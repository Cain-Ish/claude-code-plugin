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

# Test 5: /? prefix never crashes (smoke — the real env may or may not have the bundle).
out=$(payload "/? what's the best approach" | bash "$SCRIPT" 2>&1)
echo "$out" | grep -qE '^\{' || [ -z "$out" ] || fail "/? prefix should emit either JSON or be silent (got: $out)"
pass "/? prefix handled cleanly"

# Test 5a (0.32.x /? delivery): with a PRESENT persona-think-cli bundle on the resolved
# THINK_CLI path, a '/? <query>' prompt must deliver the Opus brief to additionalContext.
# We stub the bundle (the script resolves it to $CLAUDE_PLUGIN_ROOT/mcp/dist/cli/
# persona-think-cli.bundle.js) so it prints a sentinel; assert BOTH the sentinel AND the
# '[Persona deep brief' wrapper reach additionalContext. The pre-existing Test 5 passed on
# EMPTY output — so a /? route that silently delivered nothing (bundle path typo, node
# swallow) would have shipped green. This asserts the actual effect.
if command -v node >/dev/null 2>&1; then
  THINK_ROOT=$(mktemp -d)
  mkdir -p "$THINK_ROOT/mcp/dist/cli"
  cat > "$THINK_ROOT/mcp/dist/cli/persona-think-cli.bundle.js" <<'STUBJS'
