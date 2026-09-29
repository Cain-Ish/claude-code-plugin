#!/bin/bash
# pins: SB_PROTOCOL_GUARD — master kill switch (all three modes); we assert both on/off.
# pins: SB_DELEGATION_CHECK — pg_agent kill switch; asserted off ⇒ no output/row.
# pins: SB_DELEGATION_REWRITE — opt-in model rewrite; asserted unset (no updatedInput) and =1.
# pins: SB_ROLE_CARDS — pg_subagent kill switch; asserted off ⇒ no output.
# pins: SB_PROTOCOL_CARD — pg_card kill switch; asserted off ⇒ no stdout.
# pins: SB_MODEL_LADDER — points sb_resolve_model at a fixture manifest with real aliases.
# pins: SB_PERSONA_MODEL, SB_EXTRACTOR_MODEL, SB_MODEL_TIER_FAST — operator pins; asserted
#   they resolve to a dispatch ALIAS (never leak a full model ID into a card or a rewrite).
# pins: SB_NESTED_SPAWN — scrubbed in run()'s hermeticity list so a stray value in the
#   calling shell can't leak into protocol-guard.sh's own re-entrancy guard under test.
# run-all-timeout: 300   (~60 protocol-guard.sh runs, several doing the full live role-card
#   build; 23 s quiet, 76-78 s measured on MSYS under concurrent-suite load, 2026-09-28)
#
# docs/plans/2026-09-24-repo-brain.md Slice 1: SessionStart protocol card, PreToolUse
# Agent/Task delegation-tier warn (+ opt-in rewrite), SubagentStart role cards, and the
# two machine locks (source-scan, hooks wiring) that keep the class-5 protocol honest.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/protocol-guard.sh"
LADDER="$REPO_ROOT/model-ladder.json"

for cmd in jq bash mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done
[ -f "$SCRIPT" ] || { echo "FAIL: scripts/protocol-guard.sh missing"; exit 1; }
[ -f "$LADDER" ] || { echo "FAIL: model-ladder.json missing"; exit 1; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SANDBOX=$(mktemp -d "$TMPDIR_BASE/second-brain-protocol-guard.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
SB_HOME="$SANDBOX/home"
BRAIN="$SANDBOX/home/.second-brain"
mkdir -p "$SB_HOME" "$BRAIN/.injected"

PASS=0
FAIL=0
pass(){ PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail(){ FAIL=$((FAIL + 1)); echo "  FAIL  $1"; shift; [ -n "${1:-}" ] && printf '%s\n' "$1" | sed 's/^/        /'; }

# run <mode> <payload-json> [EXTRA_ENV=val ...]: feeds payload on stdin, returns stdout.
# Hermetic (review fix): every pin/switch this suite exercises is scrubbed from whatever the
# CALLING shell happened to export, so a developer or CI job with e.g. SB_PERSONA_MODEL set
# gets the same result as a clean shell. "$@" (the caller's per-case overrides) comes AFTER
# the -u list so a specific case can still turn a switch on/off on purpose.
run() {
  local mode="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env \
    -u SB_PERSONA_MODEL -u SB_EXTRACTOR_MODEL -u SB_MAINTAIN_LLM_MODEL -u SB_QUALITY_GATE_MODEL \
    -u SB_MODEL_TIER_FAST -u SB_MODEL_TIER_MID -u SB_MODEL_TIER_DEEP -u SB_MODEL_ELASTIC \
    -u SB_DELEGATION_REWRITE -u SB_NESTED_SPAWN -u SB_HOOK_PROFILE -u SB_PROTOCOL_GUARD \
    -u SB_PROTOCOL_CARD -u SB_DELEGATION_CHECK -u SB_ROLE_CARDS -u CLAUDE_PROJECT_DIR \
    "$@" HOME="$SB_HOME" BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SB_MODEL_LADDER="$LADDER" bash "$SCRIPT" "$mode"
}
audit_tail() { tail -1 "$BRAIN/audit-log.jsonl" 2>/dev/null | tr -d '\r'; }
audit_all() { cat "$BRAIN/audit-log.jsonl" 2>/dev/null | tr -d '\r'; }
reset_audit() { : > "$BRAIN/audit-log.jsonl"; }
# ctx_bytes <json-envelope>: byte length of .hookSpecificOutput.additionalContext. jq
# decoding a MULTI-LINE string back to raw newlines on Windows re-triggers the jq-CRLF-stdout
# bug this whole codebase routes around (every jq call elsewhere is piped through
# `tr -d '\r'`) — extracting a card's content for measurement is no exception.
ctx_bytes() { printf '%s' "$1" | jq -j '.hookSpecificOutput.additionalContext' 2>/dev/null | tr -d '\r' | wc -c | tr -d ' '; }

echo "test-protocol-guard.sh"
echo "-----------------------"

# ===== self-check: run() hermeticity (review fix) ====================================
# A stray SB_NESTED_SPAWN=1 exported by the CALLING shell (not passed as a run() override)
# must not leak into the hook under test — proves the env -u scrubbing in run() actually
# protects behavior, not just documents an intent.
export SB_NESTED_SPAWN=1
OUT_HERMETIC=$(run card '{"hook_event_name":"SessionStart","source":"startup","session_id":"s0"}')
unset SB_NESTED_SPAWN
case "$OUT_HERMETIC" in
  *"Working agreement"*) pass "self-check: ambient SB_NESTED_SPAWN=1 does not leak into run() (card still renders)" ;;
  *) fail "self-check: ambient SB_NESTED_SPAWN=1 leaked into run()" "$OUT_HERMETIC" ;;
esac

# ===== card mode =====================================================================

OUT=$(run card '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1"}')
case "$OUT" in
  *"Working agreement"*) pass "card: stdout contains 'Working agreement'" ;;
  *) fail "card: stdout missing 'Working agreement'" "$OUT" ;;
esac
case "$OUT" in
  *"SCOUT=haiku"*) pass "card: SCOUT=haiku (fixture ladder rung 0)" ;;
  *) fail "card: missing 'SCOUT=haiku'" "$OUT" ;;
esac
case "$OUT" in
  *"DO=sonnet"*) pass "card: DO=sonnet" ;;
  *) fail "card: missing 'DO=sonnet'" "$OUT" ;;
esac
case "$OUT" in
  *"THINK=opus"*) pass "card: THINK=opus" ;;
  *) fail "card: missing 'THINK=opus'" "$OUT" ;;
esac
case "$OUT" in
  *'{SCOUT}'*|*'{DO}'*|*'{THINK}'*) fail "card: an unreplaced placeholder survived" "$OUT" ;;
  *) pass "card: no placeholder left unreplaced" ;;
esac
BYTES=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
[ "$BYTES" -le 1200 ] && pass "card: byte length <=1200 (got $BYTES)" || fail "card: byte length $BYTES > 1200"
case "$(audit_all)" in
  *'gate=protocol-card'*'sid=s1'*) pass "card: audit-log has gate=protocol-card ... sid=s1" ;;
  *) fail "card: no gate=protocol-card row for sid=s1" "$(audit_all)" ;;
esac

reset_audit
OUT_OFF=$(run card '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1"}' SB_PROTOCOL_CARD=off)
[ -z "$OUT_OFF" ] && pass "card: SB_PROTOCOL_CARD=off yields empty stdout" || fail "card: SB_PROTOCOL_CARD=off still printed" "$OUT_OFF"
OUT_OFF2=$(run card '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1"}' SB_PROTOCOL_GUARD=off)
[ -z "$OUT_OFF2" ] && pass "card: SB_PROTOCOL_GUARD=off yields empty stdout" || fail "card: SB_PROTOCOL_GUARD=off still printed" "$OUT_OFF2"

# --- review fix: operator pins are surface-blind — a full model ID pinned for a headless
# surface (SB_PERSONA_MODEL, SB_EXTRACTOR_MODEL, SB_MODEL_TIER_FAST here are all full IDs,
# not dispatch aliases) must NOT leak into the dispatch-surface card as a literal; each gets
# ignored (logged once) and the dispatch ladder's own rung 0 alias wins instead.
reset_audit
OUT_PINNED=$(run card '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1p"}' \
  SB_PERSONA_MODEL=claude-opus-4-7 SB_EXTRACTOR_MODEL=claude-sonnet-4-6 SB_MODEL_TIER_FAST=claude-haiku-4-5)
case "$OUT_PINNED" in
  *"SCOUT=haiku"*) pass "operator pins: SCOUT=haiku (surface-blind pins ignored/aliased)" ;;
  *) fail "operator pins: SCOUT != haiku" "$OUT_PINNED" ;;
