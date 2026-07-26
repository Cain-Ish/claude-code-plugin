#!/bin/bash
# Guard: plan-first-nudge gates and phase tracking.
#   Spine ON (default): Gate A denies the first multi-file substantive write exactly once
#   (fact-forcing: names the retry path), the retry auto-passes recording plan_ack +
#   declared scope; Gate B warns once on a zero-goal-overlap file set, denies once on a
#   second consecutive set, then dampens; on-scope files never trigger it and reset the
#   consecutive counter; the phase file flips plan→implement on the first substantive edit.
#   Spine OFF: the legacy soft advisory (allow + additionalContext, never blocks).
#   Both modes: silent on single-file work, one-line diffs, non-code files, non-edit tools;
#   kill switches + thresholds honored; malformed input fail-soft.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/plan-first-nudge.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"

BRAIN_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/sb-plan-$$"); export BRAIN_DIR
mkdir -p "$BRAIN_DIR"
trap 'rm -rf "$BRAIN_DIR"' EXIT

big=$(yes 'line' | head -5)     # >= MIN_LINES (3)
one=$(yes 'x' | head -1)        # one-line diff

evt(){ # $1=tool $2=file $3=session $4=content/new_string
  jq -nc --arg f "$2" --arg s "$3" --arg c "$4" \
    "{tool_name:\"$1\",session_id:\$s,tool_input:{file_path:\$f,content:\$c,new_string:\$c}}"
}
seed_memo(){ # $1=sid $2=json — pre-seed the session memo (goal/goal_kw/plan_ack)
  mkdir -p "$BRAIN_DIR/.injected"
  printf '%s' "$2" > "$BRAIN_DIR/.injected/$1.json"
}

# --- Gate A (spine on, the default) ---

