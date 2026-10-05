#!/bin/bash
# pins: SB_INTENT_SPINE — kill-switch test: asserts =off leaves the legacy advisory path alone
# pins: SB_PERSONA_GATE — kill-switch test: asserts =off is honored (Test 4)
# pins: SB_PERSONA_THINK — D145: kill-switch test: asserts =off refuses ONLY the /? paid-advisor
#   path (distinct from SB_PERSONA_GATE, which disables the whole hook)
# pins: SB_MACHINE_TURN_SKIP — kill-switch test (MT5): asserts =off sends a machine-shaped prompt
#   back to retrieval
# pins: SB_HEADLESS_CONTEXT — opt-in test (HL3): asserts =on restores memory for a headless child
# Tests for scripts/persona-context.sh — UserPromptSubmit hook (Layer 1 + /? route).
# Replaces scripts/intent-gate.sh in v2.3.0.
#
# Implementation note: scripts/persona-context.sh ships without the executable
# bit (hooks.json invokes it as `bash <script>`), so all test invocations here
# go through `bash "$SCRIPT"` rather than `"$SCRIPT"` directly.
set -u
# The hook's headless-child gate keys on these (R1#2): a suite launched from `claude -p`, or from a
# session whose values leak in, must not silently turn every case below into a no-op.
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED SB_HEADLESS_CONTEXT SB_MACHINE_TURN_SKIP SB_NESTED_SPAWN
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/persona-context.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# G2: no case in this file may spawn the real `claude` (a /? prompt against a built bundle used to
# start a real, paid Opus advisor run on every suite pass). A fake `claude` first on PATH drops a
# sentinel if anything reaches it; the sentinel is asserted absent after Test 5 and at the end.
CLAUDE_SPAWNED="$TMP/claude-spawned"
mkdir -p "$TMP/fake-bin"
printf '#!/bin/bash\necho "spawned $*" >> "%s"\nexit 1\n' "$CLAUDE_SPAWNED" > "$TMP/fake-bin/claude"
chmod +x "$TMP/fake-bin/claude"
export PATH="$TMP/fake-bin:$PATH"

# Isolate from the user's real ~/.second-brain. Without this, the per-session
# injection memo persists between test cases (same session_id => deduped output)
# and the test pollutes the user's actual brain dir.
export BRAIN_DIR="$TMP/brain"
mkdir -p "$BRAIN_DIR"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Runtime cases need node (the retrieval CLIs are node bundles). On a dev box without it
# they report a skip; under CI node is provisioned, so a missing node is a broken lane, not a skip.
need_node() {
  command -v node >/dev/null 2>&1 && return 0
  [ -n "${CI:-}" ] && fail "$1: node is not on PATH under CI (the lane provisions it) — refusing to skip"
  return 1
}

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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null \
  || fail "substantive: missing hookSpecificOutput envelope (got: $out)"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("Persona context"; "i")' >/dev/null \
  || fail "substantive: additionalContext missing 'Persona context' header"
pass "substantive prompt emits persona context"

# Test 4: SB_PERSONA_GATE=off honored
out=$(SB_PERSONA_GATE=off bash -c "$(declare -f payload); payload 'implement a new feature with many words to ensure substantive' | bash '$SCRIPT'")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should suppress output (got: $out)"
pass "kill switch honored"

# Test 5 (G2 — hermetic): a /? prompt goes to the persona-think bundle and never further. This case
# used to run against the REAL plugin root, so wherever the bundle was built it started a real, paid
# Opus advisor run on every suite pass, and it passed on empty output too. Now it runs against a
# scratch CLAUDE_PLUGIN_ROOT whose persona-think-cli bundle is a stub (shared with Test 5a), asserts
# the stub's reply is what reaches additionalContext, and asserts the fake `claude` installed first
# on PATH above was never spawned.
# Test 5a (0.32.x /? delivery): with a PRESENT persona-think-cli bundle on the resolved
# THINK_CLI path, a '/? <query>' prompt must deliver the Opus brief to additionalContext.
# We stub the bundle (the script resolves it to $CLAUDE_PLUGIN_ROOT/mcp/dist/cli/
# persona-think-cli.bundle.js) so it prints a sentinel; assert BOTH the sentinel AND the
# '[Persona deep brief' wrapper reach additionalContext. The pre-existing Test 5 passed on
# EMPTY output — so a /? route that silently delivered nothing (bundle path typo, node
# swallow) would have shipped green. This asserts the actual effect.
if need_node "/? (Test 5 + present-bundle 5a)"; then
  THINK_ROOT=$(mktemp -d)
  mkdir -p "$THINK_ROOT/mcp/dist/cli"
  cat > "$THINK_ROOT/mcp/dist/cli/persona-think-cli.bundle.js" <<'STUBJS'