esac
case "$OUT_PINNED" in
  *"DO=sonnet"*) pass "operator pins: DO=sonnet (SB_EXTRACTOR_MODEL full ID not leaked)" ;;
  *) fail "operator pins: DO != sonnet" "$OUT_PINNED" ;;
esac
case "$OUT_PINNED" in
  *"THINK=opus"*) pass "operator pins: THINK=opus (SB_PERSONA_MODEL full ID not leaked)" ;;
  *) fail "operator pins: THINK != opus" "$OUT_PINNED" ;;
esac

# RED (paste in PR): against the scaffold's stub `pg_card() { :; }`, this whole card
# section prints nothing and no audit row exists — every assertion above fails RED.

# ===== pg_agent (pre mode, Agent/Task) ===============================================

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s2","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find where sb_manifest_add is defined"}}')
case "$OUT" in
  *explore-above-fast*"model: haiku"*|*"model: haiku"*explore-above-fast*) pass "agent explore-above-fast: additionalContext has rule + suggested model" ;;
  *) fail "agent explore-above-fast: additionalContext wrong" "$OUT" ;;
esac
PD=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "null"' 2>/dev/null)
UI=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput // "null"' 2>/dev/null)
[ "$PD" = "null" ] && pass "agent explore-above-fast: permissionDecision null" || fail "agent explore-above-fast: permissionDecision=$PD"
[ "$UI" = "null" ] && pass "agent explore-above-fast: updatedInput null" || fail "agent explore-above-fast: updatedInput=$UI"
ROW=$(audit_tail)
case "$ROW" in
  *'gate=delegation tool=Agent agent=Explore job=scout model=opus effective=opus tier=deep verdict=warn rule=explore-above-fast sid=s2'*)
    pass "agent explore-above-fast: exact gate=delegation row" ;;
  *) fail "agent explore-above-fast: row mismatch" "$ROW" ;;
esac
case "$(audit_all)" in
  *'"verdict":"warn"'*'"rule":"delegation:explore-above-fast"'*) pass "agent explore-above-fast: sb_log_audit row present" ;;
  *) fail "agent explore-above-fast: sb_log_audit row missing" "$(audit_all)" ;;
esac

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s3","tool_input":{"subagent_type":"code-reviewer","model":"haiku","prompt":"adversarial review of the design tradeoffs"}}')
case "$OUT" in *think-at-scout*) pass "agent think-at-scout: rule fires" ;; *) fail "agent think-at-scout: rule missing" "$OUT" ;; esac
case "$(audit_tail)" in *'rule=think-at-scout'*) pass "agent think-at-scout: row has rule" ;; *) fail "agent think-at-scout: row wrong" "$(audit_tail)" ;; esac

# --- review fix: the rewrite and the warn text must share ONE resolved model. A dispatch
# pin holding a full ID (SB_PERSONA_MODEL=claude-opus-4-7, not a dispatch alias) must never
# reach updatedInput.model — the Agent tool's model param is an alias-only enum and would
# reject it outright — so both the suggestion and the rewrite must fall back to the
# ladder's own bare alias ("opus"), not the pinned literal.
reset_audit
OUT_PIN_RW=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s3p","tool_input":{"subagent_type":"code-reviewer","model":"haiku","prompt":"adversarial review of the design tradeoffs"}}' \
  SB_PERSONA_MODEL=claude-opus-4-7 SB_DELEGATION_REWRITE=1)
RWM=$(printf '%s' "$OUT_PIN_RW" | jq -r '.hookSpecificOutput.updatedInput.model // "null"' 2>/dev/null)
[ "$RWM" = "opus" ] && pass "operator pins: rewrite model is the bare alias 'opus', not a pinned full ID" \
  || fail "operator pins: rewrite model=$RWM (expected bare alias 'opus')" "$OUT_PIN_RW"
RWM_PD=$(printf '%s' "$OUT_PIN_RW" | jq -r '.hookSpecificOutput.permissionDecision // "null"' 2>/dev/null)
RWM_HEN=$(printf '%s' "$OUT_PIN_RW" | jq -r '.hookSpecificOutput.hookEventName // "null"' 2>/dev/null)
[ "$RWM_PD" = "allow" ] || fail "operator pins: rewrite must carry permissionDecision=allow (CC ignores updatedInput otherwise), got $RWM_PD" "$OUT_PIN_RW"
[ "$RWM_HEN" = "PreToolUse" ] || fail "operator pins: rewrite must carry hookEventName=PreToolUse, got $RWM_HEN" "$OUT_PIN_RW"
case "$OUT_PIN_RW" in
  *"suggested model: opus"*) pass "operator pins: warn text names the same alias as the rewrite" ;;
  *) fail "operator pins: warn text does not say 'suggested model: opus'" "$OUT_PIN_RW" ;;
esac

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s4","tool_input":{"subagent_type":"my-custom","prompt":"do something"}}')
case "$OUT" in *unpinned-no-model*) pass "agent unpinned-no-model: no pin anywhere -> warn" ;; *) fail "agent unpinned-no-model: expected warn" "$OUT" ;; esac
mkdir -p "$SB_HOME/.claude/agents"
cat > "$SB_HOME/.claude/agents/my-custom.md" <<'MD'
---
name: my-custom
model: sonnet
---
MD
reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s4b","tool_input":{"subagent_type":"my-custom","prompt":"do something"}}')
[ -z "$OUT" ] && pass "agent unpinned-no-model: pinned via \$HOME/.claude/agents -> no output" || fail "agent pinned: unexpected output" "$OUT"
case "$(audit_tail)" in
  *'effective=sonnet'*'verdict=ok'*) pass "agent pinned: effective=sonnet verdict=ok" ;;
  *) fail "agent pinned: row wrong" "$(audit_tail)" ;;
esac
rm -rf "$SB_HOME/.claude/agents"

# --- review fix: unpinned-no-model must not fire for an OMITTED subagent_type (it defaults
# to general-purpose) or for a FOREIGN-plugin agent (`<plugin>:<name>`) whose pin lives
# somewhere this guard can't resolve — only for a truly unpinned agent, or our OWN
# unpinned second-brain:* agent (that one we CAN and should resolve).
reset_audit
OUT_NOSUB=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s4c","tool_input":{"prompt":"implement the login widget"}}')
[ -z "$OUT_NOSUB" ] && pass "unpinned-no-model: omitted subagent_type -> no output (treated as general-purpose)" \
  || fail "unpinned-no-model: omitted subagent_type produced output" "$OUT_NOSUB"
case "$(audit_tail)" in
  *'agent=- '*'verdict=ok rule=-'*) pass "unpinned-no-model: omitted subagent_type -> verdict=ok rule=-" ;;
  *) fail "unpinned-no-model: omitted subagent_type row wrong" "$(audit_tail)" ;;
esac

reset_audit
OUT_FOREIGN=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s4d","tool_input":{"subagent_type":"ecc:code-reviewer","prompt":"implement the login widget"}}')
[ -z "$OUT_FOREIGN" ] && pass "unpinned-no-model: foreign-plugin agent (ecc:code-reviewer) -> no output" \
  || fail "unpinned-no-model: foreign-plugin agent produced output" "$OUT_FOREIGN"
case "$(audit_tail)" in
  *'verdict=ok rule=-'*) pass "unpinned-no-model: foreign-plugin agent -> verdict=ok rule=-" ;;
  *) fail "unpinned-no-model: foreign-plugin agent row wrong" "$(audit_tail)" ;;
esac

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s5","tool_input":{"subagent_type":"second-brain:search-conversations","prompt":"find past decisions on auth"}}')
[ -z "$OUT" ] && pass "agent plugin pin: search-conversations frontmatter honoured -> no output" || fail "agent plugin pin: unexpected output" "$OUT"
case "$(audit_tail)" in
  *'job=scout'*'effective=haiku'*'tier=fast'*'verdict=ok'*) pass "agent plugin pin: row matches" ;;
  *) fail "agent plugin pin: row wrong" "$(audit_tail)" ;;
esac

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6","tool_input":{"subagent_type":"general-purpose","model":"sonnet","prompt":"implement the login widget"}}')
[ -z "$OUT" ] && pass "agent ok row: general-purpose -> no output" || fail "agent ok row: unexpected output" "$OUT"
case "$(audit_tail)" in
  *'gate=delegation'*'verdict=ok rule=-'*) pass "agent ok row: every call is measured (verdict=ok rule=-)" ;;
  *) fail "agent ok row: row missing/wrong" "$(audit_tail)" ;;
esac