# 1. First substantive code file -> silent, and the phase file flips plan->implement
OUT=$(printf '%s' "$(evt Write a.ts S1 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "single code file should be silent (got: $OUT)"
[ -f "$BRAIN_DIR/.injected/S1.phase" ] || fail "phase file not created on first substantive edit"
[ "$(cat "$BRAIN_DIR/.injected/S1.phase")" = "implement" ] || fail "phase should be 'implement'"
pass "single-file edit silent + phase plan->implement"

# 2. Second distinct code file -> Gate A denies ONCE, naming the exact retry path
OUT=$(printf '%s' "$(evt Write b.ts S1 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  || fail "2nd code file should be denied by Gate A (got: $OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason|test("state the plan: goal, files in scope, verify command — then retry")' >/dev/null 2>&1 \
  || fail "Gate A deny must name the exact retry path (got: $OUT)"
[ -f "$BRAIN_DIR/.plan-nudge/S1.gate" ] || fail "Gate A deny marker missing"
pass "Gate A: deny-once with fact-forcing retry instruction"

# 3. Retry (next substantive edit) -> auto-passes silently, records plan_ack + scope
OUT=$(printf '%s' "$(evt Edit c.ts S1 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "retry after Gate A deny must pass silently (got: $OUT)"
[ -f "$BRAIN_DIR/.plan-nudge/S1.done" ] || fail "retry should resolve Gate A (.done missing)"
[ "$(jq -r '.plan_ack // ""' "$BRAIN_DIR/.injected/S1.json")" = "1" ] || fail "plan_ack not recorded to memo"
jq -r '.scope // ""' "$BRAIN_DIR/.injected/S1.json" | grep -q 'a.ts' || fail "declared scope not recorded to memo"
pass "Gate A: retry auto-passes, plan_ack + declared scope recorded"

# 4. Later files, same session -> silent (deny fired at most once)
OUT=$(printf '%s' "$(evt Write d.ts S1 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "Gate A must deny at most once per session (got: $OUT)"
pass "Gate A: deny-once (later files silent)"

# --- Cheap-exit paths (mode-independent) ---

# 5. One-line diffs across two files (new session) -> silent (below MIN_LINES, never counted)
printf '%s' "$(evt Write a.ts S2 "$one")" | bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S2 "$one")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "one-line diffs must stay silent"
pass "one-line diffs silent"

# 6. Non-code files ignored (two .md files, new session)
printf '%s' "$(evt Write a.md S3 "$big")" | bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.md S3 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "non-code files should be ignored"
pass "non-code files ignored"

# 7. Kill switch (whole script)
printf '%s' "$(evt Write a.ts S4 "$big")" | SB_PLAN_FIRST_NUDGE=off bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S4 "$big")" | SB_PLAN_FIRST_NUDGE=off bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "kill switch should suppress"
pass "SB_PLAN_FIRST_NUDGE=off suppresses"

# 8. Raised threshold tunes Gate A (need 3 files; 2 should stay silent, new session)
printf '%s' "$(evt Write a.ts S5 "$big")" | SB_PLAN_FIRST_FILES=3 bash "$SC" >/dev/null 2>&1
OUT=$(printf '%s' "$(evt Write b.ts S5 "$big")" | SB_PLAN_FIRST_FILES=3 bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "raised threshold should keep 2 files silent"
pass "SB_PLAN_FIRST_FILES tunes the threshold"

# 9. Non-edit tool + malformed input fail-soft
[ -z "$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$SC" 2>/dev/null)" ] || fail "Bash should be ignored"
[ -z "$(printf 'not json' | bash "$SC" 2>/dev/null)" ] || fail "malformed should be silent"
pass "non-edit tool ignored + malformed fail-soft"

# --- Legacy advisory (SB_INTENT_SPINE=off) ---

# 10. Spine off -> the original once-per-session soft nudge; no phase file, never blocks
printf '%s' "$(evt Write a.ts S6 "$big")" | SB_INTENT_SPINE=off bash "$SC" >/dev/null 2>&1
[ -f "$BRAIN_DIR/.injected/S6.phase" ] && fail "spine off must not write a phase file"
OUT=$(printf '%s' "$(evt Write b.ts S6 "$big")" | SB_INTENT_SPINE=off bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'Plan-first' || fail "spine off: 2nd code file should soft-nudge"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1 || fail "advisory must allow"
printf '%s' "$OUT" | grep -qiE '"deny"|"ask"' && fail "advisory must never block/ask"
OUT=$(printf '%s' "$(evt Edit c.ts S6 "$big")" | SB_INTENT_SPINE=off bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "advisory should fire at most once per session"
[ "$(grep -c . "$BRAIN_DIR/.plan-nudge/S6.seen")" = "2" ] \
  || fail "advisory mode must stop registering after the one-shot (.seen grew)"
pass "SB_INTENT_SPINE=off: legacy advisory (allow, once, no phase file, .seen frozen after fire)"

# --- Gate B (drift re-grounding) ---
GB_MEMO='{"goal":"improve the widget auth flow because logins time out","goal_kw":"widget auth flow","plan_ack":"1"}'

# 11. Warn once on the first zero-overlap set, deny once on the second, dampen after
seed_memo S7 "$GB_MEMO"
for f in zebra1 zebra2 zebra3; do
  OUT=$(printf '%s' "$(evt Write "$f.ts" S7 "$big")" | bash "$SC" 2>/dev/null)
  [ -z "$OUT" ] || fail "below drift threshold must be silent ($f got: $OUT)"
done
OUT=$(printf '%s' "$(evt Write zebra4.ts S7 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext|test("Re-ground")' >/dev/null 2>&1 \
  || fail "4th zero-overlap file should warn (got: $OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext|test("widget auth flow because")' >/dev/null 2>&1 \
  || fail "drift warn must quote the frozen goal (got: $OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput|has("permissionDecision")|not' >/dev/null 2>&1 \
  || fail "drift warn must NOT carry a permissionDecision (got: $OUT)"
[ -f "$BRAIN_DIR/.plan-nudge/S7.driftwarn" ] || fail "drift warn marker missing"
for f in zebra5 zebra6 zebra7; do
  OUT=$(printf '%s' "$(evt Write "$f.ts" S7 "$big")" | bash "$SC" 2>/dev/null)
  [ -z "$OUT" ] || fail "second set below threshold must be silent ($f got: $OUT)"
done
OUT=$(printf '%s' "$(evt Write zebra8.ts S7 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  || fail "second consecutive zero-overlap set should deny (got: $OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason|test("confirm scope change or return to goal — then retry")' >/dev/null 2>&1 \
  || fail "Gate B deny must name the exact retry path (got: $OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason|test("widget auth flow because")' >/dev/null 2>&1 \
  || fail "Gate B deny must quote the frozen goal (got: $OUT)"
jq -r '.scope_queued // ""' "$BRAIN_DIR/.injected/S7.json" | grep -q 'zebra' \
  || fail "Gate B deny must queue the scope change in the memo"
OUT=$(printf '%s' "$(evt Write zebra9.ts S7 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "after the one deny, drift must dampen (got: $OUT)"
# The post-deny call doubles as the scope-change confirmation: the queued set is
# merged into the declared scope (dedup) and the queue clears.
[ "$(jq -r '.scope_queued // ""' "$BRAIN_DIR/.injected/S7.json")" = "" ] \
  || fail "scope_queued must clear after the post-deny merge"
jq -r '.scope // ""' "$BRAIN_DIR/.injected/S7.json" | grep -q 'zebra8.ts' \
  || fail "queued drift set must merge into the declared scope"
pass "Gate B: warn once -> deny once (goal quoted) -> dampened; queued scope merged on retry"

# 12. On-scope files (keyword overlap) never warn or deny
seed_memo S8 "$GB_MEMO"
for f in auth-a auth-b auth-c auth-d auth-e; do
  OUT=$(printf '%s' "$(evt Write "$f.ts" S8 "$big")" | bash "$SC" 2>/dev/null)
  [ -z "$OUT" ] || fail "on-scope file $f must never trigger Gate B (got: $OUT)"
done
[ -f "$BRAIN_DIR/.plan-nudge/S8.driftwarn" ] && fail "on-scope session must not carry a drift warn marker"
pass "Gate B: on-scope files never flagged"

# 13. An on-scope file RESETS the consecutive zero-overlap counter
seed_memo S9 "$GB_MEMO"
for f in zebra1 zebra2 zebra3 auth-reset zebra4 zebra5 zebra6; do
  OUT=$(printf '%s' "$(evt Write "$f.ts" S9 "$big")" | bash "$SC" 2>/dev/null)
  [ -z "$OUT" ] || fail "reset sequence must stay silent ($f got: $OUT)"
done
[ -f "$BRAIN_DIR/.plan-nudge/S9.driftwarn" ] && fail "counter did not reset on the on-scope file"
pass "Gate B: on-scope file resets the consecutive counter"

# 14. End-to-end Gate A→B (nothing gate-side seeded — only the goal, which
# persona-context owns): the login-bug continuation scenario must produce AT MOST
# ONE warn and ZERO denies, and pre-plan files must never enter a drift set.
seed_memo S11 '{"goal":"fix the login bug because users get logged out","goal_kw":"fix login bug because users get logged out"}'
OUT=$(printf '%s' "$(evt Write src/auth/login.ts S11 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "S11 file1 should be silent (got: $OUT)"
[ -f "$BRAIN_DIR/.plan-nudge/S11.drift" ] && fail "pre-plan file must never enter a drift set"
OUT=$(printf '%s' "$(evt Write src/api/session-routes.ts S11 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  || fail "S11 file2 should hit the real Gate A deny (got: $OUT)"
OUT=$(printf '%s' "$(evt Write src/api/session-routes.ts S11 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "S11 Gate A retry should pass silently (got: $OUT)"
WARNS=0; DENIES=0
for f in src/db/models/user.ts src/utils/retry.ts src/workers/queue.ts src/config/auth-flags.ts \
         src/db/models/session.ts src/utils/backoff.ts src/workers/retry-worker.ts \
         src/config/db-flags.ts src/db/models/token.ts; do
  OUT=$(printf '%s' "$(evt Write "$f" S11 "$big")" | bash "$SC" 2>/dev/null)
  printf '%s' "$OUT" | grep -q 'Re-ground gate' && DENIES=$((DENIES + 1))
  printf '%s' "$OUT" | grep -q '\[Re-ground\]' && WARNS=$((WARNS + 1))
done
[ "$DENIES" -eq 0 ] || fail "continuation scenario must produce ZERO denies (got $DENIES)"
[ "$WARNS" -le 1 ] || fail "continuation scenario must produce AT MOST ONE warn (got $WARNS)"
[ -f "$BRAIN_DIR/.plan-nudge/S11.driftdeny" ] && fail "continuation scenario must never reach the drift deny"
jq -r '.observed_dirs // ""' "$BRAIN_DIR/.injected/S11.json" | grep -q 'src/db/models' \
  || fail "warned dirs should be absorbed into observed_dirs"
pass "Gate B: end-to-end login-bug continuation — <=1 warn, 0 denies, dirs absorbed"

# 15. Segment-boundary prefixes: scope src/utils blesses src/utils/* but NEVER the
# lookalike src/utils-legacy/* — those must still accumulate drift and warn.
seed_memo S12 '{"goal":"improve widget flow because reasons","goal_kw":"improve widget flow because reasons","plan_ack":"1","scope":"src/utils/helpers.ts"}'
OUT=$(printf '%s' "$(evt Write src/utils/deep.ts S12 "$big")" | bash "$SC" 2>/dev/null)
[ -z "$OUT" ] || fail "src/utils/deep.ts is inside the declared boundary — must be silent (got: $OUT)"
for f in a b c; do
  OUT=$(printf '%s' "$(evt Write "src/utils-legacy/$f.ts" S12 "$big")" | bash "$SC" 2>/dev/null)
  [ -z "$OUT" ] || fail "below threshold must be silent (src/utils-legacy/$f.ts got: $OUT)"
done
OUT=$(printf '%s' "$(evt Write src/utils-legacy/d.ts S12 "$big")" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext|test("Re-ground")' >/dev/null 2>&1 \
  || fail "lookalike dir src/utils-legacy must NOT be blessed by scope src/utils (expected warn, got: $OUT)"
pass "Gate B: segment boundary — src/utils never blesses src/utils-legacy"

echo; echo "ALL PASS"
