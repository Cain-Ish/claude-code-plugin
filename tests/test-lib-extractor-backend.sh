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

# --- Case E: Backend 2 must send a REAL model id, never a bare dispatch alias (D108) ---
# tier:mid resolves (via sb_resolve_model) to the ladder's rung-0 alias "sonnet" — the
# CLI accepts that, but the Messages API 404s on a bare alias. Capture the posted
# body's .model and assert it is not one of the bare dispatch aliases.
export MODEL_PROBE="$TMP/model.probe"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "--data-binary" ]; then
    f="${a#@}"
    [ -f "$f" ] && jq -r '.model // empty' "$f" > "$MODEL_PROBE" 2>/dev/null
  fi
  prev="$a"
done
printf '%s' '{"content":[{"text":"{\"decisions\":[],\"blockers\":[]}"}]}'
EOF
chmod +x "$TMP/bin/curl"
rm -f "$MODEL_PROBE"
(
  CLAUDECODE=1 ANTHROPIC_API_KEY="sk-ant-test" bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    export MODEL_PROBE="'"$MODEL_PROBE"'"
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    sb_call_extractor "$input" "$out" "tier:mid" "test-system" 10 || true
    rm -f "$input" "$out"
  '
)
POSTED_MODEL=$(cat "$MODEL_PROBE" 2>/dev/null || echo "")
echo "E posted model: $POSTED_MODEL"
case "$POSTED_MODEL" in
  sonnet|opus|haiku|fable|"")
    echo "FAIL E: Backend 2 posted a bare alias or nothing (got '$POSTED_MODEL')"; exit 1 ;;
esac
echo "PASS E: Backend 2 posts a real model id ('$POSTED_MODEL'), not a bare alias"

# --- Case F: Backend 2 must never rely on a BARE `timeout` binary — sb_timeout's
# gtimeout/timeout/bash-watchdog fallback must still run curl when neither
# `timeout` nor `gtimeout` is on PATH (stock macOS/BSD) (D102).
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s' '{"content":[{"text":"{\"decisions\":[],\"blockers\":[]}"}]}'
EOF
chmod +x "$TMP/bin/curl"
result_f=$(
  CLAUDECODE=1 ANTHROPIC_API_KEY="sk-ant-test" bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    command() { if [ "$1" = -v ] && { [ "$2" = timeout ] || [ "$2" = gtimeout ]; }; then return 1; fi; builtin command "$@"; }
    timeout() { echo "bash: timeout: command not found" >&2; return 127; }
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 5 || true
    backend=$(jq -r ".backend // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    status=$(jq -r ".status // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    rm -f "$input" "$out"
    echo "F backend=$backend status=$status"
  '
)
echo "$result_f"
echo "$result_f" | grep -q "status=ok" \
  || { echo "FAIL F: expected status=ok via sb_timeout fallback when timeout/gtimeout absent (got: $result_f)"; exit 1; }
echo "PASS F: Backend 2 works via sb_timeout watchdog when timeout/gtimeout are absent"

# --- Case G: parse JSON FIRST — a valid JSON delta must be accepted even when
# its PROSE mentions "unauthorized"/"invalid api key"; only classify as an
# auth failure when stdout is NOT valid JSON AND matches the signature (D122).
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"recent_decisions":["Fixed the 401 Unauthorized response handling in auth middleware"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
EOF
chmod +x "$TMP/bin/claude"
result_g=$(
  env -u CLAUDECODE -u ANTHROPIC_API_KEY bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    rc=0
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 5 || rc=$?
    outsize=$(wc -c < "$out" | tr -d " ")
    status=$(jq -r ".status // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    rm -f "$input" "$out"
    echo "G rc=$rc outsize=$outsize status=$status"
  '
)
echo "$result_g"
echo "$result_g" | grep -q "rc=0" \
  || { echo "FAIL G: valid JSON delta with auth-flavored prose must be ACCEPTED (rc must be 0)"; exit 1; }
echo "$result_g" | grep -q "status=ok" \
  || { echo "FAIL G: expected status=ok for a valid JSON delta (got: $result_g)"; exit 1; }
echo "PASS G: valid JSON accepted even when prose mentions 'Unauthorized' (D122)"

# --- Case H (review follow-up): a bare, contentless `{}` must be REJECTED as a
# usable extraction — `jq -e 'type=="object"'` treated it as valid (type IS
# object) even though it carries no fields at all.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{}'
EOF
chmod +x "$TMP/bin/claude"
result_h=$(
  env -u CLAUDECODE -u ANTHROPIC_API_KEY bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    rc=0
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 5 || rc=$?
    status=$(jq -r ".status // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    rm -f "$input" "$out"
    echo "H rc=$rc status=$status"
  '
)
echo "$result_h"
echo "$result_h" | grep -q "rc=0" \
  && { echo "FAIL H: a bare {} must NOT be accepted as a usable extraction (rc=0)"; exit 1; }
echo "$result_h" | grep -q "status=fail" \
  || { echo "FAIL H: bare {} must record status=fail (got: $result_h)"; exit 1; }
echo "PASS H: bare {} rejected (review follow-up: sb_extractor_object_ok requires length>0)"

# --- Case I (review follow-up): a concatenated multi-value JSON stream
# (`{}{"a":...}`) must be REJECTED. `jq -e 'type=="object"'` WITHOUT `-s`
# only judges the LAST value in the stream and would have accepted this.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{}{"recent_decisions":["smuggled second value"]}'
EOF
chmod +x "$TMP/bin/claude"
result_i=$(
  env -u CLAUDECODE -u ANTHROPIC_API_KEY bash -c '
    set -eu
    export BRAIN_DIR="'"$BRAIN_DIR"'"
    export PATH="'"$PATH"'"
    source "'"$SCRIPT_DIR"'/scripts/lib.sh"
    rm -f "$BRAIN_DIR/.extractor-health.json"
    input=$(mktemp); out=$(mktemp)
    printf "hello" > "$input"
    rc=0
    sb_call_extractor "$input" "$out" "claude-sonnet-4-6" "test-system" 5 || rc=$?
    status=$(jq -r ".status // \"missing\"" "$BRAIN_DIR/.extractor-health.json" 2>/dev/null || echo missing)
    rm -f "$input" "$out"
    echo "I rc=$rc status=$status"
  '
)
echo "$result_i"
echo "$result_i" | grep -q "rc=0" \
  && { echo "FAIL I: a concatenated multi-value JSON stream must NOT be accepted (rc=0)"; exit 1; }
echo "$result_i" | grep -q "status=fail" \
  || { echo "FAIL I: concatenated stream must record status=fail (got: $result_i)"; exit 1; }
echo "PASS I: concatenated multi-value JSON stream rejected (review follow-up: jq -es length==1)"

echo "ALL PASS"
