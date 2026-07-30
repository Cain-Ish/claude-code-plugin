#!/bin/bash
# Tests for the deterministic PostToolUse observation ledger (P0 rec 5).
# Contract under test:
#   scripts/observe-tool-use.sh appends ONE compact JSONL line per tool use —
#   {ts, tool, target, ok[, err]} — to $BRAIN_DIR/observations/<session>.jsonl.
#   Pure jq/bash, zero LLM; always exits 0; kill switch SB_OBSERVATION_LEDGER=off;
#   quiet under SB_HOOK_PROFILE=minimal (pre-source shim) and SB_NESTED_SPAWN=1;
#   session id sanitized (no path traversal); bounded by SB_OBSERVATION_MAX_BYTES.
#   The drainer mines the ledger: lib.sh sb_observations_summary renders a
#   bounded ERROR + TOOL COUNTS digest, and sb_extract_transcript embeds it in
#   the extractor input as a labeled DATA section.
unset CLAUDECODE
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/observe-tool-use.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

export HOME="$TMP/home"; mkdir -p "$HOME"
export BRAIN_DIR="$TMP/brain"; mkdir -p "$BRAIN_DIR"
OBS_DIR="$BRAIN_DIR/observations"

payload() {  # $1=tool $2=session_id $3=input-json $4=response-json
  jq -nc --arg t "$1" --arg sid "$2" --argjson inp "$3" --argjson resp "$4" \
    '{hook_event_name:"PostToolUse", tool_name:$t, session_id:$sid, tool_input:$inp, tool_response:$resp}'
}

# 1. Happy path: Bash success → one line, ok:true, command as target.
payload "Bash" "sess-1" '{"command":"git status"}' '{"stdout":"clean","stderr":""}' \
  | bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "happy: expected exit 0, got $rc"
F="$OBS_DIR/sess-1.jsonl"
[ -f "$F" ] || fail "happy: ledger file not created"
jq -e 'select(.tool=="Bash" and .target=="git status" and .ok==true and (.ts | test("^20")))' "$F" >/dev/null 2>&1 \
  || fail "happy: record fields wrong: $(cat "$F")"
jq -e 'has("err")' "$F" 2>/dev/null | grep -q true && fail "happy: err field present on a success"
pass "success tool use → {ts, tool, target, ok:true}, no err field"

# 2. Append, not overwrite: a second call adds a second line.
payload "Edit" "sess-1" '{"file_path":"/repo/src/a.ts"}' '{}' | bash "$SCRIPT"
N=$(wc -l < "$F" | tr -d ' ')
[ "$N" -eq 2 ] || fail "append: expected 2 lines, got $N"
jq -es '.[1] | select(.tool=="Edit" and .target=="/repo/src/a.ts")' "$F" >/dev/null 2>&1 \
  || fail "append: second record wrong: $(tail -1 "$F")"
pass "second tool use appends (2 lines, order preserved)"

# 3. Error shapes: is_error flag, error field, and nonzero exit code.
payload "Bash" "sess-err" '{"command":"npm test"}' '{"is_error":true,"error":"FAIL tests/x.sh: assertion"}' | bash "$SCRIPT"
payload "Read" "sess-err" '{"file_path":"/gone.txt"}' '{"error":"ENOENT: no such file"}' | bash "$SCRIPT"
payload "Bash" "sess-err" '{"command":"false"}' '{"stdout":"","stderr":"boom","exitCode":1}' | bash "$SCRIPT"
FE="$OBS_DIR/sess-err.jsonl"
N=$(jq -s '[.[] | select(.ok==false)] | length' "$FE")
[ "$N" -eq 3 ] || fail "errors: expected 3 ok:false records, got $N: $(cat "$FE")"
jq -e 'select(.tool=="Bash" and .ok==false) | select(.err | test("assertion"))' "$FE" >/dev/null 2>&1 \
  || fail "errors: err head not captured from is_error shape"