# --- review fix: a TEXT-ONLY scout signal (the prompt merely mentions "search"/"find"/etc.,
# with no scout-tier agent or agent-name signal) must not forcibly downgrade an explicit
# model under the opt-in rewrite — it's too weak a signal to override a real DO task. The
# rule still fires (warn; the classifier stays measured), it just never rewrites.
reset_audit
OUT_TXTSCOUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6b","tool_input":{"subagent_type":"general-purpose","model":"opus","prompt":"Fix the crash in the search indexer and add a regression test"}}' SB_DELEGATION_REWRITE=1)
PD_TXT=$(printf '%s' "$OUT_TXTSCOUT" | jq -r '.hookSpecificOutput.permissionDecision // "null"' 2>/dev/null)
UI_TXT=$(printf '%s' "$OUT_TXTSCOUT" | jq -r '.hookSpecificOutput.updatedInput // "null"' 2>/dev/null)
[ "$PD_TXT" = "null" ] && pass "text-only scout signal: permissionDecision null (no forced rewrite)" || fail "text-only scout signal: permissionDecision=$PD_TXT" "$OUT_TXTSCOUT"
[ "$UI_TXT" = "null" ] && pass "text-only scout signal: updatedInput null (no forced rewrite)" || fail "text-only scout signal: updatedInput=$UI_TXT" "$OUT_TXTSCOUT"
case "$(audit_tail)" in
  *'verdict=warn rule=scout-at-think'*) pass "text-only scout signal: row verdict=warn rule=scout-at-think" ;;
  *) fail "text-only scout signal: row wrong" "$(audit_tail)" ;;
esac

# --- review fix: classifier regex parity with §7 — "architecture"/"reviewing"/"designs"
# must still hit the THINK regex (leading boundary only, no trailing boundary), and the
# SCOUT regex must carry "which files?" and "does .* exist".
reset_audit
OUT_ARCH=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6c","tool_input":{"subagent_type":"helper","model":"haiku","prompt":"Evaluate the architecture of the auth module"}}')
case "$(audit_tail)" in *'rule=think-at-scout'*) pass "classifier: 'architecture' hits the THINK regex" ;; *) fail "classifier: 'architecture' did not hit THINK" "$(audit_tail)" ;; esac

reset_audit
OUT_WHICH=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6d","tool_input":{"subagent_type":"helper","model":"opus","prompt":"which files import brain-paths.ts"}}')
case "$(audit_tail)" in *'rule=scout-at-think'*) pass "classifier: 'which files' hits the SCOUT regex" ;; *) fail "classifier: 'which files' did not hit SCOUT" "$(audit_tail)" ;; esac

reset_audit
OUT_EXIST=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6e","tool_input":{"subagent_type":"helper","model":"opus","prompt":"does a helper for CRLF stripping exist anywhere"}}')
case "$(audit_tail)" in *'rule=scout-at-think'*) pass "classifier: 'does .* exist' hits the SCOUT regex" ;; *) fail "classifier: 'does .* exist' did not hit SCOUT" "$(audit_tail)" ;; esac

# An Explore-typed agent (agent-declared scout) whose PROMPT happens to mention a THINK
# keyword ("security") must stay classified scout, never get reclassified think by a
# text-only match — an agent-declared job outranks a text-only signal.
reset_audit
OUT_EXPLORE_SEC=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s6f","tool_input":{"subagent_type":"Explore","model":"haiku","prompt":"Find where the security token check lives and list the files"}}')
case "$(audit_tail)" in
  *'job=scout'*) pass "classifier: Explore + a THINK-keyword prompt stays job=scout" ;;
  *) fail "classifier: Explore + a THINK-keyword prompt was reclassified" "$(audit_tail)" ;;
esac
case "$(audit_tail)" in
  *'rule=think-at-scout'*) fail "classifier: Explore + a THINK-keyword prompt must not fire think-at-scout" "$(audit_tail)" ;;
  *) pass "classifier: Explore + a THINK-keyword prompt does not fire think-at-scout" ;;
esac

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s7","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find where sb_manifest_add is defined","description":"locate sb_manifest_add"}}' SB_DELEGATION_REWRITE=1)
RM=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.model // "null"' 2>/dev/null)
RS=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.subagent_type // "null"' 2>/dev/null)
RP=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt // "null"' 2>/dev/null)
RD=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.description // "null"' 2>/dev/null)
RPD=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "null"' 2>/dev/null)
RHEN=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // "null"' 2>/dev/null)
[ "$RM" = "haiku" ] && pass "rewrite opt-in: updatedInput.model=haiku" || fail "rewrite opt-in: updatedInput.model=$RM"
[ "$RS" = "Explore" ] && pass "rewrite opt-in: updatedInput.subagent_type preserved" || fail "rewrite opt-in: subagent_type=$RS"
case "$RP" in "find where"*) pass "rewrite opt-in: updatedInput.prompt preserved" ;; *) fail "rewrite opt-in: prompt=$RP" ;; esac
[ "$RD" = "locate sb_manifest_add" ] && pass "rewrite opt-in: updatedInput.description preserved" || fail "rewrite opt-in: description=$RD"
[ "$RPD" = "allow" ] || fail "rewrite opt-in: must carry permissionDecision=allow (CC ignores updatedInput otherwise), got $RPD" "$OUT"
[ "$RHEN" = "PreToolUse" ] || fail "rewrite opt-in: must carry hookEventName=PreToolUse, got $RHEN" "$OUT"
case "$(audit_tail)" in *'verdict=rewrite'*) pass "rewrite opt-in: row verdict=rewrite" ;; *) fail "rewrite opt-in: row wrong" "$(audit_tail)" ;; esac
reset_audit
OUT_NOREWRITE=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s7b","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find where sb_manifest_add is defined"}}')
NU=$(printf '%s' "$OUT_NOREWRITE" | jq -r '.hookSpecificOutput.updatedInput // "null"' 2>/dev/null)
[ "$NU" = "null" ] && pass "rewrite opt-in: unset SB_DELEGATION_REWRITE -> no updatedInput" || fail "rewrite opt-in: updatedInput present without opt-in" "$OUT_NOREWRITE"

# plan hint
echo '{"rules":[{"name":"warn-rm-rf","tool":"Bash","action":"ask","reason":"destructive rm -rf without confirmation","enabled":true}]}' > "$BRAIN/persona-rules.json"
reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s8","tool_input":{"subagent_type":"Plan","prompt":"plan the refactor"}}')
case "$OUT" in *plan-no-hard-rules*) pass "plan hint: plan-no-hard-rules fires" ;; *) fail "plan hint: rule missing" "$OUT" ;; esac
case "$OUT" in *"- warn-rm-rf:"*) pass "plan hint: HARD rules line present" ;; *) fail "plan hint: HARD rules line missing" "$OUT" ;; esac
OUT2=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s8b","tool_input":{"subagent_type":"Plan","prompt":"plan the refactor. HARD rules: no rm -rf"}}')
[ -z "$OUT2" ] && pass "plan hint: prompt carrying HARD rules -> verdict=ok, no output" || fail "plan hint: unexpected output" "$OUT2"
rm -f "$BRAIN/persona-rules.json"

# kill switches
reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s9","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find X"}}')
case "$OUT" in *explore-above-fast*) pass "kill switch: positive twin fires without the switch" ;; *) fail "kill switch: positive twin failed" "$OUT" ;; esac
[ -s "$BRAIN/audit-log.jsonl" ] && pass "kill switch: positive twin left a row" || fail "kill switch: no row for positive twin"
reset_audit
OUT_KS=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s9b","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find X"}}' SB_DELEGATION_CHECK=off)
[ -z "$OUT_KS" ] && pass "kill switch: SB_DELEGATION_CHECK=off -> no output" || fail "kill switch: output despite off" "$OUT_KS"
[ ! -s "$BRAIN/audit-log.jsonl" ] && pass "kill switch: SB_DELEGATION_CHECK=off -> no gate=delegation row" || fail "kill switch: row written despite off" "$(audit_all)"

reset_audit
OUT_TASK=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Task","session_id":"s9c","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find X"}}')
case "$OUT_TASK" in *explore-above-fast*) pass "Task tool behaves identically to Agent" ;; *) fail "Task tool did not trigger the same rule" "$OUT_TASK" ;; esac

