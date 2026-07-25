#!/usr/bin/env bash
# Behavioral tests for scripts/team-run.sh — the /second-brain:team run ledger (M1 B1).
# Covers: init/task/report round-trip in a SANDBOXED BRAIN_DIR, slug resolution through
# the real sb_resolve_slug (env branch AND the pin fallback branch — per
# feedback_test_fallback_branches), jq -c one-object-per-line + CRLF-clean events.jsonl,
# verify exit-code propagation, fail-loud behavior on bad input, and the mechanical
# ledger locks: write-overlap refusal (split parent/child excepted), escalate-once,
# two-strikes report rejection, max_logical_depth, and the list-open resume check.
# POSIX/bash-3.2/BSD-safe: no mapfile, no GNU-only flags.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TR="$ROOT/scripts/team-run.sh"
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SB="$TMP/.sb"
mkdir -p "$SB/projects/teamproj"
touch "$SB/projects/teamproj/PROJECT.md"
CR=$(printf '\r')

run() { # run <expected-cwd-independent invocation> — env-scoped call with the sandbox brain
  BRAIN_DIR="$SB" CLAUDE_PROJECT_DIR="/home/u/Projects/teamproj" bash "$TR" "$@"
}

# ---------------------------------------------------------------------------
# Test 1 — init creates the per-run ledger under projects/<slug>/teams/ with
# policy defaults, plan, tasks/, and a valid init event.
# ---------------------------------------------------------------------------
RUN=$(run init --goal "test goal" --verify-cmd "exit 0") || fail "init exited nonzero"
[ -n "$RUN" ] || fail "init printed no run_id"
RD="$SB/projects/teamproj/teams/$RUN"
[ -d "$RD/tasks" ]        || fail "init did not create $RD/tasks"
[ -f "$RD/plan.json" ]    || fail "init did not create plan.json"
[ -f "$RD/policy.json" ]  || fail "init did not create policy.json"
[ -f "$RD/events.jsonl" ] || fail "init did not create events.jsonl"
jq -e '.goal=="test goal" and .state=="open"' "$RD/plan.json" >/dev/null || fail "plan.json wrong shape"
jq -e '.max_dispatches==30 and .wave_cap==5 and .max_logical_depth==2 and .verify_cmd=="exit 0"' \
  "$RD/policy.json" >/dev/null || fail "policy.json defaults wrong (want 30/5/2 + pinned verify_cmd)"
jq -e 'select(.event=="init")' "$RD/events.jsonl" >/dev/null || fail "no init event recorded"
pass "init: ledger dir + plan/policy/events created with spec defaults"

# ---------------------------------------------------------------------------
# Test 2 — slug fallback branch: NO CLAUDE_PROJECT_DIR, cwd unknown, pin set.
# sb_resolve_slug must route through the pin (the branch fixtures usually bypass).
# ---------------------------------------------------------------------------
printf 'teamproj' > "$SB/.active-session-slug"
mkdir -p "$TMP/nowhere-special"
RUN2=$(cd "$TMP/nowhere-special" && BRAIN_DIR="$SB" bash -c "unset CLAUDE_PROJECT_DIR; bash '$TR' init --goal 'pin fallback'") \
  || fail "pin-fallback init exited nonzero"
[ -d "$SB/projects/teamproj/teams/$RUN2" ] \
  || fail "pin-fallback init did not land under projects/teamproj (sb_resolve_slug pin branch broken)"
pass "init: pin fallback branch resolves via sb_resolve_slug (no env, unknown cwd)"

# ---------------------------------------------------------------------------
# Test 3 — task-add / task-set / status round-trip.
# ---------------------------------------------------------------------------
run task-add --run "$RUN" --task T1 --goal "design it" --tier THINK --role designer >/dev/null \
  || fail "task-add T1 failed"
run task-add --run "$RUN" --task T2 --goal "build it" --tier DO --role implementer --parent T1 --paths "/a/x.sh,/a/y.sh" >/dev/null \
  || fail "task-add T2 failed"
