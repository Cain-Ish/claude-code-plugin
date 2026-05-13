#!/bin/bash
# Tests for scripts/persona-context.sh — UserPromptSubmit hook (Layer 1 + /? route).
# Replaces scripts/intent-gate.sh in v2.3.0.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-context.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

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

# Test 1: empty stdin → silent
out=$(echo "" | "$SCRIPT")
[ -z "$out" ] || fail "empty stdin should be silent"
pass "empty stdin silent"

# Test 2: trivial 'yes' → silent
out=$(payload "yes" | "$SCRIPT")
[ -z "$out" ] || fail "trivial ack should be silent (got: $out)"
pass "trivial ack silent"

# Test 3: substantive build prompt → emits additionalContext
out=$(payload "build a login form with rate limiting and oauth" | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null \
  || fail "substantive: missing hookSpecificOutput envelope (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("Persona context"; "i")' >/dev/null \
  || fail "substantive: additionalContext missing 'Persona context' header"
pass "substantive prompt emits persona context"

# Test 4: SB_PERSONA_GATE=off honored
out=$(SB_PERSONA_GATE=off bash -c "$(declare -f payload); payload 'implement a new feature with many words to ensure substantive' | '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output (got: $out)"
pass "kill switch honored"

# Test 5: /? prefix without bundle present → silent (defer to T6 wiring; the test
# environment may or may not have the bundle, but it should never crash)
out=$(payload "/? what's the best approach" | "$SCRIPT" 2>&1)
echo "$out" | grep -qE '^\{' || [ -z "$out" ] || fail "/? prefix should emit either JSON or be silent (got: $out)"
pass "/? prefix handled cleanly"

# Test 6: short action-verb prompt → still substantive (preserved from intent-gate)
out=$(payload "fix the bug in auth" | "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null \
  || fail "short action-verb prompt should still be substantive (got: $out)"
pass "action-verb prompt substantive"

# Test 7: persona-card injected when present
BRAIN_DIR_TEST=$(mktemp -d)
cat > "$BRAIN_DIR_TEST/persona-card.md" <<EOF
# Persona

## Identity
- test-role-marker

## Style
- terse
EOF
out=$(BRAIN_DIR="$BRAIN_DIR_TEST" payload "build a thing with many words to be substantive" | BRAIN_DIR="$BRAIN_DIR_TEST" "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("test-role-marker")' >/dev/null \
  || fail "persona-card identity bullets should appear in context (got: $out)"
pass "persona-card injected"
rm -rf "$BRAIN_DIR_TEST"

echo
echo "ALL PASS"
