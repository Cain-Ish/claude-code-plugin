#!/bin/bash
# Tests for scripts/persona-context.sh — UserPromptSubmit hook (Layer 1 + /? route).
# Replaces scripts/intent-gate.sh in v2.3.0.
#
# Implementation note: scripts/persona-context.sh ships without the executable
# bit (hooks.json invokes it as `bash <script>`), so all test invocations here
# go through `bash "$SCRIPT"` rather than `"$SCRIPT"` directly.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-context.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate from the user's real ~/.second-brain. Without this, the per-session
# injection memo persists between test cases (same session_id => deduped output)
# and the test pollutes the user's actual brain dir.
export BRAIN_DIR="$TMP/brain"
mkdir -p "$BRAIN_DIR"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Default to a unique session_id per case so the memo doesn't bleed across
# semantic-content cases. payload() runs inside command substitution
# subshells, so the counter has to live in a file — variables don't survive
# the subshell exit.
export SID_COUNTER_FILE="$TMP/sid-counter"
echo 0 > "$SID_COUNTER_FILE"
payload() {
  local n
  n=$(($(cat "$SID_COUNTER_FILE") + 1))
  echo "$n" > "$SID_COUNTER_FILE"
  jq -nc --arg p "$1" --arg sid "test-$n" '{
    session_id: $sid,
    transcript_path: "/dev/null",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt: $p
  }'
}

payload_sid() {
  jq -nc --arg p "$1" --arg sid "$2" '{
    session_id: $sid,
    transcript_path: "/dev/null",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt: $p
  }'
}

# Test 1: empty stdin → silent
out=$(echo "" | bash "$SCRIPT")
[ -z "$out" ] || fail "empty stdin should be silent"
pass "empty stdin silent"

# Test 2: trivial 'yes' → silent
out=$(payload "yes" | bash "$SCRIPT")
[ -z "$out" ] || fail "trivial ack should be silent (got: $out)"
pass "trivial ack silent"