# --- review fix: the Agent/Task path's steady-state (warm memo, verdict=ok) spawn budget.
# PATH-stub jq/tr/grep/awk/sed/git/date/cygpath/mkdir/mv (idiom copied from
# tests/test-validate-plugin.sh's `claude` stub): each shim appends its own name to
# $SB_SPAWN_LOG then execs the REAL binary captured before PATH changes.
# Floor is 11, not the review finding's naive "cygpath+jq+tr+date+jq+tr"=6 estimate: `source
# lib.sh` itself unconditionally costs a 2nd cygpath (lib.sh's own BRAIN_DIR re-resolution)
# and a hidden jq+tr (kb-schema.sh, sourced BY lib.sh, loading the KB schema once), and
# sb_log_error's sb_rotate_audit_log does two `wc|tr -d ' '` size checks — none of that is
# pg_agent's own code or in this slice's owned files. The number that IS this fix's to own
# is the reduction from 18 (RED, the extra T-jq, Slower-tr and four grep pipelines) to 11.
SPAWN_BIN="$SANDBOX/spawnbin"; mkdir -p "$SPAWN_BIN"
for c in jq tr grep awk sed git date cygpath mkdir mv; do
  real=$(command -v "$c" 2>/dev/null || true)
  [ -n "$real" ] || continue
  cat > "$SPAWN_BIN/$c" <<SH
#!/bin/sh
printf '%s\n' "$c" >> "\$SB_SPAWN_LOG" 2>/dev/null
exec "$real" "\$@"
SH
  chmod +x "$SPAWN_BIN/$c"
done
# Pre-warm the tier-alias memo and slug memo for session "sspawn" via one real (unshimmed) call.
run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"sspawn","tool_input":{"subagent_type":"general-purpose","model":"sonnet","prompt":"implement the login widget"}}' >/dev/null
mkdir -p "$BRAIN/.injected"
printf 'main\n' > "$BRAIN/.injected/sspawn.slug"
SPAWN_LOG="$SANDBOX/spawns"; : > "$SPAWN_LOG"
reset_audit
OUT_SPAWN=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"sspawn","tool_input":{"subagent_type":"general-purpose","model":"sonnet","prompt":"implement the login widget"}}' \
  PATH="$SPAWN_BIN:$PATH" SB_SPAWN_LOG="$SPAWN_LOG")
[ -z "$OUT_SPAWN" ] && pass "spawn budget: warm ok-path still emits no output" || fail "spawn budget: unexpected output" "$OUT_SPAWN"
SPAWN_COUNT=$(wc -l < "$SPAWN_LOG" 2>/dev/null | tr -d ' ')
[ "${SPAWN_COUNT:-99}" -le 11 ] && pass "spawn budget: warm ok-path spawns <=11 external commands (got $SPAWN_COUNT)" \
  || fail "spawn budget: warm ok-path spawned $SPAWN_COUNT external commands (budget <=11)" "$(cat "$SPAWN_LOG" 2>/dev/null)"

# RED (paste in PR): against the scaffold's stub `pg_agent() { :; }`, every case above
# that expects a warn/rewrite gets empty output, and every gate=delegation assertion
# fails because no row is ever written — RED on every subtest in this section.

# ===== pg_subagent (SubagentStart) ====================================================

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"a1","session_id":"s3"}')
HEN=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // "null"' 2>/dev/null)
[ "$HEN" = "SubagentStart" ] && pass "subagent role card: hookEventName=SubagentStart" || fail "subagent role card: hookEventName=$HEN"
case "$OUT" in *"Role card"*SCOUT*) pass "subagent role card: contains Role card + SCOUT" ;; *) fail "subagent role card: missing Role card/SCOUT" "$OUT" ;; esac
# S0 B5: the HARD lines are labelled for what they are — plugin defaults (no repo rules.json here),
# enforced by hooks — not presented as this repo's rules.
case "$OUT" in *"HARD - plugin defaults (all repos), enforced by hooks:"*) pass "subagent role card: HARD block labelled as plugin defaults enforced by hooks" ;; *) fail "subagent role card: missing plugin-defaults HARD label" "$OUT" ;; esac
RBYTES=$(ctx_bytes "$OUT")
[ "$RBYTES" -le 900 ] && pass "subagent role card: byte length <=900 (got $RBYTES)" || fail "subagent role card: byte length $RBYTES > 900"
case "$(audit_tail)" in
  *'gate=role-card agent=Explore tier=SCOUT'*'verdict=ok'*) pass "subagent role card: row matches" ;;
  *) fail "subagent role card: row wrong" "$(audit_tail)" ;;
esac
# S0 B2 miss detection: a `start` line lands in the per-session marker file before any work and
# an `end` line after the row, so a start with no end is a counted miss (a killed hook writes no
# row at all — hook-timer.sh cannot log a kill).
MARKF="$BRAIN/.injected/s3.subagent.tsv"
TAB=$(printf '\t')
if grep -qxF "start${TAB}a1" "$MARKF" 2>/dev/null; then pass "miss detection: start marker 'start<TAB>a1' written"
else fail "miss detection: no 'start<TAB>a1' line in $MARKF" "$(cat "$MARKF" 2>/dev/null)"; fi
if grep -qF "end${TAB}a1${TAB}ok" "$MARKF" 2>/dev/null; then pass "miss detection: end marker 'end<TAB>a1<TAB>ok' written"
else fail "miss detection: no 'end<TAB>a1<TAB>ok' line in $MARKF" "$(cat "$MARKF" 2>/dev/null)"; fi
START_LN=$(grep -nF "start${TAB}a1" "$MARKF" 2>/dev/null | head -1 | cut -d: -f1)
END_LN=$(grep -nF "end${TAB}a1${TAB}" "$MARKF" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$START_LN" ] && [ -n "$END_LN" ] && [ "$START_LN" -lt "$END_LN" ] \
  && pass "miss detection: start precedes end" || fail "miss detection: start/end order wrong (start=$START_LN end=$END_LN)"

# --- review fix (i): the 900 B cap must never drop the mandatory Return: line, and the
# row's hard= must equal what actually rendered — not the pre-truncation rule count.
case "$OUT" in
  *"Return: findings first"*) pass "role card 900B cap: Return: line survives truncation" ;;
  *) fail "role card 900B cap: Return: line missing" "$OUT" ;;
esac
OUT_HARD_LINES=$(printf '%s' "$OUT" | jq -j '.hookSpecificOutput.additionalContext' 2>/dev/null | tr -d '\r' | grep -c '^- ')
ROW_HARD=$(audit_tail); ROW_HARD="${ROW_HARD#*hard=}"; ROW_HARD="${ROW_HARD%% *}"
[ "$ROW_HARD" = "$OUT_HARD_LINES" ] && pass "role card 900B cap: row hard=$ROW_HARD matches rendered '^- ' lines ($OUT_HARD_LINES)" \
  || fail "role card 900B cap: row hard=$ROW_HARD != rendered lines $OUT_HARD_LINES" "$OUT"

# --- review fix (ii): a rule file whose reasons are long, multi-byte (Polish + em-dash)
# text must still respect the byte cap — LC_ALL=C makes ${#card} a byte count, not a char
# count — and the row's bytes= must equal the actual rendered byte length.
LONG_REASON="Zażółć gęślą jaźń — powód numer jeden dla testu limitu bajtowego karty ról, wypełniacz treści do stu znaków."
cat > "$BRAIN/persona-rules.json" <<JSON
{"rules":[
  {"name":"ask-one","tool":"Bash","action":"ask","reason":"$LONG_REASON"},
  {"name":"ask-two","tool":"Bash","action":"ask","reason":"$LONG_REASON"},
  {"name":"ask-three","tool":"Bash","action":"ask","reason":"$LONG_REASON"},
  {"name":"ask-four","tool":"Bash","action":"ask","reason":"$LONG_REASON"},
  {"name":"ask-five","tool":"Bash","action":"ask","reason":"$LONG_REASON"}
]}
JSON
reset_audit
OUT_LONG=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"a1b","session_id":"s3f"}')
LONG_CTX=$(printf '%s' "$OUT_LONG" | jq -j '.hookSpecificOutput.additionalContext' 2>/dev/null | tr -d '\r')
LONG_BYTES=$(ctx_bytes "$OUT_LONG")
[ "$LONG_BYTES" -le 900 ] && pass "role card 900B cap: long multi-byte reasons still <=900 B (got $LONG_BYTES)" \
  || fail "role card 900B cap: long multi-byte reasons exceeded cap ($LONG_BYTES > 900)" "$OUT_LONG"
ROW_LONG=$(audit_tail)
ROW_BYTES="${ROW_LONG#*bytes=}"; ROW_BYTES="${ROW_BYTES%% *}"
[ "$ROW_BYTES" = "$LONG_BYTES" ] && pass "role card 900B cap: row bytes=$ROW_BYTES matches rendered $LONG_BYTES" \
  || fail "role card 900B cap: row bytes=$ROW_BYTES != rendered $LONG_BYTES" "$ROW_LONG"
case "$LONG_CTX" in
  *"(+"*) pass "role card 900B cap: overflow marked with '(+' when rules were dropped" ;;
  *) fail "role card 900B cap: no '(+' overflow marker though rules should have overflowed" "$LONG_CTX" ;;
