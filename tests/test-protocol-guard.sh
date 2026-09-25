#!/bin/bash
# pins: SB_PROTOCOL_GUARD — master kill switch (all three modes); we assert both on/off.
# pins: SB_DELEGATION_CHECK — pg_agent kill switch; asserted off ⇒ no output/row.
# pins: SB_DELEGATION_REWRITE — opt-in model rewrite; asserted unset (no updatedInput) and =1.
# pins: SB_ROLE_CARDS — pg_subagent kill switch; asserted off ⇒ no output.
# pins: SB_PROTOCOL_CARD — pg_card kill switch; asserted off ⇒ no stdout.
# pins: SB_MODEL_LADDER — points sb_resolve_model at a fixture manifest with real aliases.
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
run() {
  local mode="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env "$@" HOME="$SB_HOME" BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SB_MODEL_LADDER="$LADDER" bash "$SCRIPT" "$mode"
}
audit_tail() { tail -1 "$BRAIN/audit-log.jsonl" 2>/dev/null | tr -d '\r'; }
audit_all() { cat "$BRAIN/audit-log.jsonl" 2>/dev/null | tr -d '\r'; }
reset_audit() { : > "$BRAIN/audit-log.jsonl"; }

echo "test-protocol-guard.sh"
echo "-----------------------"

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

reset_audit
OUT=$(run pre '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s7","tool_input":{"subagent_type":"Explore","model":"opus","prompt":"find where sb_manifest_add is defined"}}' SB_DELEGATION_REWRITE=1)
RM=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.model // "null"' 2>/dev/null)
RS=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.subagent_type // "null"' 2>/dev/null)
RP=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt // "null"' 2>/dev/null)
[ "$RM" = "haiku" ] && pass "rewrite opt-in: updatedInput.model=haiku" || fail "rewrite opt-in: updatedInput.model=$RM"
[ "$RS" = "Explore" ] && pass "rewrite opt-in: updatedInput.subagent_type preserved" || fail "rewrite opt-in: subagent_type=$RS"
case "$RP" in "find where"*) pass "rewrite opt-in: updatedInput.prompt preserved" ;; *) fail "rewrite opt-in: prompt=$RP" ;; esac
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

# RED (paste in PR): against the scaffold's stub `pg_agent() { :; }`, every case above
# that expects a warn/rewrite gets empty output, and every gate=delegation assertion
# fails because no row is ever written — RED on every subtest in this section.

# ===== pg_subagent (SubagentStart) ====================================================

reset_audit
OUT=$(run subagent '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"a1","session_id":"s3"}')
HEN=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // "null"' 2>/dev/null)
[ "$HEN" = "SubagentStart" ] && pass "subagent role card: hookEventName=SubagentStart" || fail "subagent role card: hookEventName=$HEN"
case "$OUT" in *"Role card"*SCOUT*) pass "subagent role card: contains Role card + SCOUT" ;; *) fail "subagent role card: missing Role card/SCOUT" "$OUT" ;; esac
case "$OUT" in *"HARD (enforced)"*) pass "subagent role card: contains HARD (enforced)" ;; *) fail "subagent role card: missing HARD (enforced)" "$OUT" ;; esac
RBYTES=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
[ "$RBYTES" -le 900 ] && pass "subagent role card: byte length <=900 (got $RBYTES)" || fail "subagent role card: byte length $RBYTES > 900"
case "$(audit_tail)" in
  *'gate=role-card agent=Explore tier=SCOUT'*'verdict=ok'*) pass "subagent role card: row matches" ;;
  *) fail "subagent role card: row wrong" "$(audit_tail)" ;;
esac

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

WRITE_RE='(>>?[[:space:]]?["'"'"']?[A-Za-z0-9_./$}{~-]*(CLAUDE\.md|MEMORY\.md|\.claude/rules))|(^|[[:space:]])(cp|mv|tee)[[:space:]].*(CLAUDE\.md|MEMORY\.md|\.claude/rules)'
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

LOCK_HITS=$(grep -nE 'claude -p|"decision":"block"|settings\.json|permissionDecision:"deny"|permissionDecision:"ask"' "$REPO_ROOT/scripts/protocol-guard.sh" 2>/dev/null || true)
[ -z "$LOCK_HITS" ] && pass "protocol-guard.sh: no claude -p / decision:block / settings.json / deny|ask verdict" \
  || fail "protocol-guard.sh: forbidden construct found" "$LOCK_HITS"

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

echo "-----------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