jq -e '.status=="pending" and .tier=="THINK" and .parent_task==null' "$RD/tasks/T1.json" >/dev/null \
  || fail "T1.json wrong shape"
jq -e '.parent_task=="T1" and (.paths|length==2)' "$RD/tasks/T2.json" >/dev/null \
  || fail "T2.json parent/paths wrong"
run task-set --run "$RUN" --task T2 --status dispatched >/dev/null || fail "task-set dispatched failed"
ST=$(run status --run "$RUN") || fail "status failed"
printf '%s' "$ST" | jq -e '.counts.pending==1 and .counts.dispatched==1 and (.tasks|length==2)' >/dev/null \
  || fail "status summary wrong: $ST"
pass "task-add/task-set/status: DAG round-trip with parent_task + tier preserved"

# duplicate task id refused
run task-add --run "$RUN" --task T1 --goal "again" >/dev/null 2>&1 && fail "duplicate task id accepted"
# unknown parent refused
run task-add --run "$RUN" --task T9 --goal "x" --parent NOPE >/dev/null 2>&1 && fail "unknown parent accepted"
# invalid status refused, record untouched
run task-set --run "$RUN" --task T2 --status bogus >/dev/null 2>&1 && fail "invalid status accepted"
jq -e '.status=="dispatched"' "$RD/tasks/T2.json" >/dev/null || fail "invalid status mutated the record"
# invalid tier / blame refused
run task-add --run "$RUN" --task T8 --goal "x" --tier HUGE >/dev/null 2>&1 && fail "invalid tier accepted"
run task-set --run "$RUN" --task T2 --status failed --blame someone-else >/dev/null 2>&1 && fail "invalid blame accepted"
pass "fail loud: duplicate task, unknown parent, bad status/tier/blame all refused"

# ---------------------------------------------------------------------------
# Test 4 — report-ingest: CRLF-poisoned valid report round-trips clean.
# ---------------------------------------------------------------------------
REPORT='Did the work. Edited two files.
```json
{"v":1,"task_id":"T2","status":"done","artifacts":["a/x.sh","a/y.sh"],"evidence":["edited both per contract"],"learnings":[]}
```'
printf '%s\n' "$REPORT" | awk '{printf "%s\r\n", $0}' \
  | run report-ingest --run "$RUN" --task T2 >/dev/null || fail "report-ingest (CRLF) failed"
jq -e '.status=="done"' "$RD/tasks/T2.json" >/dev/null || fail "report did not set task status"
jq -e '.artifacts|length==2' "$RD/tasks/T2.report.json" >/dev/null || fail "report payload not stored"
grep -q "$CR" "$RD/tasks/T2.report.json" && fail "CR bytes leaked into report payload"
pass "report-ingest: CRLF-poisoned TEAM-REPORT parses, stores payload, sets status"

# BLAME line outside the tail is captured into the task record
run task-add --run "$RUN" --task T3 --goal "blocked one" >/dev/null || fail "task-add T3 failed"
REPORT3='packet missing absolute paths
```json
{"v":1,"task_id":"T3","status":"blocked","artifacts":[],"evidence":["packet field 3 absent"],"learnings":[]}
```
BLAME: caller-under-supplied'
printf '%s\n' "$REPORT3" | run report-ingest --run "$RUN" --task T3 >/dev/null || fail "blocked report-ingest failed"
jq -e '.status=="blocked" and .blame=="caller-under-supplied"' "$RD/tasks/T3.json" >/dev/null \
  || fail "BLAME class not captured into task record"
pass "report-ingest: BLAME line captured with the shipped vocabulary"

