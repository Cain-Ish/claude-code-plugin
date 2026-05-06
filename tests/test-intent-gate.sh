#!/bin/bash
# Tests for scripts/intent-gate.sh — UserPromptSubmit hook.
# Contract: emit a JSON envelope with hookSpecificOutput.additionalContext
# containing the Intent Analysis reminder for substantive prompts; emit
# nothing for trivial follow-ups (acks, ≤6-word ack-style replies).
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/intent-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Helper: build a UserPromptSubmit hook stdin payload around a prompt.
payload() {
  jq -nc --arg p "$1" '{
    session_id: "test",
    transcript_path: "/dev/null",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt: $p
  }'
}

# Test 1: substantive prompt → emits additionalContext with Intent cue.
out=$(payload "I want to implement an endpoint /all to get all data" | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null \
  || fail "substantive: missing hookSpecificOutput envelope"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("Intent"; "i")' >/dev/null \
  || fail "substantive: additionalContext missing Intent cue"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("second-brain"; "i")' >/dev/null \
  || fail "substantive: additionalContext missing second-brain query directive"
pass "substantive prompt: emits Intent reminder"

# Test 2: ack "yes" → no output.
out=$(payload "yes" | "$SCRIPT")
[ -z "$out" ] || fail "ack 'yes': expected silent, got: $out"
pass "ack 'yes': silent"

# Test 3: ack "go ahead" (3 words) → no output.
out=$(payload "go ahead" | "$SCRIPT")
[ -z "$out" ] || fail "ack 'go ahead': expected silent"
pass "ack 'go ahead': silent"

# Test 4: short non-ack 3-word question → silent (under threshold).
out=$(payload "what is this" | "$SCRIPT")
[ -z "$out" ] || fail "short prompt: expected silent"
pass "short prompt (<7 words): silent"

# Test 5: action-verb keyword in short prompt → still substantive.
out=$(payload "implement /users endpoint with auth" | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null \
  || fail "short action-verb: expected substantive"
pass "short prompt with action verb 'implement': substantive"

# Test 6: empty prompt → no output (no crash).
out=$(payload "" | "$SCRIPT")
[ -z "$out" ] || fail "empty prompt: expected silent"
pass "empty prompt: silent"

# Test 7: malformed JSON on stdin → exit 0, no output (fail-soft, never block user).
out=$(printf 'not json' | "$SCRIPT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "malformed input: expected exit 0, got $rc"
[ -z "$out" ] || fail "malformed input: expected silent"
pass "malformed JSON: fail-soft (exit 0, silent)"

# Test 8: substantive prompt → output is valid JSON parseable by jq.
out=$(payload "design a caching layer for the data ingestion pipeline" | "$SCRIPT")
echo "$out" | jq -e '.' >/dev/null || fail "substantive: output is not valid JSON"
pass "substantive: output is valid JSON"

# Test 9: ack "lgtm" → silent.
out=$(payload "lgtm" | "$SCRIPT")
[ -z "$out" ] || fail "ack 'lgtm': expected silent"
pass "ack 'lgtm': silent"

# Test 10: long acknowledgement starting with thanks → silent (sentence-shape ack).
out=$(payload "thanks, that worked perfectly for me" | "$SCRIPT")
[ -z "$out" ] || fail "thanks-prefix ack: expected silent"
pass "ack 'thanks, ...': silent"

echo "ALL PASS"
