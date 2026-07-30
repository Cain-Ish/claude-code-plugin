#!/usr/bin/env bash
# Verify sb_call_extractor backend selection under the four
# (CLAUDECODE × ANTHROPIC_API_KEY) combinations.
#
# Stubs `claude` to always hang and `curl` to return a canned valid JSON.
# Observes which backend was actually used via the health-marker file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolated second-brain dir
export BRAIN_DIR="$TMP/.sb"
mkdir -p "$BRAIN_DIR"

# Stub claude CLI that always hangs (simulates recursive-claude in-session)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
chmod +x "$TMP/bin/claude"

# Stub curl that returns a canned valid Messages-API response
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Drain stdin so the caller's input pipe closes cleanly
cat >/dev/null
printf '%s' '{"content":[{"text":"{\"decisions\":[],\"blockers\":[]}"}]}'
EOF
chmod +x "$TMP/bin/curl"

# jq is required by lib.sh; assume host has it
command -v jq >/dev/null || { echo "SKIP: jq not on host PATH"; exit 0; }

export PATH="$TMP/bin:$PATH"

# Source lib.sh in a subshell so we can re-enter with fresh env
run_case() {
  local label="$1" tmo="${2:-2}"
  rm -f "$BRAIN_DIR/.extractor-health.json"
  local input=$(mktemp) out=$(mktemp)
  printf "hello" > "$input"
  local start=$(date +%s)
  (
    source "$SCRIPT_DIR/scripts/lib.sh"
    # Timeout per case: A/B pass 10s — their CORRECT paths never run the CLI, so
    # elapsed stays ~0s, but the inner `timeout` also wraps the curl stub, and a
    # 2s ceiling got the stub killed under post-vitest load on a Pi (the
    # status=fail suite flake). C keeps 2s so the hang-stub kill stays fast.
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" "$tmo" || true
  )
  local elapsed=$(( $(date +%s) - start ))
  local backend status
  backend=$(jq -r '.backend // "missing"' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
  status=$(jq -r '.status // "missing"'   "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
  rm -f "$input" "$out"
  echo "$label backend=$backend status=$status elapsed=${elapsed}s"
}

# --- Case A: inside Claude Code + API key set ---------------------------------
# Expected: anthropic-api (NOT claude-cli — that would hang).
result_a=$(
  CLAUDECODE=1 ANTHROPIC_API_KEY="sk-ant-test" run_case "A" 10
)
echo "$result_a"
echo "$result_a" | grep -q "backend=anthropic-api" \
  || { echo "FAIL A: expected backend=anthropic-api"; exit 1; }
echo "$result_a" | grep -q "status=ok" \
  || { echo "FAIL A: expected status=ok"; exit 1; }
# Must be fast — the guard is vs a wrong-path CLI burn (>= the 10s timeout);
# the correct path never runs the CLI so elapsed stays ~0 even under suite load.
elapsed_a=$(echo "$result_a" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')
[ "${elapsed_a:-99}" -lt 10 ] \
  || { echo "FAIL A: elapsed=${elapsed_a}s (expected <10s, CLI must be skipped)"; exit 1; }
echo "PASS A: in-CC + API key → anthropic-api, fast"

# --- Case B: inside Claude Code + no API key ----------------------------------
# Expected: status=queued and very fast (no CLI hang attempt).
result_b=$(
  CLAUDECODE=1 run_case "B" 10
)
echo "$result_b"
echo "$result_b" | grep -q "status=queued" \
  || { echo "FAIL B: expected status=queued"; exit 1; }
elapsed_b=$(echo "$result_b" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')
[ "${elapsed_b:-99}" -lt 10 ] \
  || { echo "FAIL B: elapsed=${elapsed_b}s (expected <10s, no CLI hang)"; exit 1; }
echo "PASS B: in-CC + no API key → queued, fast-fail"

# --- Case C: outside Claude Code + no API key ---------------------------------
# Expected: tries CLI (and either hangs to timeout or fails — that's OK; the
# point is we DON'T short-circuit when not in-session). We just verify the
# function returns within timeout+a little, and the health record was
# written by Backend 1's empty-output path (NOT the new queued path).
# Must explicitly unset CLAUDECODE because this test itself usually runs
# inside a Claude Code session and would otherwise inherit CLAUDECODE=1.
result_c=$(
  env -u CLAUDECODE -u ANTHROPIC_API_KEY bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    start=$(date +%s)
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 2 || true
    elapsed=$(( $(date +%s) - start ))
    backend=$(jq -r ".backend // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    status=$(jq -r ".status // \"missing\""   "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    rm -f "$input" "$out"
    echo "C backend=$backend status=$status elapsed=${elapsed}s"
  '
)
echo "$result_c"
echo "$result_c" | grep -q "status=queued" \
  && { echo "FAIL C: must NOT short-circuit when CLAUDECODE unset"; exit 1; }
echo "PASS C: outside CC → CLI path runs (no short-circuit)"

# --- Case D: API path hits the max_tokens output cap ---------------------------
# A truncated response returns a valid envelope whose text is a JSON *prefix* +
# stop_reason "max_tokens". Health must name the truncation (capture-widening
# review: cap 3→8 raised output demand — an overflow must be diagnosable, not
# generic "non-json"). Also locks the widened output budget: the Backend 2
# payload must request max_tokens >= 8192.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"stop_reason":"max_tokens","content":[{"text":"{\"recent_decisions\":[\"trunca"}]}'
EOF
chmod +x "$TMP/bin/curl"
result_d=$(
  CLAUDECODE=1 ANTHROPIC_API_KEY="sk-ant-test" run_case "D" 10
)
echo "$result_d"
echo "$result_d" | grep -q "status=fail" \
  || { echo "FAIL D: truncated output must record status=fail"; exit 1; }
reason_d=$(jq -r '.reason // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)
printf '%s' "$reason_d" | grep -q 'max-tokens-truncated' \
  || { echo "FAIL D: reason must name the truncation (got: $reason_d)"; exit 1; }
grep -q 'max_tokens:8192' "$SCRIPT_DIR/scripts/lib.sh" \
  || { echo "FAIL D: Backend 2 payload must request max_tokens:8192 (widened schema budget)"; exit 1; }
echo "PASS D: max_tokens truncation named in health; output budget 8192 locked"

echo "ALL PASS"