let d='';process.stdin.on('data',c=>{d+=c;});process.stdin.on('end',()=>{
  process.stdout.write('SB_THINK_SENTINEL_42 query=' + d.trim());
});
STUBJS
  THINK_BRAIN=$(mktemp -d)
  out=$(payload "/? what is the best caching strategy" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$THINK_BRAIN" bash "$SCRIPT")
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("SB_THINK_SENTINEL_42")' >/dev/null \
    || fail "/? present-bundle: stubbed brief sentinel did NOT reach additionalContext (got: $out)"
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("\\[Persona deep brief")' >/dev/null \
    || fail "/? present-bundle: additionalContext missing the '[Persona deep brief' wrapper (got: $out)"
  pass "/? present-bundle: Opus brief sentinel + '[Persona deep brief' wrapper delivered to additionalContext"
  rm -rf "$THINK_ROOT" "$THINK_BRAIN"
else
  pass "/? present-bundle: skipped (node not on PATH)"
fi

# Test 5b (0.32.x /? dead-route guard): with the bundle MISSING, a '/?' prompt must NOT be
# silently empty — it must emit the fallback hint naming persona-think-cli.bundle.js so the
# user knows /? is dead (common cause: dist/ not rebuilt after a plugin pull). Force
# CLAUDE_PLUGIN_ROOT to an empty temp root so the bundle is guaranteed absent regardless of
# whether the real repo has it built.
NOBUNDLE_ROOT=$(mktemp -d)        # no mcp/dist/cli/persona-think-cli.bundle.js inside
NOBUNDLE_BRAIN=$(mktemp -d)
out=$(payload "/? what is the best caching strategy" \
  | CLAUDE_PLUGIN_ROOT="$NOBUNDLE_ROOT" BRAIN_DIR="$NOBUNDLE_BRAIN" bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("persona-think-cli.bundle.js is missing")' >/dev/null \
  || fail "/? missing-bundle: fallback hint ('persona-think-cli.bundle.js is missing') did NOT reach additionalContext — a dead /? would be silently empty (got: $out)"
pass "/? missing-bundle: dead-route fallback hint delivered to additionalContext (never silently empty)"
rm -rf "$NOBUNDLE_ROOT" "$NOBUNDLE_BRAIN"

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

# --- Session Intent Spine: goal anchor + always-emit goal line ---
SP_BRAIN=$(mktemp -d); SP_KNOW=$(mktemp -d); mkdir -p "$SP_KNOW/wiki"
sp_ctx() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

# Spine 1: the first ACTION prompt freezes the goal (with its "because" clause) and
# emits the goal line with phase plan; goal + keywords land in the memo.
out=$(payload_sid "implement the retry backoff because timeouts cascade in prod" "spine-1" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
printf '%s' "$out" | grep -qF '[Goal: implement the retry backoff because timeouts cascade in prod | phase: plan]' \
  || fail "spine: ACTION prompt should freeze + emit the goal line (got: $out)"
[ "$(jq -r '.goal // ""' "$SP_BRAIN/.injected/spine-1.json")" = "implement the retry backoff because timeouts cascade in prod" ] \
  || fail "spine: goal not frozen in the memo"
[ -n "$(jq -r '.goal_kw // ""' "$SP_BRAIN/.injected/spine-1.json")" ] \
  || fail "spine: goal keywords not frozen in the memo"
pass "spine: first ACTION prompt freezes goal + emits goal line (phase plan)"

# Spine 2: a later prompt in the same session — wiki/episodic/principles all deduped
# or empty (the simulated post-compaction quiet turn) — STILL carries the goal line
# verbatim, and the whole injection stays within the 200B/turn overhead budget.
out2=$(payload_sid "consider the overall direction again please" "spine-1" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
printf '%s' "$out2" | grep -qF '[Goal: implement the retry backoff because timeouts cascade in prod | phase: plan]' \
  || fail "spine: goal line must re-inject VERBATIM on a quiet turn (got: $out2)"
LEN=$(printf '%s' "$out2" | wc -c | tr -d ' ')
[ "$LEN" -le 200 ] || fail "spine: quiet-turn overhead $LEN bytes exceeds the 200B budget (got: $out2)"
pass "spine: verbatim re-injection on a quiet turn, <=200B overhead"

# Spine 3: the goal is FROZEN — a later ACTION prompt must not overwrite it.
out3=$(payload_sid "fix the flaky login suite right now" "spine-1" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
printf '%s' "$out3" | grep -qF '[Goal: implement the retry backoff' \
  || fail "spine: goal line lost on a later ACTION prompt (got: $out3)"
printf '%s' "$out3" | grep -qF 'flaky login' && fail "spine: later ACTION prompt overwrote the frozen goal"
pass "spine: goal frozen from the FIRST action prompt only"

# Spine 4: the phase token tracks the phase file (plan -> implement here).
printf 'implement' > "$SP_BRAIN/.injected/spine-1.phase"
out4=$(payload_sid "consider the direction once more please" "spine-1" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
printf '%s' "$out4" | grep -qF '| phase: implement]' \
  || fail "spine: phase token should reflect the phase file (got: $out4)"
pass "spine: phase token tracks the phase file"

# Spine 5: kill switch — no goal line anywhere, no goal frozen.
SPOFF_BRAIN=$(mktemp -d)
out5=$(payload_sid "implement the cache warmup because latency spikes" "spine-off" \
  | SB_INTENT_SPINE=off BRAIN_DIR="$SPOFF_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
printf '%s' "$out5" | grep -qF '[Goal: ' && fail "spine: SB_INTENT_SPINE=off must suppress the goal line (got: $out5)"
[ "$(jq -r '.goal // ""' "$SPOFF_BRAIN/.injected/spine-off.json" 2>/dev/null)" = "" ] \
  || fail "spine: SB_INTENT_SPINE=off must not freeze a goal"
pass "spine: SB_INTENT_SPINE=off suppresses anchor + goal line"

# Spine 6: a very long ACTION prompt is capped ONCE at freeze — memo goal <=170
# BYTES of valid UTF-8, and the quiet-turn goal line fits the 200B budget with
# the frame intact (no per-prompt re-trim).
LONGP="implement the mega feature because $(yes 'reasons pile up' | head -20 | tr '\n' ' ')"
payload_sid "$LONGP" "spine-long" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" >/dev/null
G6=$(jq -r '.goal // ""' "$SP_BRAIN/.injected/spine-long.json" | tr -d '\r\n')
GLEN=$(printf '%s' "$G6" | wc -c | tr -d ' ')
[ "$GLEN" -le 170 ] || fail "spine: frozen goal should be capped at 170 bytes (got $GLEN)"
if command -v iconv >/dev/null 2>&1; then
  printf '%s' "$G6" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1 \
    || fail "spine: frozen goal is not valid UTF-8"
fi
out6=$(payload_sid "consider the overall direction again please" "spine-long" \
  | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
LEN6=$(printf '%s' "$out6" | wc -c | tr -d ' ')
[ "$LEN6" -le 200 ] || fail "spine: long-goal line $LEN6 bytes exceeds the 200B budget"
printf '%s' "$out6" | grep -qF '| phase: plan]' || fail "spine: truncation must preserve the frame (got: $out6)"
pass "spine: long goal capped at freeze (memo <=170 bytes valid UTF-8, line <=200B, frame intact)"

# Spine 7: multibyte goal — byte truncation must land on a character boundary
# (no mojibake / replacement chars re-emitted every turn). iconv-gated: the
# freeze path itself falls back to the raw cut where iconv is absent.
if command -v iconv >/dev/null 2>&1; then
  MB_TAIL=$(printf 'タイムアウト再試行%.0s' 1 2 3 4 5 6 7 8)
  payload_sid "implement 国際化のリトライ改善 because $MB_TAIL" "spine-mb" \
    | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" >/dev/null
  G7=$(jq -r '.goal // ""' "$SP_BRAIN/.injected/spine-mb.json" | tr -d '\r\n')
  [ -n "$G7" ] || fail "spine-mb: multibyte goal not frozen"
  G7LEN=$(printf '%s' "$G7" | wc -c | tr -d ' ')
  [ "$G7LEN" -le 170 ] || fail "spine-mb: goal exceeds 170 bytes (got $G7LEN)"
  [ "$(printf '%s' "$G7" | iconv -f utf-8 -t utf-8 -c 2>/dev/null)" = "$G7" ] \
    || fail "spine-mb: goal carries invalid UTF-8 (byte-split character survived)"
  out7=$(payload_sid "consider the overall direction again please" "spine-mb" \
    | BRAIN_DIR="$SP_BRAIN" KNOWLEDGE_DIR="$SP_KNOW" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SP_KNOW" bash "$SCRIPT" | sp_ctx)
  printf '%s' "$out7" | grep -qF '[Goal: implement' || fail "spine-mb: goal line missing (got: $out7)"
  LEN7=$(printf '%s' "$out7" | wc -c | tr -d ' ')
  [ "$LEN7" -le 200 ] || fail "spine-mb: line $LEN7 bytes exceeds the 200B budget"
  pass "spine: multibyte goal truncates on a UTF-8 boundary (no mojibake, <=200B line)"
else
  pass "spine: multibyte truncation skipped (iconv not on PATH)"
fi
rm -rf "$SP_BRAIN" "$SP_KNOW" "$SPOFF_BRAIN"

echo
echo "ALL PASS"