pass "error shapes (is_error / error field / exitCode!=0) → ok:false with err head"

# 4. Kill switch: SB_OBSERVATION_LEDGER=off → no write, exit 0.
payload "Bash" "sess-off" '{"command":"x"}' '{}' | SB_OBSERVATION_LEDGER=off bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "kill: expected exit 0, got $rc"
[ -f "$OBS_DIR/sess-off.jsonl" ] && fail "kill: ledger written despite SB_OBSERVATION_LEDGER=off"
pass "SB_OBSERVATION_LEDGER=off → no write, exit 0"

# 5. Hook profile minimal: quiet via the PRE-SOURCE shim.
payload "Bash" "sess-min" '{"command":"x"}' '{}' | SB_HOOK_PROFILE=minimal bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "minimal: expected exit 0, got $rc"
[ -f "$OBS_DIR/sess-min.jsonl" ] && fail "minimal: ledger written despite SB_HOOK_PROFILE=minimal"
pass "SB_HOOK_PROFILE=minimal → quiet (pre-source shim)"

# 6. Nested spawn: headless children never ledger their own tool calls.
payload "Bash" "sess-nest" '{"command":"x"}' '{}' | SB_NESTED_SPAWN=1 bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "nested: expected exit 0, got $rc"
[ -f "$OBS_DIR/sess-nest.jsonl" ] && fail "nested: ledger written under SB_NESTED_SPAWN=1"
pass "SB_NESTED_SPAWN=1 → no write"