esac
rm -f "$BRAIN/persona-rules.json"

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"second-brain:raw-drainer","agent_id":"a2","session_id":"s3b"}')
[ -z "$OUT" ] && pass "subagent skip: second-brain: agent -> no output" || fail "subagent skip: unexpected output" "$OUT"
case "$(audit_tail)" in *'verdict=skip reason=second-brain-agent'*) pass "subagent skip: reason=second-brain-agent" ;; *) fail "subagent skip: row wrong" "$(audit_tail)" ;; esac

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Plan","agent_id":"a3","session_id":"s3c"}')
[ -z "$OUT" ] && pass "subagent skip: Plan -> no output" || fail "subagent skip: unexpected output" "$OUT"
case "$(audit_tail)" in *'verdict=skip reason=plan'*) pass "subagent skip: reason=plan" ;; *) fail "subagent skip: row wrong" "$(audit_tail)" ;; esac

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"","agent_id":"a4","session_id":"s3d"}')
[ -z "$OUT" ] && pass "subagent skip: empty agent_type -> no output" || fail "subagent skip: unexpected output" "$OUT"
case "$(audit_tail)" in *'verdict=skip reason=no-agent-type'*) pass "subagent skip: reason=no-agent-type" ;; *) fail "subagent skip: row wrong" "$(audit_tail)" ;; esac

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"a5","session_id":"s3e"}' SB_ROLE_CARDS=off)
[ -z "$OUT" ] && pass "subagent kill switch: SB_ROLE_CARDS=off -> nothing" || fail "subagent kill switch: output despite off" "$OUT"

# --- review fix: silent failures. A common env -u prefix (matches run()'s scrubbing) for
# both direct `env ... bash "$SCRIPT"` calls below, since they each need a SB_MODEL_LADDER
# or CLAUDE_PLUGIN_ROOT override that run()'s own fixed trailing assignments would clobber.
HERMETIC_U="-u SB_PERSONA_MODEL -u SB_EXTRACTOR_MODEL -u SB_MAINTAIN_LLM_MODEL -u SB_QUALITY_GATE_MODEL -u SB_MODEL_TIER_FAST -u SB_MODEL_TIER_MID -u SB_MODEL_TIER_DEEP -u SB_MODEL_ELASTIC -u SB_DELEGATION_REWRITE -u SB_NESTED_SPAWN -u SB_HOOK_PROFILE -u SB_PROTOCOL_GUARD -u SB_PROTOCOL_CARD -u SB_DELEGATION_CHECK -u SB_ROLE_CARDS -u CLAUDE_PROJECT_DIR"

# (i) an unreadable model-ladder.json must log loudly, not just silently disable tier checks.
: > "$BRAIN/error-log.jsonl"
OUT_NOLADDER=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"snoladder","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find X"}}' \
  | env $HERMETIC_U HOME="$SB_HOME" BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SB_MODEL_LADDER="$SANDBOX/missing-ladder.json" bash "$SCRIPT" pre)
ERRLOG_HITS=$(grep -c 'model-ladder unreadable' "$BRAIN/error-log.jsonl" 2>/dev/null); ERRLOG_HITS="${ERRLOG_HITS:-0}"
[ "${ERRLOG_HITS:-0}" -ge 1 ] && pass "silent-failure fix: model-ladder unreadable is logged (got $ERRLOG_HITS)" \
  || fail "silent-failure fix: model-ladder unreadable was not logged" "$(cat "$BRAIN/error-log.jsonl" 2>/dev/null)"

# (ii) a missing protocol.md role block must skip loudly (logged + verdict=skip), not ship
# a card with a blank role section.
FAKEROOT="$SANDBOX/fakeroot"
rm -rf "$FAKEROOT"; mkdir -p "$FAKEROOT/scripts"
cp "$REPO_ROOT/scripts/lib.sh" "$FAKEROOT/scripts/lib.sh"
cp "$REPO_ROOT/scripts/persona-rules.default.json" "$FAKEROOT/scripts/persona-rules.default.json"
: > "$BRAIN/error-log.jsonl"
reset_audit
OUT_NOROLE=$(printf '%s' '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"anr","session_id":"snorole"}' \
  | env $HERMETIC_U HOME="$SB_HOME" BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_ROOT="$FAKEROOT" \
    SB_MODEL_LADDER="$LADDER" bash "$SCRIPT" subagent)
[ -z "$OUT_NOROLE" ] && pass "silent-failure fix: missing role block -> no output" || fail "silent-failure fix: unexpected output" "$OUT_NOROLE"
case "$(audit_tail)" in
  *'verdict=skip reason=no-role-block'*) pass "silent-failure fix: row verdict=skip reason=no-role-block" ;;
  *) fail "silent-failure fix: row wrong" "$(audit_tail)" ;;
esac
ERRLOG_HITS2=$(grep -c 'missing role:SCOUT' "$BRAIN/error-log.jsonl" 2>/dev/null); ERRLOG_HITS2="${ERRLOG_HITS2:-0}"
[ "${ERRLOG_HITS2:-0}" -ge 1 ] && pass "silent-failure fix: 'missing role:SCOUT' logged" \
  || fail "silent-failure fix: 'missing role:SCOUT' not logged" "$(cat "$BRAIN/error-log.jsonl" 2>/dev/null)"

# ===== S0 B2: role cards precomputed at SessionStart, read from a per-session cache ==========
# run_root <plugin-root> <mode> <payload> [ENV=val ...]: run() with a chosen CLAUDE_PLUGIN_ROOT.
run_root() {
  local root="$1" mode="$2" payload="$3"; shift 3
  printf '%s' "$payload" | env $HERMETIC_U "$@" HOME="$SB_HOME" BRAIN_DIR="$BRAIN" \
    CLAUDE_PLUGIN_ROOT="$root" SB_MODEL_LADDER="$LADDER" bash "$SCRIPT" "$mode"
}
CROOT="$SANDBOX/croot"
rm -rf "$CROOT"; mkdir -p "$CROOT/scripts" "$CROOT/skills/using-second-brain"
cp "$REPO_ROOT/scripts/lib.sh" "$REPO_ROOT/scripts/kb-schema.sh" "$REPO_ROOT/scripts/persona-rules.default.json" "$CROOT/scripts/"
cp "$REPO_ROOT/skills/using-second-brain/protocol.md" "$CROOT/skills/using-second-brain/"
RCF="$BRAIN/.injected/scache.rolecard.tsv"
rm -f "$RCF"
reset_audit
OUT_CC=$(run_root "$CROOT" card '{"hook_event_name":"SessionStart","source":"startup","session_id":"scache"}')
case "$OUT_CC" in *"Working agreement"*) pass "rolecard cache: card mode still prints the protocol card" ;; *) fail "rolecard cache: card mode lost its card" "$OUT_CC" ;; esac
if [ -s "$RCF" ]; then pass "rolecard cache: card mode wrote $RCF"; else fail "rolecard cache: card mode wrote no per-session cache"; fi
RC_TIERS=$(grep -cE "^(SCOUT|DO|THINK)${TAB}" "$RCF" 2>/dev/null); RC_TIERS="${RC_TIERS:-0}"
[ "$RC_TIERS" = "3" ] && pass "rolecard cache: all three tiers precomputed" || fail "rolecard cache: $RC_TIERS/3 tiers in cache" "$(cat "$RCF" 2>/dev/null)"

# Structural proof of the cache-hit path: with lib.sh GONE from the plugin root, the live build
# (which sources lib.sh, resolves models, merges rules) cannot run at all — so a card that still
# arrives came from the cache. The PATH shims additionally prove no awk/git/mkdir/mv spawns and
# at most one jq (the payload parse); `date` is allowed once for bash < 4.2 (macOS 3.2).
mv "$CROOT/scripts/lib.sh" "$CROOT/scripts/lib.sh.off"
SPAWN_LOG_RC="$SANDBOX/spawns-rc"; : > "$SPAWN_LOG_RC"
reset_audit
OUT_HIT=$(run_root "$CROOT" subagent '{"hook_event_name":"SubagentStart","agent_type":"general-purpose","agent_id":"ac1","session_id":"scache"}' \
  PATH="$SPAWN_BIN:$PATH" SB_SPAWN_LOG="$SPAWN_LOG_RC")
HEN_HIT=$(printf '%s' "$OUT_HIT" | jq -r '.hookSpecificOutput.hookEventName // "null"' 2>/dev/null | tr -d '\r')
[ "$HEN_HIT" = "SubagentStart" ] && pass "rolecard cache hit: card emitted with lib.sh absent (live build impossible)" \
  || fail "rolecard cache hit: no card without lib.sh — the hot path still needs the live build" "$OUT_HIT"