# ---------------------------------------------------------------------------
# Test 5 — report-ingest rejects malformed input; the RUN LEDGER carries the
# strike trail (report-rejected events + .strikes) and the SECOND strike
# mechanically fails the task with BLAME child-under-delivered.
# ---------------------------------------------------------------------------
run task-add --run "$RUN" --task T4 --goal "victim" >/dev/null || fail "task-add T4 failed"
# strike 1: nonzero exit, report-rejected event + strikes=1, task still open
printf '%s\n' 'no fence at all' | run report-ingest --run "$RUN" --task T4 >/dev/null 2>&1 \
  && fail "malformed report accepted: no fence"
jq -e '.strikes==1 and .status=="pending"' "$RD/tasks/T4.json" >/dev/null \
  || fail "first strike must record strikes=1 and leave the task open"
jq -e 'select(.event=="report-rejected") | .task_id=="T4" and (.data.reason|length>0) and .data.strikes==1' \
  "$RD/events.jsonl" >/dev/null || fail "no report-rejected event with reason + strike count for T4"
# strike 2: still a nonzero exit AND the ledger flips the task to failed with blame
printf '%s\n' '```json
{"v":2,"task_id":"T4","status":"done"}
```' | run report-ingest --run "$RUN" --task T4 >/dev/null 2>&1 && fail "second malformed report accepted"
jq -e '.strikes==2 and .status=="failed" and .blame=="child-under-delivered"' "$RD/tasks/T4.json" >/dev/null \
  || fail "second strike must fail the task with BLAME child-under-delivered"
# the rest of the malformed battery still rejects loudly
for bad in \
  '```json
{"v":1,"task_id":"WRONG","status":"done"}
```' \
  '```json
{"v":1,"task_id":"T4","status":"finished"}
```' \
  '```json
{"v":1,"task_id":"T4","status":"done","request_team":{"goal":"g","tasks":[]}}
```' \
  '```json
{not json}
```'; do
  printf '%s\n' "$bad" | run report-ingest --run "$RUN" --task T4 >/dev/null 2>&1 \
    && fail "malformed report accepted: $bad"
done
[ -f "$RD/tasks/T4.report.json" ] && fail "malformed report left a payload file"
pass "report-ingest: malformed battery rejected; strike trail in ledger; second strike fails the task"

# a valid split report IS accepted
REPORT5='needs decomposition
```json
{"v":1,"task_id":"T4","status":"split","artifacts":[],"evidence":[],"request_team":{"goal":"sub-work","tasks":[{"role":"implementer","skills":[],"inputs":"x"}]},"learnings":[]}
```'
printf '%s\n' "$REPORT5" | run report-ingest --run "$RUN" --task T4 >/dev/null || fail "valid split report rejected"
jq -e '.status=="split"' "$RD/tasks/T4.json" >/dev/null || fail "split status not recorded"
pass "report-ingest: valid split request accepted and recorded"

# ---------------------------------------------------------------------------
# Test 6 — events.jsonl discipline: every line one valid JSON object, LF only.
# ---------------------------------------------------------------------------
grep -q "$CR" "$RD/events.jsonl" && fail "CR bytes in events.jsonl (jq CRLF leak)"
n_lines=$(wc -l < "$RD/events.jsonl" | tr -d ' ')
n_obj=$(jq -c 'select(type=="object")' "$RD/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')
[ "$n_lines" -ge 6 ] || fail "expected >=6 events, got $n_lines"
[ "$n_lines" = "$n_obj" ] || fail "events.jsonl has non-object/invalid lines ($n_obj/$n_lines valid)"
pass "events.jsonl: $n_lines events, all single-line JSON objects, CRLF-clean"

# generic event verb records; reserved kinds refused
run event --run "$RUN" --kind gate-verdict --data '{"verdict":"blocked"}' >/dev/null || fail "event verb failed"
jq -e 'select(.event=="gate-verdict") | .data.verdict=="blocked"' "$RD/events.jsonl" >/dev/null \
  || fail "gate-verdict event not recorded"
run event --run "$RUN" --kind verify >/dev/null 2>&1 && fail "reserved event kind accepted"
pass "event: gate-verdict recorded; reserved kinds refused"

# ---------------------------------------------------------------------------
# Test 7 — verify: pinned command only, exit code propagated + recorded.
# ---------------------------------------------------------------------------
run verify --run "$RUN" >/dev/null || fail "verify (pinned 'exit 0') should exit 0"
RUNF=$(run init --goal "failing verify" --verify-cmd "exit 7") || fail "init failing-run"
run verify --run "$RUNF" >/dev/null 2>&1
ec=$?
[ "$ec" -eq 7 ] || fail "verify must propagate the pinned command's exit code (want 7, got $ec)"
jq -e 'select(.event=="verify") | .data.exit_code==7' \
  "$SB/projects/teamproj/teams/$RUNF/events.jsonl" >/dev/null || fail "verify exit code not recorded as evidence"
# no pinned command -> refuse loudly (never guess) — the no-config default branch
RUNN=$(run init --goal "no verify cmd") || fail "init no-verify-run"
run verify --run "$RUNN" >/dev/null 2>&1 && fail "verify without a pinned command must fail loud"
pass "verify: exit codes propagated + recorded; unpinned verify refused"

# ---------------------------------------------------------------------------
# Test 8 — fail loud on bad invocations; M2 seams reserved.
# ---------------------------------------------------------------------------
run frobnicate >/dev/null 2>&1 && fail "unknown verb accepted"
run task-set --run "team_nope" --task T1 --status done >/dev/null 2>&1 && fail "nonexistent run accepted"
run init >/dev/null 2>&1 && fail "init without --goal accepted"
run status --run "$RUN" --bogus x >/dev/null 2>&1 && fail "unknown option accepted"
out=$(run commit --run "$RUN" 2>&1) && fail "commit must be an M2 seam"
printf '%s' "$out" | grep -q "M2" || fail "commit refusal must name M2, got: $out"
out=$(run merge --run "$RUN" 2>&1) && fail "merge must be an M2 seam"
pass "fail loud: unknown verb/run/option refused; commit/merge reserved for M2"

# status without --run lists runs
LIST=$(run status) || fail "status list failed"
printf '%s' "$LIST" | jq -e --arg r "$RUN" 'index($r) != null' >/dev/null || fail "run list missing $RUN: $LIST"
pass "status: run listing includes created runs"

# list-open shows open runs with the goal (the skill's Phase-1 resume check)
LO=$(run list-open) || fail "list-open failed"
printf '%s' "$LO" | jq -e --arg r "$RUN" 'map(.run_id) | index($r) != null' >/dev/null \
  || fail "list-open missing open run $RUN: $LO"
printf '%s' "$LO" | jq -e 'all(has("goal") and has("run_id"))' >/dev/null \
  || fail "list-open entries must carry run_id + goal for resume matching: $LO"
pass "list-open: open runs listed with run_id + goal"

# ---------------------------------------------------------------------------
# Test 9 — escalate at most once: the ledger refuses a second escalation.
# ---------------------------------------------------------------------------
RUNO=$(run init --goal "overlap and escalation locks" --verify-cmd "exit 0") || fail "init lock-run failed"
RDO="$SB/projects/teamproj/teams/$RUNO"
run task-add --run "$RUNO" --task E1 --goal "escalate me" >/dev/null || fail "task-add E1 failed"
run task-set --run "$RUNO" --task E1 --status escalated >/dev/null || fail "first escalation refused"
jq -e '.escalated==true and .status=="escalated"' "$RDO/tasks/E1.json" >/dev/null \
  || fail "escalation not recorded"
run task-set --run "$RUNO" --task E1 --status escalated >/dev/null 2>&1 \
  && fail "second escalation accepted (escalate at most once)"
jq -e '.status=="escalated"' "$RDO/tasks/E1.json" >/dev/null || fail "refused escalation mutated the record"
pass "task-set: second escalation refused, record untouched"

# ---------------------------------------------------------------------------
# Test 10 — write-overlap lock: overlap with a non-terminal sibling refused
# (both ids + path named); disjoint accepted; done frees the paths; split
# parent/child chains allowed; a stranger overlapping a split task refused.
# ---------------------------------------------------------------------------
run task-add --run "$RUNO" --task A1 --goal "hold paths" --paths "C:/team-w/a.sh,C:/team-w/b.sh" >/dev/null \
  || fail "task-add A1 failed"
out=$(run task-add --run "$RUNO" --task A2 --goal "collide" --paths "C:/team-w/b.sh,C:/team-w/c.sh" 2>&1) \
  && fail "overlapping task accepted"
printf '%s' "$out" | grep -q "A2" || fail "overlap refusal must name the new task id, got: $out"
printf '%s' "$out" | grep -q "A1" || fail "overlap refusal must name the sibling task id, got: $out"
printf '%s' "$out" | grep -q "C:/team-w/b.sh" || fail "overlap refusal must name the overlapping path, got: $out"
[ -f "$RDO/tasks/A2.json" ] && fail "refused overlap left a task record"
run task-add --run "$RUNO" --task A3 --goal "disjoint" --paths "C:/team-w/c.sh" >/dev/null \
  || fail "disjoint paths refused"
run task-set --run "$RUNO" --task A1 --status done >/dev/null || fail "task-set A1 done failed"
run task-add --run "$RUNO" --task A4 --goal "reuse freed" --paths "C:/team-w/b.sh" >/dev/null \
  || fail "paths of a done (terminal) task still locked"
pass "task-add: overlap refused naming both ids + path; disjoint accepted; done frees paths"

SPLIT_A3='decompose me
```json
{"v":1,"task_id":"A3","status":"split","artifacts":[],"evidence":[],"request_team":{"goal":"sub","tasks":[{"role":"implementer","skills":[],"inputs":"x"}]},"learnings":[]}
```'
printf '%s\n' "$SPLIT_A3" | run report-ingest --run "$RUNO" --task A3 >/dev/null || fail "split report A3 failed"
run task-add --run "$RUNO" --task A3a --goal "child inherits" --parent A3 --paths "C:/team-w/c.sh" >/dev/null \
  || fail "split child inheriting parent paths refused (split parent no longer executes)"
run task-add --run "$RUNO" --task A5 --goal "stranger" --paths "C:/team-w/c.sh" >/dev/null 2>&1 \
  && fail "non-child task overlapping a split task's paths accepted"
SPLIT_A3A='again
```json
{"v":1,"task_id":"A3a","status":"split","artifacts":[],"evidence":[],"request_team":{"goal":"sub2","tasks":[{"role":"implementer","skills":[],"inputs":"y"}]},"learnings":[]}
```'
printf '%s\n' "$SPLIT_A3A" | run report-ingest --run "$RUNO" --task A3a >/dev/null || fail "split report A3a failed"
run task-add --run "$RUNO" --task A3a1 --goal "grandchild inherits" --parent A3a --paths "C:/team-w/c.sh" >/dev/null \
  || fail "grandchild overlapping its split ancestor chain refused"
pass "task-add: split parent/child (and grandchild chain) overlap allowed; strangers refused"

# ---------------------------------------------------------------------------
# Test 11 — max_logical_depth enforced mechanically via the parent_task chain.
# ---------------------------------------------------------------------------
out=$(run task-add --run "$RUNO" --task A3a1x --goal "too deep" --parent A3a1 2>&1) \
  && fail "depth-3 chain accepted (policy max_logical_depth is 2)"
printf '%s' "$out" | grep -q "max_logical_depth" || fail "depth refusal must name max_logical_depth, got: $out"
[ -f "$RDO/tasks/A3a1x.json" ] && fail "refused depth left a task record"
pass "task-add: parent-chain depth beyond policy.json max_logical_depth refused"

echo; echo "ALL PASS"