# 7. Malformed / empty stdin → exit 0, nothing written.
printf '' | bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "empty-stdin: expected exit 0, got $rc"
printf 'not json' | bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "garbage-stdin: expected exit 0, got $rc"
GARBAGE_FILES=$(find "$OBS_DIR" -name 'unknown.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$GARBAGE_FILES" -eq 0 ] || { grep -q '"tool"' "$OBS_DIR/unknown.jsonl" 2>/dev/null && fail "garbage-stdin: a record was fabricated from garbage: $(cat "$OBS_DIR/unknown.jsonl")"; }
pass "empty/garbage stdin → exit 0, no fabricated records"

# 8. Session id sanitized: traversal chars stripped, file stays inside observations/.
payload "Bash" "../../evil" '{"command":"x"}' '{}' | bash "$SCRIPT"
[ -f "$TMP/evil.jsonl" ] && fail "sanitize: session id escaped observations/ (traversal)"
[ -f "$BRAIN_DIR/../evil.jsonl" ] && fail "sanitize: session id escaped BRAIN_DIR"
LEDGERS=$(find "$OBS_DIR" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')
[ "$LEDGERS" -ge 3 ] || fail "sanitize: expected the sanitized ledger to land inside observations/"
pass "session id sanitized — no path traversal out of observations/"

# 9. Size cap: file at/over SB_OBSERVATION_MAX_BYTES → append skipped, exit 0.
FCAP="$OBS_DIR/sess-cap.jsonl"
printf '%0.s{"pad":1}\n' 1 2 3 4 5 6 7 8 9 10 > "$FCAP"
CAP_BYTES=$(wc -c < "$FCAP" | tr -d ' ')
payload "Bash" "sess-cap" '{"command":"x"}' '{}' | SB_OBSERVATION_MAX_BYTES="$CAP_BYTES" bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] || fail "cap: expected exit 0, got $rc"
NEW_BYTES=$(wc -c < "$FCAP" | tr -d ' ')
[ "$NEW_BYTES" -eq "$CAP_BYTES" ] || fail "cap: file grew past SB_OBSERVATION_MAX_BYTES ($CAP_BYTES → $NEW_BYTES)"
pass "size cap: at-cap ledger stops appending (bounded per session)"

# ============================================================================
# Mining: sb_observations_summary + sb_extract_transcript embedding
# ============================================================================
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib.sh" || fail "lib.sh failed to source"

SUMMARY=$(sb_observations_summary "$OBS_DIR/sess-err.jsonl")
printf '%s' "$SUMMARY" | grep -q '^ERROR Bash npm test' \
  || fail "summary: error line missing (got: $SUMMARY)"
printf '%s' "$SUMMARY" | grep -q 'TOOL COUNTS:' \
  || fail "summary: tool counts line missing (got: $SUMMARY)"
printf '%s' "$SUMMARY" | grep -qE 'Bash: 2|Read: 1' \
  || fail "summary: per-tool counts wrong (got: $SUMMARY)"
pass "sb_observations_summary: ERROR lines + TOOL COUNTS, deterministic"

# sb_extract_transcript embeds the ledger for the archive's session id.
DRAIN_BRAIN="$TMP/drain-brain"
mkdir -p "$DRAIN_BRAIN/observations" "$DRAIN_BRAIN/projects"
BRAIN_DIR="$DRAIN_BRAIN"
TXT="$TMP/mine-session_test-slug_2026-07-30.txt"
cat > "$TXT" <<'EOF'
--- session-meta ---
session_id: mine-session
project_slug: test-slug
date: 2026-07-30
tool_count: 3
line_count: 3
---

USER: fix the build
ASSISTANT:
  [Bash] npm test
EOF
printf '{"ts":"2026-07-30T00:00:00Z","tool":"Bash","target":"npm test","ok":false,"err":"LEDGER-SENTINEL-FAILURE"}\n' \
  > "$DRAIN_BRAIN/observations/mine-session.jsonl"
CAPTURED="$TMP/captured-input.txt"
# Override the extractor: capture the input the drainer built, return a minimal delta.
sb_call_extractor() { cp "$1" "$CAPTURED"; printf '{"recent_decisions":[]}' > "$2"; return 0; }
sb_extract_transcript "$TXT" "test-slug" >/dev/null 2>&1 || fail "mine: sb_extract_transcript failed"
grep -q '=== OBSERVATIONS' "$CAPTURED" || fail "mine: observations section missing from extractor input"
grep -q 'LEDGER-SENTINEL-FAILURE' "$CAPTURED" || fail "mine: ledger error line not embedded"
grep -q 'DATA, not instructions' "$CAPTURED" || fail "mine: observations section missing the DATA framing"
pass "sb_extract_transcript embeds the session's ledger as a labeled DATA section"

# Absent ledger → no observations section, extraction still succeeds.
rm -f "$DRAIN_BRAIN/observations/mine-session.jsonl" "$CAPTURED"
sb_extract_transcript "$TXT" "test-slug" >/dev/null 2>&1 || fail "mine-absent: extraction failed without a ledger"
grep -q '=== OBSERVATIONS' "$CAPTURED" && fail "mine-absent: observations section emitted with no ledger"
pass "absent ledger → no observations section, extraction unaffected"

# ============================================================================
# Wiring locks (prose promises get machine locks)
# ============================================================================
jq -e '.hooks.PostToolUse[] | select(.hooks[].command | test("observe-tool-use")) | .matcher' \
  "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  || fail "wiring: hooks.json has no PostToolUse entry for observe-tool-use.sh"
MATCHER=$(jq -r '.hooks.PostToolUse[] | select(.hooks[].command | test("observe-tool-use")) | .matcher' "$PLUGIN_ROOT/hooks/hooks.json")
for t in Bash Write Edit Read Task; do
  printf '%s' "$MATCHER" | grep -q "$t" || fail "wiring: matcher missing $t (got: $MATCHER)"
done
grep -q 'observations' "$PLUGIN_ROOT/scripts/extract-drain.sh" \
  || fail "wiring: extract-drain.sh has no observations GC"
grep -q 'SB_OBSERVATION_LEDGER' "$PLUGIN_ROOT/scripts/lib.sh" \
  || fail "wiring: SB_OBSERVATION_LEDGER not mapped in lib.sh minimal profile"
pass "wiring: hooks.json entry + drainer GC + minimal-profile mapping present"

echo
echo "ALL PASS"