case "$OUT_HIT" in *"Role card - DO"*"Return: findings first"*) pass "rolecard cache hit: DO card with its Return: line" ;; *) fail "rolecard cache hit: wrong card" "$OUT_HIT" ;; esac
case "$(audit_tail)" in
  *'gate=role-card agent=general-purpose tier=DO'*'verdict=ok'*'src=cache'*'aid=ac1'*'sid=scache'*) pass "rolecard cache hit: row verdict=ok src=cache aid=ac1" ;;
  *) fail "rolecard cache hit: row wrong" "$(audit_tail)" ;;
esac
RC_JQ=$(grep -cx 'jq' "$SPAWN_LOG_RC" 2>/dev/null); RC_JQ="${RC_JQ:-0}"
RC_ALL=$(grep -cv '^date$' "$SPAWN_LOG_RC" 2>/dev/null); RC_ALL="${RC_ALL:-0}"
RC_DATE=$(grep -cx 'date' "$SPAWN_LOG_RC" 2>/dev/null); RC_DATE="${RC_DATE:-0}"
[ "$RC_JQ" -le 1 ] && [ "$RC_ALL" -le 1 ] && [ "$RC_DATE" -le 1 ] \
  && pass "rolecard cache hit: spawns = ${RC_JQ} jq + ${RC_DATE} date, nothing else" \
  || fail "rolecard cache hit: hot path spawned more than one jq (+date)" "$(cat "$SPAWN_LOG_RC" 2>/dev/null)"
mv "$CROOT/scripts/lib.sh.off" "$CROOT/scripts/lib.sh"

# Stale cache -> live build fallback, which also refreshes the cache for the next dispatch.
touch -t 200001010000 "$RCF"
touch -t 200001010000 "$SANDBOX/ref-old"
reset_audit
OUT_LIVE=$(run_root "$CROOT" subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"ac2","session_id":"scache"}')
case "$OUT_LIVE" in *"Role card - SCOUT"*) pass "rolecard stale cache: live build still emits the card" ;; *) fail "rolecard stale cache: no card" "$OUT_LIVE" ;; esac
case "$(audit_tail)" in *'verdict=ok'*'src=live'*) pass "rolecard stale cache: row src=live" ;; *) fail "rolecard stale cache: row not src=live" "$(audit_tail)" ;; esac
[ "$RCF" -nt "$SANDBOX/ref-old" ] && pass "rolecard stale cache: live build rewrote the cache" || fail "rolecard stale cache: cache not refreshed"
reset_audit
run_root "$CROOT" subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"ac3","session_id":"scache"}' >/dev/null
case "$(audit_tail)" in *'src=cache'*) pass "rolecard stale cache: next dispatch is a cache hit again" ;; *) fail "rolecard stale cache: next dispatch not a hit" "$(audit_tail)" ;; esac
# A session slug memo that disagrees with the slug the cache was built for forces a rebuild.
printf 'someotherrepo' > "$BRAIN/.injected/scache.slug"
reset_audit
run_root "$CROOT" subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"ac4","session_id":"scache"}' >/dev/null
case "$(audit_tail)" in *'src=live'*) pass "rolecard cache: slug memo mismatch forces a live rebuild" ;; *) fail "rolecard cache: slug mismatch served a stale card" "$(audit_tail)" ;; esac
rm -f "$BRAIN/.injected/scache.slug"
# A torn/corrupt tier line is never emitted verbatim: it is a logged miss, rebuilt live.
run_root "$CROOT" card '{"hook_event_name":"SessionStart","source":"startup","session_id":"scache"}' >/dev/null
# The rewritten file is the newest input, so only the corrupt line (not staleness) can force a rebuild.
{ head -1 "$RCF"; printf 'SCOUT\t12\t0\tnot-an-envelope\n'; grep -E "^(DO|THINK)${TAB}" "$RCF"; } > "$RCF.x" && mv "$RCF.x" "$RCF"
: > "$BRAIN/error-log.jsonl"
reset_audit
OUT_TORN=$(run_root "$CROOT" subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"ac5","session_id":"scache"}')
case "$OUT_TORN" in *'not-an-envelope'*) fail "rolecard cache: corrupt line was emitted verbatim" "$OUT_TORN" ;; *"Role card - SCOUT"*) pass "rolecard cache: corrupt tier line -> live card, never the raw line" ;; *) fail "rolecard cache: corrupt line -> no card" "$OUT_TORN" ;; esac
case "$(audit_tail)" in *'src=live'*) pass "rolecard cache: corrupt line row src=live" ;; *) fail "rolecard cache: corrupt line row wrong" "$(audit_tail)" ;; esac
grep -q 'role-card cache line for SCOUT unreadable' "$BRAIN/error-log.jsonl" 2>/dev/null && pass "rolecard cache: corrupt line logged (fail loud)" \
  || fail "rolecard cache: corrupt line not logged" "$(cat "$BRAIN/error-log.jsonl" 2>/dev/null)"

# ===== S0 B2: a malformed payload is named as such, not as a missing agent_type ==============
: > "$BRAIN/error-log.jsonl"
reset_audit
OUT_BAD=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"abad","session_id":"sbad"')
BAD_RC=$?
[ "$BAD_RC" -eq 0 ] && pass "bad payload: exit 0" || fail "bad payload: exit $BAD_RC"
[ -z "$OUT_BAD" ] && pass "bad payload: emits nothing" || fail "bad payload: emitted output" "$OUT_BAD"
case "$(audit_tail)" in *'gate=role-card'*'verdict=skip reason=bad-payload'*) pass "bad payload: row verdict=skip reason=bad-payload" ;; *) fail "bad payload: row wrong" "$(audit_tail)" ;; esac
case "$(audit_all)" in *'reason=no-agent-type'*) fail "bad payload: still logged the misleading reason=no-agent-type" "$(audit_all)" ;; *) pass "bad payload: no misleading no-agent-type row" ;; esac
grep -q 'bad-payload' "$BRAIN/error-log.jsonl" 2>/dev/null && pass "bad payload: error-log entry written (fail loud)" \
  || fail "bad payload: no error-log entry" "$(cat "$BRAIN/error-log.jsonl" 2>/dev/null)"
grep -qF "end${TAB}abad${TAB}skip${TAB}bad-payload" "$BRAIN/.injected/sbad.subagent.tsv" 2>/dev/null \
  && pass "bad payload: start/end markers still pair (end ... skip bad-payload)" \
  || fail "bad payload: marker file lacks the end line" "$(cat "$BRAIN/.injected/sbad.subagent.tsv" 2>/dev/null)"
reset_audit
OUT_BAD2=$(run subagent 'this is not json')
[ -z "$OUT_BAD2" ] && pass "bad payload (not JSON): emits nothing" || fail "bad payload (not JSON): emitted output" "$OUT_BAD2"
case "$(audit_tail)" in *'verdict=skip reason=bad-payload'*) pass "bad payload (not JSON): reason=bad-payload" ;; *) fail "bad payload (not JSON): row wrong" "$(audit_tail)" ;; esac
reset_audit
OUT_BAD3=$(run subagent '["SubagentStart"]')
case "$(audit_tail)" in *'verdict=skip reason=bad-payload'*) pass "bad payload (JSON, not an object): reason=bad-payload" ;; *) fail "bad payload (JSON array): row wrong" "$(audit_tail)" ;; esac

# ===== S0 B5: repo rules come first, under their own label ===================================
mkdir -p "$BRAIN/projects/demo"
printf 'demo' > "$BRAIN/.injected/srepo.slug"
cat > "$BRAIN/projects/demo/rules.json" <<'JSON'
{"rules":[{"name":"repo-no-force","tool":"Bash","action":"ask","match_command":"git push --force","reason":"This repo forbids force pushes to shared branches."}]}
JSON
reset_audit
OUT_REPO=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"general-purpose","agent_id":"arepo","session_id":"srepo"}')
CTX_REPO=$(printf '%s' "$OUT_REPO" | jq -j '.hookSpecificOutput.additionalContext' 2>/dev/null | tr -d '\r')
case "$CTX_REPO" in
  *"HARD - this repo (rules.json), enforced by hooks:"*"- repo-no-force:"*"HARD - plugin defaults (all repos), enforced by hooks:"*)
    pass "repo rules: repo label + rule precede the plugin-defaults label" ;;
  *) fail "repo rules: repo rule not first / labels wrong" "$CTX_REPO" ;;