# Test 3: substantive build prompt → emits additionalContext
out=$(payload "build a login form with rate limiting and oauth" | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null \
  || fail "substantive: missing hookSpecificOutput envelope (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("Persona context"; "i")' >/dev/null \
  || fail "substantive: additionalContext missing 'Persona context' header"
pass "substantive prompt emits persona context"

# Test 4: SB_PERSONA_GATE=off honored
out=$(SB_PERSONA_GATE=off bash -c "$(declare -f payload); payload 'implement a new feature with many words to ensure substantive' | bash '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output (got: $out)"
pass "kill switch honored"

# Test 5: /? prefix without bundle present → silent (defer to T6 wiring; the test
# environment may or may not have the bundle, but it should never crash)
out=$(payload "/? what's the best approach" | bash "$SCRIPT" 2>&1)
echo "$out" | grep -qE '^\{' || [ -z "$out" ] || fail "/? prefix should emit either JSON or be silent (got: $out)"
pass "/? prefix handled cleanly"

# Test 6: short action-verb prompt → still substantive (preserved from intent-gate)
out=$(payload "fix the bug in auth" | bash "$SCRIPT")
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
out=$(BRAIN_DIR="$BRAIN_DIR_TEST" payload "build a thing with many words to be substantive" | BRAIN_DIR="$BRAIN_DIR_TEST" bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("test-role-marker")' >/dev/null \
  || fail "persona-card identity bullets should appear in context (got: $out)"
pass "persona-card injected"
rm -rf "$BRAIN_DIR_TEST"

# Test 8: per-session injection memo deduplicates ambient state across turns.
# Same session_id, same context inputs → second invocation should suppress the
# persona/catalog/wiki/episodic sections (they were already injected). The header
# alone has nothing to add, so the script exits silent.
BRAIN_DIR_DEDUP=$(mktemp -d)
cat > "$BRAIN_DIR_DEDUP/persona-card.md" <<EOF
# Persona

## Identity
- dedup-test-role

## Style
- terse
EOF
out_a=$(BRAIN_DIR="$BRAIN_DIR_DEDUP" payload_sid "implement a thing that needs substance and many words" "dedup-session" | BRAIN_DIR="$BRAIN_DIR_DEDUP" bash "$SCRIPT")
echo "$out_a" | jq -e '.hookSpecificOutput.additionalContext | test("dedup-test-role")' >/dev/null \
  || fail "first turn should emit persona context (got: $out_a)"
[ -f "$BRAIN_DIR_DEDUP/.injected/dedup-session.json" ] \
  || fail "memo file should be written after first turn"

out_b=$(BRAIN_DIR="$BRAIN_DIR_DEDUP" payload_sid "another substantive prompt that won't change static context" "dedup-session" | BRAIN_DIR="$BRAIN_DIR_DEDUP" bash "$SCRIPT")
# Second turn: persona unchanged, wiki/catalog/episodic empty in this test env →
# all sections suppressed → header-only → exit silent.
if [ -n "$out_b" ]; then
  echo "$out_b" | jq -e '.hookSpecificOutput.additionalContext | test("dedup-test-role") | not' >/dev/null \
    || fail "second turn must not re-inject unchanged persona (got: $out_b)"
fi
pass "per-session memo dedups unchanged sections"
rm -rf "$BRAIN_DIR_DEDUP"

# Test 9a: persona-card bullets duplicating USER.md get stripped from the
# injected context. The duplicated bullet is already injected via USER.md by
# session-load.sh; re-injecting it through persona-card is wasted tokens.
BRAIN_DIR_OVERLAP=$(mktemp -d)
cat > "$BRAIN_DIR_OVERLAP/USER.md" <<EOF
# User Profile

## Hard Rules
- Zero AI attribution in commits — no Co-Authored-By
- Local-only data — never sync externally
EOF
cat > "$BRAIN_DIR_OVERLAP/persona-card.md" <<EOF
# Persona

## Identity
- Zero AI attribution in commits — no Co-Authored-By
- distinct-card-only-bullet
EOF
out_e=$(BRAIN_DIR="$BRAIN_DIR_OVERLAP" payload_sid "implement a thing that needs substance and many words" "overlap-session" | BRAIN_DIR="$BRAIN_DIR_OVERLAP" bash "$SCRIPT")
echo "$out_e" | jq -e '.hookSpecificOutput.additionalContext | test("distinct-card-only-bullet")' >/dev/null \
  || fail "card-only bullet should appear in context (got: $out_e)"
echo "$out_e" | jq -e '.hookSpecificOutput.additionalContext | test("Persona:.*Zero AI attribution") | not' >/dev/null \
  || fail "USER.md-duplicate bullet should be stripped from persona context (got: $out_e)"
pass "USER.md-duplicate bullets stripped from persona context"
rm -rf "$BRAIN_DIR_OVERLAP"

# Test 9: changing the persona between turns forces re-injection.
BRAIN_DIR_CHANGE=$(mktemp -d)
cat > "$BRAIN_DIR_CHANGE/persona-card.md" <<EOF
# Persona

## Identity
- first-marker
EOF
out_c=$(BRAIN_DIR="$BRAIN_DIR_CHANGE" payload_sid "implement a thing that needs substance and many words" "change-session" | BRAIN_DIR="$BRAIN_DIR_CHANGE" bash "$SCRIPT")
echo "$out_c" | jq -e '.hookSpecificOutput.additionalContext | test("first-marker")' >/dev/null \
  || fail "first turn should emit first-marker (got: $out_c)"

cat > "$BRAIN_DIR_CHANGE/persona-card.md" <<EOF
# Persona

## Identity
- second-marker
EOF
out_d=$(BRAIN_DIR="$BRAIN_DIR_CHANGE" payload_sid "another substantive prompt with enough words to bypass the trivial gate" "change-session" | BRAIN_DIR="$BRAIN_DIR_CHANGE" bash "$SCRIPT")
echo "$out_d" | jq -e '.hookSpecificOutput.additionalContext | test("second-marker")' >/dev/null \
  || fail "second turn should re-inject changed persona (got: $out_d)"
pass "memo re-injects when content changes"
rm -rf "$BRAIN_DIR_CHANGE"

echo
echo "ALL PASS"
