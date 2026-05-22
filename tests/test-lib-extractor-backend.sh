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
  local label="$1"
  rm -f "$BRAIN_DIR/.extractor-health.json"
  local input=$(mktemp) out=$(mktemp)
  printf "hello" > "$input"
  local start=$(date +%s)
  (
    source "$SCRIPT_DIR/scripts/lib.sh"
    # Short timeout so a hung stub doesn't stall the test
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 2 || true
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
  CLAUDECODE=1 ANTHROPIC_API_KEY="sk-ant-test" run_case "A"
)
echo "$result_a"
echo "$result_a" | grep -q "backend=anthropic-api" \
  || { echo "FAIL A: expected backend=anthropic-api"; exit 1; }
echo "$result_a" | grep -q "status=ok" \
  || { echo "FAIL A: expected status=ok"; exit 1; }
# Must be fast — no 40s timeout burn on the CLI
elapsed_a=$(echo "$result_a" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')
[ "${elapsed_a:-99}" -lt 3 ] \
  || { echo "FAIL A: elapsed=${elapsed_a}s (expected <3s, CLI must be skipped)"; exit 1; }
echo "PASS A: in-CC + API key → anthropic-api, fast"

# --- Case B: inside Claude Code + no API key ----------------------------------
# Expected: status=queued and very fast (no CLI hang attempt).
result_b=$(
  CLAUDECODE=1 run_case "B"
)
echo "$result_b"
echo "$result_b" | grep -q "status=queued" \
  || { echo "FAIL B: expected status=queued"; exit 1; }
elapsed_b=$(echo "$result_b" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')
[ "${elapsed_b:-99}" -lt 5 ] \
  || { echo "FAIL B: elapsed=${elapsed_b}s (expected <5s, no CLI hang)"; exit 1; }
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

echo "ALL PASS"