esac
FIRST_HARD=$(printf '%s\n' "$CTX_REPO" | grep '^- ' | head -1)
case "$FIRST_HARD" in "- repo-no-force:"*) pass "repo rules: first HARD line is the repo rule" ;; *) fail "repo rules: first HARD line is '$FIRST_HARD'" "$CTX_REPO" ;; esac
REPO_BYTES=$(ctx_bytes "$OUT_REPO")
[ "$REPO_BYTES" -le 900 ] && pass "repo rules: card still <=900 B (got $REPO_BYTES)" || fail "repo rules: card $REPO_BYTES > 900"
case "$CTX_REPO" in *"Return: findings first, files:lines, <=2k tokens, a Gaps: section."*) pass "repo rules: Return: line kept" ;; *) fail "repo rules: Return: line lost" "$CTX_REPO" ;; esac
REPO_ROW_HARD=$(audit_tail); REPO_ROW_HARD="${REPO_ROW_HARD#*hard=}"; REPO_ROW_HARD="${REPO_ROW_HARD%% *}"
REPO_OUT_HARD=$(printf '%s\n' "$CTX_REPO" | grep -c '^- ')
[ "$REPO_ROW_HARD" = "$REPO_OUT_HARD" ] && pass "repo rules: row hard=$REPO_ROW_HARD matches rendered lines" \
  || fail "repo rules: row hard=$REPO_ROW_HARD != rendered $REPO_OUT_HARD" "$(audit_tail)"
rm -rf "$BRAIN/projects/demo"

# ===== S0 ruler P4: the JIT seen-set is per agent, not per session ===========================
JB="$SANDBOX/jitbrain"; JREPO="$SANDBOX/jrepo"
mkdir -p "$JB/.injected" "$JB/projects/demo" "$JREPO/scripts"
printf 'demo' > "$JB/.injected/sj.slug"
cat > "$JB/projects/demo/jit-index.json" <<'JSON'
{"schema":1,"slug":"demo","generated_at":"2026-01-01T00:00:00Z","git_rev":"abc",
 "items":[{"id":"p1","kind":"lesson","globs":["scripts/lib.sh"],"line":"CRLF breaks readers of scripts/lib.sh"}]}
JSON
jit_read() {  # $1 = agent_id ("" = main thread: PreToolUse from the parent carries no agent_id)
  local extra=""
  [ -n "$1" ] && extra=',"agent_id":"'"$1"'","agent_type":"general-purpose"'
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"sj","cwd":"'"$JREPO"'","tool_input":{"file_path":"'"$JREPO"'/scripts/lib.sh"}'"$extra"'}' \
    | env $HERMETIC_U HOME="$SB_HOME" BRAIN_DIR="$JB" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      SB_MODEL_LADDER="$LADDER" CLAUDE_PROJECT_DIR="$JREPO" bash "$SCRIPT" pre
}
J1=$(jit_read agA); J2=$(jit_read agB); J3=$(jit_read agA); J4=$(jit_read ""); J5=$(jit_read "")
case "$J1" in *'[[p1]]'*) pass "jit per-agent: agent A gets p1" ;; *) fail "jit per-agent: agent A did not get p1" "$J1" ;; esac
case "$J2" in *'[[p1]]'*) pass "jit per-agent: sibling agent B also gets p1 (A did not consume it)" ;; *) fail "jit per-agent: sibling B starved by A's delivery" "$J2" ;; esac
[ -z "$J3" ] && pass "jit per-agent: agent A's repeat Read is silent (once per agent+item)" || fail "jit per-agent: agent A got p1 twice" "$J3"
case "$J4" in *'[[p1]]'*) pass "jit per-agent: main thread keeps its own seen-set (gets p1)" ;; *) fail "jit per-agent: main thread starved by subagents" "$J4" ;; esac
[ -z "$J5" ] && pass "jit per-agent: main thread repeat is silent" || fail "jit per-agent: main thread got p1 twice" "$J5"
J_MAN=$(grep -cxF '{"kind":"jit","id":"p1"}' "$JB/.injected-manifest-sj.jsonl" 2>/dev/null); J_MAN="${J_MAN:-0}"
[ "$J_MAN" = "3" ] && pass "jit per-agent: manifest format unchanged, one {kind:jit,id:p1} line per delivery (3)" \
  || fail "jit per-agent: manifest has $J_MAN p1 lines (want 3)" "$(cat "$JB/.injected-manifest-sj.jsonl" 2>/dev/null)"

# RED (paste in PR): against the scaffold's stub `pg_subagent() { :; }`, every case in
# this section prints nothing and every audit-row assertion fails — RED on all of it.

# ===== protocol.md content lock =======================================================

PMD="$REPO_ROOT/skills/using-second-brain/protocol.md"
[ -f "$PMD" ] && pass "protocol.md exists" || fail "protocol.md missing"
if [ -f "$PMD" ]; then
  CARD_BYTES=$(awk '/^<!-- card:begin/{f=1;next}/^<!-- card:end/{f=0}f' "$PMD" | wc -c | tr -d ' ')
  [ "$CARD_BYTES" -le 1150 ] && pass "protocol.md: card block <=1150 B raw (got $CARD_BYTES)" || fail "protocol.md: card block $CARD_BYTES > 1150"
  for r in SCOUT DO THINK; do
    RB=$(awk "/^<!-- role:${r}:begin/{f=1;next}/^<!-- role:${r}:end/{f=0}f" "$PMD")
    [ -n "$RB" ] && pass "protocol.md: role:$r block present" || fail "protocol.md: role:$r block missing/empty"
  done
  # S0 B5: role blocks state facts, not commands (Claude Code's hook docs: injected context is
  # read as information about the situation; the old imperatives told a research dispatch to
  # "write the test first"). Lock: no second-person address, and no sentence (block start, or
  # after . : ; ! ? or a standalone " - ") opens with an imperative verb. All-caps tokens are tier
  # names or format tokens (SCOUT, DO, THINK, READY), never verbs — DO is not "do".
  IMPERATIVE_WORDS='you|write|end|return|locate|refute|name|assume|budget|run|use|do|don.t|never|always|make|check|keep|follow|report|search|verify|record|think|state|put|include|avoid|prefer|read|list|find|confirm|stop|begin|start|give|provide|ensure|add|fix|edit|change|implement|review|look|go|try|be|let|note|remember|cite|show|answer|reply|finish|close'
  for r in SCOUT DO THINK; do
    RB=$(awk "/^<!-- role:${r}:begin/{f=1;next}/^<!-- role:${r}:end/{f=0}f" "$PMD" | tr -d '\r' | tr '\n' ' ')
    if printf '%s' "$RB" | grep -Eiq '(^|[^[:alpha:]])you([^[:alpha:]]|$)'; then
      fail "protocol.md: role:$r addresses the reader as 'you' (state facts instead)" "$RB"
    else
      pass "protocol.md: role:$r has no second-person address"
    fi
    starts=""; prev="."
    set -f
    for w in $RB; do
      case "$prev" in
        *[.:\;!?]|-)
          w2="${w#"${w%%[[:alpha:]]*}"}"; w2="${w2%%[!\'[:alpha:]]*}"
          case "$w2" in
            '') : ;;
            *[[:lower:]]*|?) starts="$starts$w2
" ;;
            *) : ;;   # all caps: a tier name or format token
          esac
          ;;
      esac
      prev="$w"
    done
    set +f
    bad=$(printf '%s' "$starts" | grep -Eix "$IMPERATIVE_WORDS" | tr '\n' ' ')
    [ -z "$bad" ] && pass "protocol.md: role:$r has no sentence opening with an imperative verb" \
      || fail "protocol.md: role:$r sentences open with imperative verbs: $bad" "$RB"
  done
fi
SKILL_MD="$REPO_ROOT/skills/using-second-brain/SKILL.md"
grep -q 'protocol\.md' "$SKILL_MD" 2>/dev/null && pass "SKILL.md references protocol.md" || fail "SKILL.md does not reference protocol.md"

for f in "$REPO_ROOT"/agents/*.md; do
  fm=$(awk '/^---$/{n++; next} n==1' "$f")
  eff=$(printf '%s\n' "$fm" | grep '^effort:' | head -1 | sed 's/^effort:[[:space:]]*//' | tr -d '\r')
  case "$eff" in
    low|medium|high|xhigh|max) pass "$(basename "$f"): effort=$eff" ;;
    *) fail "$(basename "$f"): missing/invalid effort ('$eff')" ;;
  esac
done

# ===== source-scan lock: no scripts/*.sh writes into .claude/rules, CLAUDE.md, MEMORY.md ====

