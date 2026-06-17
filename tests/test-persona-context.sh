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

# Test 7 (0.32.0, inverted): a present persona-card is NO LONGER injected per-prompt. The
# per-prompt card injection was removed (it was a ~95% paraphrase of USER.md, ~330 tokens every
# prompt). USER.md (loaded once at SessionStart) carries identity; the card is still seeded but
# never injected here. (Tests 8/9/9a/10 — per-prompt persona memo + USER.md dedup — were removed
# with the injection they exercised.)
BRAIN_DIR_TEST=$(mktemp -d)
cat > "$BRAIN_DIR_TEST/persona-card.md" <<EOF
# Persona

## Identity
- test-role-marker
EOF
out=$(BRAIN_DIR="$BRAIN_DIR_TEST" payload "build a thing with many words to be substantive" | BRAIN_DIR="$BRAIN_DIR_TEST" bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("test-role-marker") | not' >/dev/null \
  || fail "persona-card must NOT be injected per-prompt in 0.32.0 (got: $out)"
pass "persona-card is NOT injected per-prompt (removed in 0.32.0)"
rm -rf "$BRAIN_DIR_TEST"

# Test 8b: wiki section dedups when wiki hits are unchanged across turns. UNAFFECTED by the
# persona cut — wiki/episodic injection + the per-session memo dedup are unchanged.
BRAIN_DIR_WDEDUP=$(mktemp -d)
KNOW_DIR_WDEDUP=$(mktemp -d)
mkdir -p "$KNOW_DIR_WDEDUP/wiki/entities"
cat > "$KNOW_DIR_WDEDUP/wiki/entities/widget-page.md" <<EOF
---
title: "Widget page"
type: entities
description: "documentation about the widget thing"
tags: [widget]
created: 2026-01-01
updated: 2026-01-01
---

Widget is a thing for widget processing.
EOF
out_w1=$(KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" \
  payload_sid "tell me about the widget thing in detail" "wiki-dedup-session" \
  | KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
out_w2=$(KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" \
  payload_sid "tell me about the widget thing in detail" "wiki-dedup-session" \
  | KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
if echo "$out_w1" | jq -e '.hookSpecificOutput.additionalContext | test("widget-page")' >/dev/null 2>&1; then
  echo "$out_w2" | jq -e '.hookSpecificOutput.additionalContext | test("widget-page") | not' >/dev/null \
    || fail "turn 2: wiki section should be deduped when hits unchanged (got: $out_w2)"
  pass "wiki dedup: unchanged wiki hits suppressed on next turn"
else
  pass "wiki dedup: skipped (knowledge_search returned no hits in this env)"
fi
rm -rf "$BRAIN_DIR_WDEDUP" "$KNOW_DIR_WDEDUP"

# Test 11 (0.29.4): the keyword stopword filter must whole-LINE match (grep -vxF), not
# word-match (grep -vwF). The tokenizer deliberately preserves hyphens so technical ids
# (claude-4-5, node-modules) survive — but -w treats a hyphen as a word boundary, so an
# identifier whose SEGMENT is a stopword (node-IS-modules) matched the stopword and was
# dropped, and its wiki page was never retrieved. Control-gated like Test 8b: only assert
# when the search bundle actually retrieves the plain-keyword control page in this env.
BRAIN_DIR_HY=$(mktemp -d); KNOW_DIR_HY=$(mktemp -d)
mkdir -p "$KNOW_DIR_HY/wiki/entities"
for pg in "widgetcontrol::widgetcontrol gadget" "node-is-modules::node-is-modules dependency"; do
  slug=${pg%%::*}; body=${pg##*::}
  cat > "$KNOW_DIR_HY/wiki/entities/$slug.md" <<EOF
---
title: "$slug"
type: entities
description: "$body resolution notes"
tags: [$slug]
created: 2026-01-01
updated: 2026-01-01
---
$body — $slug reference page.
EOF
done
hy_hit() { KNOWLEDGE_DIR="$KNOW_DIR_HY" BRAIN_DIR="$BRAIN_DIR_HY" payload_sid "$1" "$2" \
  | KNOWLEDGE_DIR="$KNOW_DIR_HY" BRAIN_DIR="$BRAIN_DIR_HY" bash "$SCRIPT" \
  | jq -r '.hookSpecificOutput.additionalContext // ""'; }
ctl=$(hy_hit "tell me about widgetcontrol gadget in detail please" "hy-ctl")
if echo "$ctl" | grep -q 'widgetcontrol'; then
  hy=$(hy_hit "explain the node-is-modules dependency resolution order in detail" "hy-test")
  echo "$hy" | grep -q 'node-is-modules' \
    || fail "hyphenated id 'node-is-modules' dropped by the stopword filter (grep -vwF word-match) — its wiki page was not retrieved"
  pass "hyphenated identifiers survive the keyword stopword filter (grep -vxF whole-line)"
else
  pass "keyword-hyphen test skipped (knowledge_search returned no hits in this env)"
fi
rm -rf "$BRAIN_DIR_HY" "$KNOW_DIR_HY"

echo
echo "ALL PASS"
