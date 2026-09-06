#!/bin/bash
# pins: SB_SIMPLICITY_GATE — kill-switch test: asserts =off suppresses the gate
# pins: SB_SIMPLICITY_GATE_LINES — raises the line threshold to prove a raised ceiling suppresses a 200-line change — the value is the subject of that subtest
# Guard: simplicity-gate nudges on a large Write/Edit/MultiEdit, stays silent on small ones,
# is advisory-only (never blocks), honors the kill switch + threshold, ignores non-edit tools,
# and fail-softs on malformed input.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/simplicity-gate.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"
big=$(yes 'x' | head -200)
EVT=$(jq -nc --arg c "$big" '{tool_name:"Write",tool_input:{content:$c}}')
OUT=$(printf '%s' "$EVT" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'Simplicity check' || fail "200-line Write should nudge"
printf '%s' "$OUT" | grep -qiE 'deny|permissionDecision' && fail "must be advisory, never block"
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null 2>&1 || fail "wrong hookEventName"
pass "large Write nudges, advisory PostToolUse only"
SMALL=$(jq -nc --arg c "$(yes 'x'|head -10)" '{tool_name:"Write",tool_input:{content:$c}}')
[ -z "$(printf '%s' "$SMALL" | bash "$SC" 2>/dev/null)" ] || fail "small Write should be silent"
pass "small Write silent"
EDIT=$(jq -nc --arg s "$big" '{tool_name:"Edit",tool_input:{old_string:"a",new_string:$s}}')
printf '%s' "$EDIT" | bash "$SC" 2>/dev/null | grep -q 'Simplicity check' || fail "large Edit should nudge"
ME=$(jq -nc --arg s "$(yes 'x'|head -120)" '{tool_name:"MultiEdit",tool_input:{edits:[{old_string:"a",new_string:$s},{old_string:"b",new_string:$s}]}}')
printf '%s' "$ME" | bash "$SC" 2>/dev/null | grep -q 'Simplicity check' || fail "large MultiEdit (summed) should nudge"
pass "large Edit + summed MultiEdit nudge"
[ -z "$(printf '%s' "$EVT" | SB_SIMPLICITY_GATE=off bash "$SC" 2>/dev/null)" ] || fail "kill switch should suppress"
pass "SB_SIMPLICITY_GATE=off suppresses"
[ -z "$(printf '%s' "$EVT" | SB_SIMPLICITY_GATE_LINES=500 bash "$SC" 2>/dev/null)" ] || fail "raised threshold should suppress a 200-line change"
pass "SB_SIMPLICITY_GATE_LINES tunes the threshold"
[ -z "$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$SC" 2>/dev/null)" ] || fail "Bash should be ignored"
[ -z "$(printf 'not json' | bash "$SC" 2>/dev/null)" ] || fail "malformed should be silent"
pass "non-edit tool ignored + malformed fail-soft"
echo; echo "ALL PASS"