# review fix: extended with a Write(...) call form and a `sed -i` form — the brief lists
# Write() as a forbidden construct but the original regex only covered shell redirects/cp/mv/tee.
WRITE_RE='(>>?[[:space:]]?["'"'"']?[A-Za-z0-9_./$}{~-]*(CLAUDE\.md|MEMORY\.md|\.claude/rules))|(^|[[:space:]])(cp|mv|tee)[[:space:]].*(CLAUDE\.md|MEMORY\.md|\.claude/rules)|(^|[[:space:]])Write\([^)]*(CLAUDE\.md|MEMORY\.md|\.claude/rules)|(^|[[:space:]])sed[[:space:]]+-i.*(CLAUDE\.md|MEMORY\.md|\.claude/rules)'
HITS=$(grep -rnE "$WRITE_RE" "$REPO_ROOT"/scripts/*.sh 2>/dev/null || true)
[ -z "$HITS" ] && pass "source-scan lock: no scripts/*.sh writes to .claude/rules, CLAUDE.md or MEMORY.md" \
  || fail "source-scan lock: found a write into a locked target" "$HITS"

# Self-test the scanner: it must FAIL (find something) on a deliberately poisoned copy.
POISON="$SANDBOX/poisoned-protocol-guard.sh"
cp "$REPO_ROOT/scripts/protocol-guard.sh" "$POISON"
printf '\necho x >> CLAUDE.md\n' >> "$POISON"
SELFTEST_HITS=$(grep -nE "$WRITE_RE" "$POISON" 2>/dev/null || true)
[ -n "$SELFTEST_HITS" ] && pass "source-scan lock: self-test — scanner FAILS on an injected CLAUDE.md write" \
  || fail "source-scan lock: self-test — scanner missed the injected write (scanner is broken)"

POISON2="$SANDBOX/poisoned2-protocol-guard.sh"
cp "$REPO_ROOT/scripts/protocol-guard.sh" "$POISON2"
printf '%s\n' 'Write("CLAUDE.md", x)' >> "$POISON2"
SELFTEST_HITS2=$(grep -nE "$WRITE_RE" "$POISON2" 2>/dev/null || true)
[ -n "$SELFTEST_HITS2" ] && pass "source-scan lock: self-test 2 — scanner FAILS on an injected Write() call" \
  || fail "source-scan lock: self-test 2 — scanner missed the injected Write() call (scanner is broken)"

# review fix: the lock grep now covers the jq-object and quoted-key forms this script's own
# envelope-building style would actually take, not just the two literal strings it used to.
LOCK_RE='claude -p|"?decision"?[[:space:]]*:[[:space:]]*"block"|settings\.json|"?permissionDecision"?[[:space:]]*:[[:space:]]*"(deny|ask)"|"?permissionDecision"?[[:space:]]*:[[:space:]]*"allow"'
# The ONE legitimate exception is pg_emit_pre's own rewrite envelope — an unconditional allow,
# but gated entirely behind the opt-in SB_DELEGATION_REWRITE=1 flag (its own
# permissionDecisionReason text literally names the flag, which doubles as the exclusion key —
# no other line in this file may say both "permissionDecision":"allow" and that flag name).
LOCK_HITS=$(grep -nE "$LOCK_RE" "$REPO_ROOT/scripts/protocol-guard.sh" 2>/dev/null | grep -v 'SB_DELEGATION_REWRITE=1' || true)
[ -z "$LOCK_HITS" ] && pass "protocol-guard.sh: no claude -p / decision:block / settings.json / deny|ask|allow verdict outside the gated rewrite envelope" \
  || fail "protocol-guard.sh: forbidden construct found" "$LOCK_HITS"

POISON3="$SANDBOX/poisoned3-protocol-guard.sh"
cp "$REPO_ROOT/scripts/protocol-guard.sh" "$POISON3"
printf '%s\n' 'jq -nc {decision:"block"}' >> "$POISON3"
SELFTEST_HITS3=$(grep -nE "$LOCK_RE" "$POISON3" 2>/dev/null || true)
[ -n "$SELFTEST_HITS3" ] && pass "protocol-guard.sh lock: self-test — scanner FAILS on an injected jq-object decision line" \
  || fail "protocol-guard.sh lock: self-test — scanner missed the injected jq-object decision line (scanner is broken)"

POISON4="$SANDBOX/poisoned4-protocol-guard.sh"
cp "$REPO_ROOT/scripts/protocol-guard.sh" "$POISON4"
printf '%s\n' 'printf {"permissionDecision":"deny"}' >> "$POISON4"
SELFTEST_HITS4=$(grep -nE "$LOCK_RE" "$POISON4" 2>/dev/null || true)
[ -n "$SELFTEST_HITS4" ] && pass "protocol-guard.sh lock: self-test — scanner FAILS on an injected quoted-key deny line" \
  || fail "protocol-guard.sh lock: self-test — scanner missed the injected quoted-key deny line (scanner is broken)"

POISON5="$SANDBOX/poisoned5-protocol-guard.sh"
cp "$REPO_ROOT/scripts/protocol-guard.sh" "$POISON5"
printf '%s\n' 'printf {"permissionDecision":"allow"}' >> "$POISON5"
SELFTEST_HITS5=$(grep -nE "$LOCK_RE" "$POISON5" 2>/dev/null | grep -v 'SB_DELEGATION_REWRITE=1' || true)
[ -n "$SELFTEST_HITS5" ] && pass "protocol-guard.sh lock: self-test — scanner FAILS on an injected UNGATED allow line" \
  || fail "protocol-guard.sh lock: self-test — scanner missed the injected ungated allow line (scanner is broken)"

# ===== wiring lock: hooks.json + hooks.notes.md (test-guard-wiring's matcher_for/covers idiom) ====

HJ="$REPO_ROOT/hooks/hooks.json"
matcher_for(){ jq -r --arg g "$1" '.hooks.PreToolUse[]? | select([.hooks[]?.command]|join(" ")|test($g)) | .matcher' "$HJ" | head -1; }
covers(){ local m; m=$(matcher_for "$1"); [ -n "$m" ] || return 1; printf '%s' "$2" | grep -Eq "^(${m})\$"; }
if [ -f "$HJ" ] && jq -e . "$HJ" >/dev/null 2>&1; then
  ok=1
  for t in Task Agent Read Edit Write MultiEdit; do
    covers protocol-guard.sh "$t" || { ok=0; break; }
  done
  [ "$ok" = "1" ] && pass "wiring lock: PreToolUse matcher covers Task Agent Read Edit Write MultiEdit" \
    || fail "wiring lock: PreToolUse matcher does not cover all six tools (matcher='$(matcher_for protocol-guard.sh)')"
  SS=$(jq -r '.hooks.SubagentStart[]? | .hooks[]?.command' "$HJ" 2>/dev/null | grep -c 'protocol-guard.sh')
  [ "${SS:-0}" -gt 0 ] && pass "wiring lock: registered under SubagentStart" || fail "wiring lock: not registered under SubagentStart"
  SS2=$(jq -r '.hooks.SessionStart[]? | .hooks[]?.command' "$HJ" 2>/dev/null | grep -c 'protocol-guard.sh')
  [ "${SS2:-0}" -gt 0 ] && pass "wiring lock: registered under SessionStart" || fail "wiring lock: not registered under SessionStart"
else
  fail "wiring lock: hooks/hooks.json missing or invalid JSON"
fi
HN="$REPO_ROOT/hooks/hooks.notes.md"
for h in "### SessionStart — protocol-guard.sh" "### PreToolUse — protocol-guard.sh" "### SubagentStart — protocol-guard.sh"; do
  grep -qF "$h" "$HN" 2>/dev/null && pass "wiring lock: hooks.notes.md has '$h'" || fail "wiring lock: hooks.notes.md missing '$h'"
done

# ===== CONSTITUTION.md content lock (review fix: stale 'DIRECTION' clause) ============
CONST="$REPO_ROOT/CONSTITUTION.md"
if grep -q 'DIRECTION until the Protocol lock' "$CONST" 2>/dev/null; then
  fail "CONSTITUTION.md: stale 'DIRECTION until the Protocol lock' clause still present"
else
  pass "CONSTITUTION.md: stale 'DIRECTION until the Protocol lock' clause removed"
fi
if grep -qE '(only home|\.claude/rules)' "$CONST" 2>/dev/null; then
  pass "CONSTITUTION.md: 'only home' / '.claude/rules' sanity text still present"
else
  fail "CONSTITUTION.md: 'only home' / '.claude/rules' sanity text missing"
fi
CONST_HITS=$(grep -c 'tests/test-protocol-guard.sh' "$CONST" 2>/dev/null); CONST_HITS="${CONST_HITS:-0}"
[ "${CONST_HITS:-0}" -ge 2 ] && pass "CONSTITUTION.md: tests/test-protocol-guard.sh referenced >=2 times (got $CONST_HITS)" \
  || fail "CONSTITUTION.md: tests/test-protocol-guard.sh referenced <2 times (got $CONST_HITS)"

echo "-----------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