let d='';process.stdin.on('data',c=>{d+=c;});process.stdin.on('end',()=>{
  process.stdout.write('SB_THINK_SENTINEL_42 query=' + d.trim());
});
STUBJS
  T5_BRAIN=$(mktemp -d)
  out=$(payload "/? what's the best approach" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$T5_BRAIN" bash "$SCRIPT" 2>/dev/null)
  [ -n "$out" ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("SB_THINK_SENTINEL_42 query=what.s the best approach")' >/dev/null \
    || fail "G2: /? did not deliver the STUB bundle's reply — the hermetic stub did not run (got: $out)"
  [ ! -e "$CLAUDE_SPAWNED" ] || fail "G2: the /? path spawned \`claude\` ($(cat "$CLAUDE_SPAWNED")) — Test 5 must never start a real advisor run"
  pass "G2: /? routes to the stubbed persona-think bundle and spawns no real claude"
  rm -rf "$T5_BRAIN"

  THINK_BRAIN=$(mktemp -d)
  out=$(payload "/? what is the best caching strategy" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$THINK_BRAIN" bash "$SCRIPT")
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("SB_THINK_SENTINEL_42")' >/dev/null \
    || fail "/? present-bundle: stubbed brief sentinel did NOT reach additionalContext (got: $out)"
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("\\[Persona deep brief")' >/dev/null \
    || fail "/? present-bundle: additionalContext missing the '[Persona deep brief' wrapper (got: $out)"
  pass "/? present-bundle: Opus brief sentinel + '[Persona deep brief' wrapper delivered to additionalContext"

  # Test 5a-ii (D145): the /? path spawns a PAID Opus call with no other user-visible
  # signal that it happened — additionalContext is documentation-after-the-fact for the
  # model, not the human. A one-line stderr notice must fire synchronously.
  ERR=$(payload "/? what is the best caching strategy" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$THINK_BRAIN" bash "$SCRIPT" 2>&1 >/dev/null)
  printf '%s' "$ERR" | grep -qi 'spawning Opus advisor' \
    || fail "D145: no stderr notice when /? spawned the paid advisor (got stderr: $ERR)"
  pass "D145: /? spawning the paid Opus advisor prints a one-line stderr notice"

  # Test 5a-iii (D145): SB_PERSONA_THINK=off refuses ONLY the /? paid-advisor path —
  # distinct from SB_PERSONA_GATE, which disables the whole hook (Test 4 below).
  THINK_BRAIN2=$(mktemp -d)
  out=$(payload "/? what is the best caching strategy" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$THINK_BRAIN2" SB_PERSONA_THINK=off bash "$SCRIPT")
  [ -z "$out" ] || fail "D145: SB_PERSONA_THINK=off should not emit an Opus-brief additionalContext (got: $out)"
  ERR2=$(payload "/? what is the best caching strategy" \
    | CLAUDE_PLUGIN_ROOT="$THINK_ROOT" BRAIN_DIR="$THINK_BRAIN2" SB_PERSONA_THINK=off bash "$SCRIPT" 2>&1 >/dev/null)
  printf '%s' "$ERR2" | grep -qi 'SB_PERSONA_THINK=off' \
    || fail "D145: SB_PERSONA_THINK=off did not explain why /? was refused (got stderr: $ERR2)"
  pass "D145: SB_PERSONA_THINK=off refuses the /? paid advisor without disabling the rest of persona-context"
  rm -rf "$THINK_ROOT" "$THINK_BRAIN" "$THINK_BRAIN2"
else
  echo "SKIP: /? (Test 5 + present-bundle 5a): node not on PATH"
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("persona-think-cli.bundle.js is missing")' >/dev/null \
  || fail "/? missing-bundle: fallback hint ('persona-think-cli.bundle.js is missing') did NOT reach additionalContext — a dead /? would be silently empty (got: $out)"
pass "/? missing-bundle: dead-route fallback hint delivered to additionalContext (never silently empty)"
rm -rf "$NOBUNDLE_ROOT" "$NOBUNDLE_BRAIN"

# Test 6: short action-verb prompt → still substantive (preserved from intent-gate)
out=$(payload "fix the bug in auth" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("test-role-marker") | not' >/dev/null \
  || fail "persona-card must NOT be injected per-prompt in 0.32.0 (got: $out)"
pass "persona-card is NOT injected per-prompt (removed in 0.32.0)"
rm -rf "$BRAIN_DIR_TEST"

# Test 8b: wiki section dedups when wiki hits are unchanged across turns. UNAFFECTED by the
# persona cut — wiki/episodic injection + the per-session memo dedup are unchanged.
# Two DIFFERENT prompts that retrieve the same page: an identical second prompt is an exact repeat
# (R1#1) and never reaches the dedup at all. Deterministic fixture, so no hit is a failure: the
# page grounds on two head terms (widget, gizmo), which the per-prompt gate needs.
BRAIN_DIR_WDEDUP=$(mktemp -d)
KNOW_DIR_WDEDUP=$(mktemp -d)
mkdir -p "$KNOW_DIR_WDEDUP/wiki/entities"
# The hook reads its wiki from CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR (else $HOME/knowledge), never from
# KNOWLEDGE_DIR — without this the case searched the real wiki, found nothing and always "skipped".
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW_DIR_WDEDUP"
cat > "$KNOW_DIR_WDEDUP/wiki/entities/widget-page.md" <<EOF
---
title: "Widget page"
type: entities
description: "documentation about the widget gizmo"
tags: [widget, gizmo]
created: 2026-01-01
updated: 2026-01-01
---

Widget is a gizmo for widget processing. This body stays over 100 characters so the
per-prompt CLI does not treat the page as a stub and skip it (R1#4, 2026-10).
EOF
if need_node "wiki dedup (Test 8b)"; then
  out_w1=$(payload_sid "tell me about the widget gizmo in detail" "wiki-dedup-session" \
    | BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
  out_w2=$(payload_sid "explain the widget gizmo internals once more" "wiki-dedup-session" \
    | BRAIN_DIR="$BRAIN_DIR_WDEDUP" bash "$SCRIPT")
  [ -n "$out_w1" ] && echo "$out_w1" | jq -e '.hookSpecificOutput.additionalContext | test("widget-page")' >/dev/null \
    || fail "wiki dedup: turn 1 did not inject widget-page from the deterministic fixture (got: $out_w1)"
  # Everything deduped and nothing else to say = no output at all, so "no widget-page" alone would
  # also pass for a turn that never ran. .prompts == 2 proves turn 2 went through retrieval and the
  # memo rewrite (a repeat or early exit never bumps it).
  case "$out_w2" in *widget-page*) fail "turn 2: wiki section should be deduped when hits unchanged (got: $out_w2)" ;; esac
  [ "$(jq -r '.prompts // 0' "$BRAIN_DIR_WDEDUP/.injected/wiki-dedup-session.json" 2>/dev/null | tr -d '\r')" = 2 ] \
    || fail "wiki dedup: turn 2 did not run the full retrieval path (memo .prompts != 2), so the dedup was never exercised"
  pass "wiki dedup: unchanged wiki hits suppressed on next turn"
else
  echo "SKIP: wiki dedup (Test 8b): node not on PATH"
fi
rm -rf "$BRAIN_DIR_WDEDUP" "$KNOW_DIR_WDEDUP"
unset CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR

# Test 11 (0.29.4): the keyword stopword filter must whole-LINE match (grep -vxF), not
# word-match (grep -vwF). The tokenizer deliberately preserves hyphens so technical ids
# (claude-4-5, node-modules) survive — but -w treats a hyphen as a word boundary, so an
# identifier whose SEGMENT is a stopword (node-IS-modules) matched the stopword and was
# dropped, and its wiki page was never retrieved. Control-gated like Test 8b: only assert
# when the search bundle actually retrieves the plain-keyword control page in this env.
BRAIN_DIR_HY=$(mktemp -d); KNOW_DIR_HY=$(mktemp -d)
mkdir -p "$KNOW_DIR_HY/wiki/entities"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW_DIR_HY"   # the hook's wiki dir (see Test 8b)
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
$body — $slug reference page. The body stays over 100 characters so the per-prompt
CLI does not treat the page as a stub and skip it (R1#4, 2026-10).
EOF
done
hy_hit() { KNOWLEDGE_DIR="$KNOW_DIR_HY" BRAIN_DIR="$BRAIN_DIR_HY" payload_sid "$1" "$2" \
  | KNOWLEDGE_DIR="$KNOW_DIR_HY" BRAIN_DIR="$BRAIN_DIR_HY" bash "$SCRIPT" \
  | jq -r '.hookSpecificOutput.additionalContext // ""'; }
if need_node "keyword-hyphen (Test 11)"; then
  # Deterministic fixture: the control page MUST be retrieved, or the hyphen assertion proves nothing.
  ctl=$(hy_hit "tell me about widgetcontrol gadget in detail please" "hy-ctl")
  echo "$ctl" | grep -q 'widgetcontrol' \
    || fail "keyword-hyphen control: the plain-keyword page widgetcontrol was not retrieved from the deterministic fixture (got: $ctl)"
  hy=$(hy_hit "explain the node-is-modules dependency resolution order in detail" "hy-test")
  echo "$hy" | grep -q 'node-is-modules' \
    || fail "hyphenated id 'node-is-modules' dropped by the stopword filter (grep -vwF word-match) — its wiki page was not retrieved"
  pass "hyphenated identifiers survive the keyword stopword filter (grep -vxF whole-line)"
else
  echo "SKIP: keyword-hyphen (Test 11): node not on PATH"
fi
rm -rf "$BRAIN_DIR_HY" "$KNOW_DIR_HY"
unset CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR

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

# --- mid-session cache-refresh relink guard --------------------------------
# /plugin update + /reload-plugins re-point CLAUDE_PLUGIN_ROOT to a FRESH version
# dir whose mcp/node_modules junction does not exist yet (the marketplace ships
# dist/, never node_modules). SessionStart's auto-relink only fires at the NEXT
# session, so without a per-prompt guard every prompt for the REST of the current
# session silently degrades to bm25-only (hit three times on 2026-07-30 alone).
RL_ROOT=$(mktemp -d); RL_BRAIN=$(mktemp -d)
mkdir -p "$RL_ROOT/mcp/dist/tools" "$RL_ROOT/bin"
printf 'console.log("")\n' > "$RL_ROOT/mcp/dist/tools/context-serve-cli.bundle.js"
cat > "$RL_ROOT/bin/install-vector-deps.sh" <<'RLS'
#!/bin/bash
echo "$1" >> "$(cd "$(dirname "$0")/.." && pwd)/relink-invoked"
mkdir -p "$(cd "$(dirname "$0")/.." && pwd)/mcp/node_modules/@huggingface/transformers"
exit 0
RLS
chmod +x "$RL_ROOT/bin/install-vector-deps.sh"
printf '{"prompt":"check the model ladder resolution here"}' \
  | CLAUDE_PLUGIN_ROOT="$RL_ROOT" BRAIN_DIR="$RL_BRAIN" bash "$SCRIPT" >/dev/null 2>&1
[ -f "$RL_ROOT/relink-invoked" ] && grep -q -- '--relink-only' "$RL_ROOT/relink-invoked" \
  || fail "relink guard: missing junction did not trigger --relink-only relink"
pass "relink guard: fresh cache without node_modules triggers a no-network relink"
printf '{"prompt":"check the model ladder resolution again"}' \
  | CLAUDE_PLUGIN_ROOT="$RL_ROOT" BRAIN_DIR="$RL_BRAIN" bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c . "$RL_ROOT/relink-invoked")" = "1" ] \
  || fail "relink guard: re-invoked though the junction now exists (must be once-only)"
pass "relink guard: present junction skips the relink (no per-prompt spawn)"
rm -rf "$RL_ROOT" "$RL_BRAIN"

# --- R1#1/R1#2 (0.55.0): machine-turn skip, exact-repeat skip, headless children ------------------
# 68% of per-prompt injections fired on turns no human typed (task notifications, peer messages,
# Stop-hook feedback, wrapped tags), and 122 of 124 foreign `claude -p` children got memory too.
# Hermetic: a scratch CLAUDE_PLUGIN_ROOT whose only content is a stub context-serve-cli bundle. The
# stub appends one line per call to $MT_SENTINEL (the SB_SESSION_ID it was handed and its keywords)
# and prints one wiki hit, so "retrieval ran" is a file on disk, not an inference. lib.sh still loads
# from the real scripts dir (the hook sources it relative to itself). The brain dir carries buddy
# consent (buddy.json react:true + .buddy/<sid>.seen), so a human turn provably emits `[buddy:` and
# the busy marker — the assertions that a machine turn emits neither are therefore not vacuous.
if need_node "machine-turn / headless runtime cases"; then
  MT_ROOT="$TMP/mt-root"; MT_BRAIN="$TMP/mt-brain"; MT_SENT="$TMP/mt-sentinel"
  mkdir -p "$MT_ROOT/mcp/dist/tools" "$MT_BRAIN/.buddy"
  # Dynamic import: valid whether node treats the scratch dir's .js as CommonJS or as an ES module.
  cat > "$MT_ROOT/mcp/dist/tools/context-serve-cli.bundle.js" <<'STUBJS'
import('node:fs').then(({ appendFileSync }) => {
  const s = process.env.MT_SENTINEL;
  if (s) appendFileSync(s, 'sid=' + (process.env.SB_SESSION_ID || '') + ' kw=' + process.argv.slice(2).join(' ') + '\n');
  // "quietcase" in the keywords = nothing found (the hook's nothing-surfaced exit, MT7).
  if (process.argv.slice(2).join(' ').includes('quietcase')) return;
  // A slug unique per call: the hook hash-dedups an unchanged wiki block within a session, and
  // every human turn below must show its own hit.
  process.stdout.write('### [[mt-stub-' + process.pid + ']] - stub hit for the machine-turn tests\n');
});
STUBJS
  printf '{"react":true}\n' > "$MT_BRAIN/buddy.json"
  # mt_run <sid> <prompt> [VAR=value ...]: the hook's stdout. ${1+"$@"}: bash 3.2 + set -u aborts
  # on a bare "$@" when no extra assignments are passed.
  mt_run() {
    local sid="$1" p="$2"; shift 2
    : > "$MT_BRAIN/.buddy/$sid.seen"
    payload_sid "$p" "$sid" \
      | env CLAUDE_PLUGIN_ROOT="$MT_ROOT" BRAIN_DIR="$MT_BRAIN" MT_SENTINEL="$MT_SENT" ${1+"$@"} bash "$SCRIPT" 2>/dev/null
  }
  mt_calls() { if [ -f "$MT_SENT" ]; then grep -c . "$MT_SENT" | tr -d ' '; else echo 0; fi; }
  mt_prompts() { jq -r '.prompts // 0' "$MT_BRAIN/.injected/$1.json" 2>/dev/null | tr -d '\r'; }
  mt_ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | tr -d '\r'; }
  mt_memo_sig() { if [ -f "$MT_BRAIN/.injected/$1.json" ]; then cksum < "$MT_BRAIN/.injected/$1.json"; else echo none; fi; }
  # mt_assert_human <label> <sid> <prompt> [VAR=value ...]: the turn reaches retrieval.
  mt_assert_human() {
    local label="$1" sid="$2" p="$3" out ctx; shift 3
    rm -f "$MT_SENT"
    out=$(mt_run "$sid" "$p" ${1+"$@"})
    [ "$(mt_calls)" = 1 ] || fail "$label: a human-typed prompt must reach retrieval (stub CLI calls=$(mt_calls), out: $out)"
    ctx=$(mt_ctx "$out")
    printf '%s' "$ctx" | grep -qE '\[\[mt-stub-[0-9]+\]\]' || fail "$label: the stub wiki hit did not reach additionalContext (got: $out)"
  }
  # mt_assert_machine <label> <sid> <prompt>: the turn is skipped whole — no retrieval, no output
  # at all (no [Wiki, no [buddy:, no goal line), no memo rewrite (.prompts / goal freeze) — but the
  # busy marker is still stamped, because the statusline must still show the turn as running.
  mt_assert_machine() {
    local label="$1" sid="$2" p="$3" before after out
    rm -f "$MT_SENT" "$MT_BRAIN/.buddy/$sid.busy"
    before=$(mt_memo_sig "$sid")
    out=$(mt_run "$sid" "$p")
    case "$out" in *'[Wiki'*|*'[buddy:'*) fail "$label: a machine turn leaked [Wiki / [buddy: (got: $out)" ;; esac
    [ -z "$out" ] || fail "$label: a machine turn must write no additionalContext (got: $out)"
    [ ! -f "$MT_SENT" ] || fail "$label: a machine turn reached retrieval (the stub CLI ran: $(cat "$MT_SENT"))"
    after=$(mt_memo_sig "$sid")
    [ "$before" = "$after" ] || fail "$label: a machine turn rewrote the session memo (.prompts bump / goal freeze)"
    [ -f "$MT_BRAIN/.buddy/$sid.busy" ] || fail "$label: the busy marker must still be stamped before the skip"
  }

  # MT0 (control): a human turn reaches retrieval, the [buddy: line, the busy marker and the memo.
  rm -f "$MT_SENT"
  out=$(mt_run mt-seq "implement the retry backoff because timeouts cascade in prod")
  [ "$(mt_calls)" = 1 ] || fail "MT0: control human prompt did not reach the stub retrieval CLI (calls=$(mt_calls))"
  ctx=$(mt_ctx "$out")
  printf '%s' "$ctx" | grep -qF '[Wiki' || fail "MT0: control human prompt got no [Wiki block (got: $out)"
  printf '%s' "$ctx" | grep -qF '[buddy:' || fail "MT0: control human prompt got no [buddy: line (got: $out)"
  [ -f "$MT_BRAIN/.buddy/mt-seq.busy" ] || fail "MT0: control human prompt stamped no busy marker"
  [ "$(mt_prompts mt-seq)" = 1 ] || fail "MT0: control human prompt did not count in .prompts (got $(mt_prompts mt-seq))"
  [ -n "$(jq -r '.goal // ""' "$MT_BRAIN/.injected/mt-seq.json" | tr -d '\r')" ] || fail "MT0: control ACTION prompt froze no goal"
  pass "MT0: control — a human prompt reaches retrieval, [Wiki, [buddy:, the busy marker and .prompts"

  # MT1: a task notification (the most common machine turn), alone and wrapped in whitespace / a BOM.
  mt_assert_machine "MT1 notification" mt-seq $'<task-notification>\n<task-id>b7f3c1</task-id>\n<status>completed</status>\n<summary>Agent "fix the parser" completed</summary>\n</task-notification>'
  mt_assert_machine "MT1 notification after whitespace" mt-seq $' \t\r\n\n<task-notification>\n<task-id>b7f3c2</task-id>\n<status>failed</status>\n</task-notification>'
  mt_assert_machine "MT1 notification after a BOM" mt-seq $'\xef\xbb\xbf<task-notification>\n<task-id>b7f3c3</task-id>\n<status>completed</status>\n</task-notification>'
  mt_assert_machine "MT1 notification after whitespace + BOM" mt-seq $'  \n\xef\xbb\xbf\t<task-notification>\n<task-id>b7f3c4</task-id>\n<status>completed</status>\n</task-notification>'
  [ "$(mt_prompts mt-seq)" = 1 ] || fail "MT1: .prompts moved on machine turns (got $(mt_prompts mt-seq), want 1)"
  # The skip is observable: one gate=machine-turn TRACE row in sb_log_error gate-row shape, routed
  # to the audit channel (exit_code 0), naming the kind and the session — never the prompt text.
  jq -c 'select(.script == "persona-context.sh" and .exit_code == 0 and ((.message // "") | startswith("gate=machine-turn kind=notification sid=mt-seq")))' \
      "$MT_BRAIN/audit-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
    || fail "MT1: no gate=machine-turn kind=notification TRACE row in audit-log.jsonl ($(tail -3 "$MT_BRAIN/audit-log.jsonl" 2>/dev/null))"
  grep -q 'b7f3c1' "$MT_BRAIN/audit-log.jsonl" "$MT_BRAIN/error-log.jsonl" 2>/dev/null \
    && fail "MT1: the machine-turn trace leaked prompt text into the logs"
  pass "MT1: task notifications (bare, after whitespace, after a BOM) skip retrieval, output and the memo; one gate=machine-turn trace"

  # MT2: a peer session's message.
  mt_assert_machine "MT2 peer" mt-seq $'Another Claude session sent a message:\nthe drainer finished batch 4 with 3 pages written and 2 remaining in the inbox'
  [ "$(mt_prompts mt-seq)" = 1 ] || fail "MT2: .prompts moved on a peer turn"
  pass "MT2: a peer-session message skips retrieval, output and the memo"

  # MT3: Stop-hook feedback, the continuation summary, and every hyphenated-lowercase-tag shape.
  mt_assert_machine "MT3 stop feedback" mt-seq $'Stop hook feedback:\n[verify-gate] run the tests before claiming completion of the parser change'
  mt_assert_machine "MT3 continuation" mt-seq $'This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.'
  mt_assert_machine "MT3 system-reminder" mt-seq $'<system-reminder>\nThe user opened the file scripts/lib.sh in the IDE and selected lines 1-20 of it\n</system-reminder>'
  mt_assert_machine "MT3 agent-message" mt-seq $'<agent-message from="r1-a">\nthe implementer finished the persona context gate and reported three commits\n</agent-message>'
  mt_assert_machine "MT3 command-name" mt-seq $'<command-name>/second-brain:query</command-name>\n<command-message>second-brain:query</command-message>\n<command-args>how does the drainer work</command-args>'
  mt_assert_machine "MT3 local-command-stdout" mt-seq $'<local-command-stdout>Set model to opus and effort to high for the rest of this session</local-command-stdout>'
  mt_assert_machine "MT3 cross-session-message" mt-seq $'<cross-session-message from="peer-7">\nplease rebase onto main before pushing the branch again\n</cross-session-message>'
  mt_assert_machine "MT3 command-message first" mt-seq $'<command-message>second-brain:query</command-message>\n<command-name>/second-brain:query</command-name>'
  mt_assert_machine "MT3 command-args first" mt-seq $'<command-args>how does the drainer work</command-args>\n<command-name>/second-brain:query</command-name>'
  mt_assert_machine "MT3 local-command-stderr" mt-seq $'<local-command-stderr>Error: unknown model name given to the set model command</local-command-stderr>'
  [ "$(mt_prompts mt-seq)" = 1 ] || fail "MT3: .prompts moved on Stop-feedback / tag turns"
  pass "MT3: Stop-hook feedback, the continuation summary and the allowlisted harness tags (<system-reminder>, <agent-message, <command-name/-message/-args>, <local-command-, <cross-session-message) all skip"

  # MT4: human shapes that must still reach retrieval. <pasted_content uses an underscore, so it is
  # not a hyphenated tag even when a hyphen appears later in the same line; a plain HTML tag is not
  # hyphenated; leading whitespace and a BOM are stripped only for classification.
  mt_assert_human "MT4 pasted_content" mt4-a '<pasted_content id="1">the stack trace from the failing build</pasted_content> what is wrong here'
  mt_assert_human "MT4 pasted_content with a later hyphen" mt4-b '<pasted_content foo-bar> the stack trace text </pasted_content> explain the failure please'
  mt_assert_human "MT4 BOM + whitespace human prompt" mt4-c $'\xef\xbb\xbf  \n\t  explain how the retry backoff works in this repo'
  mt_assert_human "MT4 plain html tag" mt4-d '<div>review the markup of this landing page please</div>'
  mt_assert_human "MT4 uppercase tag" mt4-e '<README-NOTES> summarize the release notes for the next version please'
  # A human asking about their own hyphenated component or custom element is not a harness tag:
  # only the allowlisted tags are machine-written (the broad hyphenated-tag rule swallowed these).
  mt_assert_human "MT4 hyphenated component" mt4-f "<my-component> doesn't render after the props change, why"
  mt_assert_human "MT4 custom element" mt4-g '<x-modal> closes on every outside click, how do I keep it open'
  mt_assert_human "MT4 one-letter hyphen tag" mt4-h '<a-x> a one letter tag name the user typed about their markup'
  mt_assert_human "MT4 near-miss of an allowlisted tag" mt4-i '<system-reminders> is the name of my new notification component, review it'
  pass "MT4: <pasted_content>, plain/uppercase/hyphenated user tags and a whitespace/BOM-led human prompt still reach retrieval"

  # MT5: kill switch — SB_MACHINE_TURN_SKIP=off restores today's behaviour (a notification is retrieved).
  mt_assert_human "MT5 SB_MACHINE_TURN_SKIP=off" mt5 $'<task-notification>\n<task-id>c9d8e7</task-id>\n<status>completed</status>\n<summary>retry backoff agent finished</summary>\n</task-notification>' SB_MACHINE_TURN_SKIP=off
  grep -q 'sid=mt5' "$MT_BRAIN/audit-log.jsonl" 2>/dev/null && fail "MT5: SB_MACHINE_TURN_SKIP=off still wrote a machine-turn trace"
  pass "MT5: SB_MACHINE_TURN_SKIP=off sends a notification back to retrieval (no trace)"

  # MT6: an exact repeat of the session's previous prompt (a cron check-in) is skipped; the same
  # prompt in a NEW session is not, and a different prompt after the repeat is not.
  CRON_P="check on the background agents and report their status"
  mt_assert_human "MT6 first cron prompt" mt6-a "$CRON_P"
  [ "$(mt_prompts mt6-a)" = 1 ] || fail "MT6: first cron prompt did not count (got $(mt_prompts mt6-a))"
  mt_assert_machine "MT6 exact repeat" mt6-a "$CRON_P"
  [ "$(mt_prompts mt6-a)" = 1 ] || fail "MT6: the repeat bumped .prompts (got $(mt_prompts mt6-a))"
  jq -c 'select((.message // "") | startswith("gate=machine-turn kind=repeat sid=mt6-a"))' "$MT_BRAIN/audit-log.jsonl" 2>/dev/null \
    | tr -d '\r' | grep -q . || fail "MT6: no gate=machine-turn kind=repeat trace for the repeat"
  mt_assert_machine "MT6 third identical check-in" mt6-a "$CRON_P"
  mt_assert_human "MT6 repeat under SB_MACHINE_TURN_SKIP=off" mt6-a "$CRON_P" SB_MACHINE_TURN_SKIP=off
  mt_assert_human "MT6 same prompt, new session" mt6-b "$CRON_P"
  mt_assert_human "MT6 different prompt after the repeat" mt6-a "now explain the retry backoff in the drainer"
  [ "$(mt_prompts mt6-a)" = 3 ] || fail "MT6: the human prompts after the repeats did not count (got $(mt_prompts mt6-a), want 3)"
  pass "MT6: an exact repeat in the same session is skipped (traced kind=repeat); SB_MACHINE_TURN_SKIP=off, a new session or a new prompt is not"

  # MT7: "the previous prompt" is the previous HUMAN turn, whichever exit it took. A turn that
  # surfaced nothing (B), an ack and a /? turn each record their own signature, so A, B, A runs
  # retrieval for the second A: before the fix only the full-context exit recorded one, and the
  # second A was skipped as a "repeat" of a prompt two turns back.
  mt_last() { jq -r '.last_prompt // ""' "$MT_BRAIN/.injected/$1.json" 2>/dev/null | tr -d '\r'; }
  mt_assert_human "MT7 A" mt7 "$CRON_P"
  MT7_A=$(mt_last mt7); [ -n "$MT7_A" ] || fail "MT7: turn A recorded no last_prompt"
  rm -f "$MT_SENT"
  out=$(mt_run mt7 "quietcase status of the overnight batch please")
  [ "$(mt_calls)" = 1 ] || fail "MT7: turn B must reach retrieval (calls=$(mt_calls))"
  case "$out" in *'[Wiki'*) fail "MT7: turn B was meant to surface nothing (got: $out)" ;; esac
  [ -n "$(mt_last mt7)" ] && [ "$(mt_last mt7)" != "$MT7_A" ] || fail "MT7: the nothing-surfaced turn B did not record its own last_prompt (still $(mt_last mt7))"
  mt_assert_human "MT7 A after B" mt7 "$CRON_P"
  mt_run mt7 "continue" >/dev/null
  [ "$(mt_last mt7)" != "$MT7_A" ] || fail "MT7: the ack turn did not record its own last_prompt"
  mt_assert_human "MT7 A after an ack" mt7 "$CRON_P"
  # A memo that is present but unparseable is never clobbered by the record; the failure is logged.
  printf 'not json' > "$MT_BRAIN/.injected/mt7b.json"
  mt_run mt7b "continue" >/dev/null
  [ "$(cat "$MT_BRAIN/.injected/mt7b.json")" = "not json" ] || fail "MT7: an unparseable memo was overwritten by the last_prompt record"
  jq -c 'select(.script == "persona-context.sh" and .exit_code != 0 and ((.message // "") | test("memo write failed.*sid=mt7b")))' \
      "$MT_BRAIN/error-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q . \
    || fail "MT7: a failed last_prompt write left no error-log breadcrumb ($(tail -2 "$MT_BRAIN/error-log.jsonl" 2>/dev/null))"
  pass "MT7: nothing-surfaced and ack turns record last_prompt, so A, B, A and A, ack, A both retrieve the second A; a bad memo is logged, not clobbered"

  # SID1: the context-serve CLI is handed the payload's session_id as SB_SESSION_ID (it drops
  # same-session episodic rows with it).
  SID1="0f8e9c2a-1b2c-4d5e-8f90-a1b2c3d4e5f6"
  mt_assert_human "SID1" "$SID1" "explain how the retry backoff works in this repo"
  grep -q "^sid=$SID1 kw=" "$MT_SENT" || fail "SID1: the stub CLI did not receive SB_SESSION_ID $SID1 (got: $(cat "$MT_SENT"))"
  pass "SID1: context-serve-cli receives SB_SESSION_ID equal to the payload session_id"

  # FB1 (R1#4): with no combined bundle the hook falls back to knowledge-search-cli, and that call
  # injects per prompt too, so it must ask for the per-prompt gate (SB_INJECT_GATE=1).
  FB_ROOT="$TMP/fb-root"; FB_SENT="$TMP/fb-sentinel"; mkdir -p "$FB_ROOT/mcp/dist/tools"
  cat > "$FB_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js" <<'STUBJS'
import('node:fs').then(({ appendFileSync }) => {
  appendFileSync(process.env.FB_SENTINEL, 'gate=' + (process.env.SB_INJECT_GATE || '') + '\n');
});
STUBJS
  payload_sid "explain how the retry backoff works in this repo" fb1 \
    | env CLAUDE_PLUGIN_ROOT="$FB_ROOT" BRAIN_DIR="$MT_BRAIN" FB_SENTINEL="$FB_SENT" bash "$SCRIPT" >/dev/null 2>&1
  [ -f "$FB_SENT" ] || fail "FB1: the knowledge-search-cli fallback never ran"
  [ "$(tr -d '\r' < "$FB_SENT")" = "gate=1" ] || fail "FB1: the fallback wiki call did not set SB_INJECT_GATE=1 (got: $(cat "$FB_SENT"))"
  pass "FB1: the knowledge-search-cli fallback runs with SB_INJECT_GATE=1"

  # HL1-HL4: foreign headless children (`claude -p`: ATTENDED=0, ENTRYPOINT=sdk-cli) get nothing and
  # write nothing; SB_HEADLESS_CONTEXT=on opts back in; interactive IDE hosts are not headless.
  # mt_assert_headless <label> <sid> [VAR=value ...]
  mt_assert_headless() {
    local label="$1" sid="$2" out; shift 2
    rm -f "$MT_SENT"
    out=$(mt_run "$sid" "explain how the retry backoff works in this repo" ${1+"$@"})
    [ -z "$out" ] || fail "$label: a headless child must get no output (got: $out)"
    [ ! -f "$MT_SENT" ] || fail "$label: a headless child reached retrieval"
    [ ! -e "$MT_BRAIN/.injected/$sid.json" ] || fail "$label: a headless child wrote a session memo"
    [ ! -e "$MT_BRAIN/.buddy/$sid.busy" ] || fail "$label: a headless child stamped a busy marker"
  }
  mt_assert_headless "HL1 ATTENDED=0" hl1 CLAUDE_CODE_SESSION_ATTENDED=0
  mt_assert_headless "HL2 ENTRYPOINT=sdk-cli" hl2 CLAUDE_CODE_ENTRYPOINT=sdk-cli
  mt_assert_human "HL3 SB_HEADLESS_CONTEXT=on + ATTENDED=0" hl3 "explain how the retry backoff works in this repo" SB_HEADLESS_CONTEXT=on CLAUDE_CODE_SESSION_ATTENDED=0
  mt_assert_human "HL4 ENTRYPOINT=claude-vscode + ATTENDED=1" hl4 "explain how the retry backoff works in this repo" CLAUDE_CODE_ENTRYPOINT=claude-vscode CLAUDE_CODE_SESSION_ATTENDED=1
  mt_assert_human "HL4b ENTRYPOINT=sdk-ts (exact match only)" hl4b "explain how the retry backoff works in this repo" CLAUDE_CODE_ENTRYPOINT=sdk-ts CLAUDE_CODE_SESSION_ATTENDED=1
  pass "HL1-HL4: ATTENDED=0 / ENTRYPOINT=sdk-cli are silent with no state writes; SB_HEADLESS_CONTEXT=on opts in; claude-vscode and sdk-ts are not headless"
else
  echo "SKIP: machine-turn / headless runtime cases: node not on PATH"
fi

# --- Static locks (R1#1/R1#2) -------------------------------------------------------------------
SCRIPTS_DIR="${SCRIPT%/persona-context.sh}"

# The machine-turn block is parsed by the archive-side parity test (mcp episodic hygiene, R1#3): every
# case alternative in it that holds a quote or a backslash is read as a machine prefix. So its
# single-quoted strings must be exactly the four text prefixes plus the eight allowlisted harness
# tags (each a `'…'*` pattern), and nothing else: an apostrophe in a comment, a quoted `<` arm (the
# rejected bare-`<` rule) or a human-exclusion branch would be read as one more machine prefix. The
# broad hyphenated-tag arm (`\<[a-z]*-*`) is gone for good: it swallowed a human's own
# `<my-component>` or `<x-modal>` question (MT4), so a lock keeps it from coming back.
MT_BLOCK=$(awk '/^[[:space:]]*# machine-turn:begin/{f=1;next} /^[[:space:]]*# machine-turn:end/{f=0} f' "$SCRIPT")
[ -n "$MT_BLOCK" ] || fail "lock: no '# machine-turn:begin' / '# machine-turn:end' block in persona-context.sh"
MT_QUOTED=$(printf '%s\n' "$MT_BLOCK" | grep -oE "'[^']*'\\*" | LC_ALL=C sort | tr '\n' '|')
MT_WANT=$(printf '%s\n' "'<task-notification>'*" "'Another Claude session sent a message:'*" \
  "'Stop hook feedback:'*" "'This session is being continued from a previous conversation'*" \
  "'<system-reminder>'*" "'<command-name>'*" "'<command-message>'*" "'<command-args>'*" \
  "'<local-command-'*" "'<agent-message'*" "'<cross-session-message'*" | LC_ALL=C sort | tr '\n' '|')
[ "$MT_QUOTED" = "$MT_WANT" ] || fail "lock: machine-turn block prefixes drifted (got: $MT_QUOTED want: $MT_WANT)"
MT_APOS=$(printf '%s' "$MT_BLOCK" | tr -cd "'" | wc -c | tr -d ' ')
[ "$MT_APOS" = 22 ] || fail "lock: the machine-turn block holds $MT_APOS single quotes, want exactly 22 (eleven quoted prefixes, nothing else)"
printf '%s\n' "$MT_BLOCK" | grep -qF '\<' && fail "lock: the machine-turn block carries an escaped-< arm again (the broad hyphenated-tag rule is retired)"
printf '%s\n' "$MT_BLOCK" | grep -q '\[a-z\]' && fail "lock: the machine-turn block carries an [a-z] glob again (the broad hyphenated-tag rule is retired)"
pass "lock: machine-turn block = four text prefixes + seven allowlisted harness tags, no broad tag arm"

# Headless predicate — single source by lock. lib.sh's sb_is_headless_child body is ONE line; every
# hook that cannot afford to source lib.sh first carries an inline copy tagged `# sb-headless-inline`
# whose condition must be byte-identical to it.
HL_COND=$(awk '/^sb_is_headless_child\(\) \{/{getline; sub(/^[[:space:]]+/, ""); print; exit}' "$SCRIPTS_DIR/lib.sh")
[ -n "$HL_COND" ] || fail "lock: sb_is_headless_child() not found in scripts/lib.sh"
HL_REPORT=$(cd "$SCRIPTS_DIR" && HL_COND="$HL_COND" awk '
  /# sb-headless-inline$/ && $0 !~ /^[[:space:]]*#/ {
    n++; line = $0; sub(/^[[:space:]]+/, "", line)
    if (!sub(/ && exit 0  # sb-headless-inline$/, "", line) || line != ENVIRON["HL_COND"]) print "DRIFT " FILENAME ": " $0
    else print "COPY " FILENAME
  }
  END { print "COUNT " n + 0 }' ./*.sh)
printf '%s\n' "$HL_REPORT" | grep -q '^DRIFT' && fail "lock: an inline headless-child copy drifted from lib.sh:
$(printf '%s\n' "$HL_REPORT" | grep '^DRIFT')
lib.sh: $HL_COND"
for f in persona-context.sh discover-installed.sh; do
  printf '%s\n' "$HL_REPORT" | grep -qx "COPY ./$f" || fail "lock: $f carries no inline headless-child copy"
done
[ "$(printf '%s\n' "$HL_REPORT" | grep -c '^COPY ')" -ge 2 ] || fail "lock: fewer than 2 inline copies found (vacuous)"
# The two hooks that source lib.sh first call the function itself, before they read stdin.
for f in session-load.sh stop-extract.sh; do
  gl=$(grep -n '^sb_is_headless_child && exit 0$' "$SCRIPTS_DIR/$f" | head -1 | cut -d: -f1)
  [ -n "$gl" ] || fail "lock: $f does not gate on sb_is_headless_child"
  rl=$(grep -nE '\$\(cat( |\))' "$SCRIPTS_DIR/$f" | head -1 | cut -d: -f1)
  [ -n "$rl" ] && [ "$gl" -lt "$rl" ] || fail "lock: $f gates on sb_is_headless_child at line $gl, after reading stdin at line ${rl:-?}"
done
# NEVER a PreToolUse guard: they fail safe and must run for every host, attended or not.
for g in symlink-guard persona-tool-guard wiki-write-guard flow-guard protocol-guard; do
  grep -qE 'sb_is_headless_child|sb-headless-inline|SB_HEADLESS_CONTEXT' "$SCRIPTS_DIR/$g.sh" \
    && fail "lock: PreToolUse guard $g.sh is gated on headless children — guards must never be"
done
pass "lock: every inline headless-child copy is byte-identical to lib.sh; session-load/stop-extract gate before stdin; no guard is gated"

[ ! -e "$CLAUDE_SPAWNED" ] || fail "G2: a case in this file spawned \`claude\`: $(cat "$CLAUDE_SPAWNED")"
pass "G2: no case in this file spawned the real claude"

echo
echo "ALL PASS"
