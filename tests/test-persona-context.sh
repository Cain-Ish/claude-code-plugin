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

# Test 8: per-session injection memo dedup policy.
#
# v2.10 contract (see persona-context.sh:256-260):
#   - Persona + catalog: ALWAYS re-injected each turn. The model has no
#     persistent memory between turns; dedup-suppressing persona after turn 1
#     was the previous behavior and silently made the persona disappear,
#     which was the bug the v2.10 change fixed.
#   - Wiki + episodic: hash-deduped on unchanged input — those are noisier
#     and re-injecting the same 12 slugs every turn is genuine signal noise.
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
# Per v2.10 contract: persona IS re-injected on the second turn (always-on
# policy). Wiki + episodic *would* be deduped if non-empty, but the test
# brain-dir has no wiki/episodic content so there's nothing to dedup here.
echo "$out_b" | jq -e '.hookSpecificOutput.additionalContext | test("dedup-test-role")' >/dev/null \
  || fail "second turn must still re-inject persona (v2.10 contract, got: $out_b)"
pass "per-session memo: persona always re-injected, wiki/episodic dedup'd on no-change"
rm -rf "$BRAIN_DIR_DEDUP"

# Test 8b: wiki section dedups when wiki hits are unchanged across turns.
# Uses a real wiki dir so knowledge-search-cli has content to retrieve. The
# memo should record the wiki hash on turn 1; turn 2 with the same prompt
# (→ same wiki retrieval) → wiki section suppressed in output.
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
cat > "$BRAIN_DIR_WDEDUP/persona-card.md" <<EOF
# Persona

## Identity
- wiki-dedup-test
EOF
# Turn 1 — wiki section should appear
out_w1=$(KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" \
  payload_sid "tell me about the widget thing in detail" "wiki-dedup-session" \
  | KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
# Turn 2 — same prompt → same wiki hits → wiki section suppressed
out_w2=$(KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" \
  payload_sid "tell me about the widget thing in detail" "wiki-dedup-session" \
  | KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP" BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
# Persona stays
echo "$out_w2" | jq -e '.hookSpecificOutput.additionalContext | test("wiki-dedup-test")' >/dev/null \
  || fail "turn 2: persona must remain (got: $out_w2)"
# If turn 1 returned wiki, turn 2 should not repeat it. Test is best-effort:
# wiki retrieval depends on the knowledge_search bundle being present; if not,
# both turns return no wiki and the assertion is vacuously true.
if echo "$out_w1" | jq -e '.hookSpecificOutput.additionalContext | test("widget-page")' >/dev/null 2>&1; then
  echo "$out_w2" | jq -e '.hookSpecificOutput.additionalContext | test("widget-page") | not' >/dev/null \
    || fail "turn 2: wiki section should be deduped when hits unchanged (got: $out_w2)"
  pass "wiki dedup: unchanged wiki hits suppressed on next turn"
else
  pass "wiki dedup: skipped (knowledge_search returned no hits in this env)"
fi
rm -rf "$BRAIN_DIR_WDEDUP" "$KNOW_DIR_WDEDUP"

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

# Test 10 (D3): USER.md<->persona-card dedup must handle backslash-bearing bullets.
# Regression: the dedup passed USER bullets to awk via `-v ub=...`, and `-v` runs POSIX escape
# processing on the value — so a bullet like `C:\temp\notes` had its `\t`/`\n` rewritten, the
# seen[] key no longer matched the verbatim card bullet, dedup silently failed, and the bullet
# was double-injected (USER.md at session-start + the card every prompt). Fixed via ENVIRON[].
BRAIN_DIR_BS=$(mktemp -d)
printf '# USER\n\n## Working\n- C:\\temp\\notes\n' > "$BRAIN_DIR_BS/USER.md"
cat > "$BRAIN_DIR_BS/persona-card.md" <<'PCARD'
# Persona

## Identity
- backslash-test-role

## Working
- C:\temp\notes
PCARD
out_bs=$(BRAIN_DIR="$BRAIN_DIR_BS" payload_sid "implement a substantive thing with enough words to clear the gate" "bs-session" | BRAIN_DIR="$BRAIN_DIR_BS" bash "$SCRIPT")
echo "$out_bs" | jq -e '.hookSpecificOutput.additionalContext | test("backslash-test-role")' >/dev/null \
  || fail "persona should inject for the backslash-dedup case (got: $out_bs)"
if echo "$out_bs" | jq -r '.hookSpecificOutput.additionalContext' | grep -F 'C:\temp\notes' >/dev/null; then
  fail "backslash bullet was NOT deduped against USER.md (mawk -v escape bug) — double-injected"
fi
pass "USER.md<->card dedup handles backslash bullets (no -v escape mangling)"
rm -rf "$BRAIN_DIR_BS"

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
