#!/usr/bin/env bash
# Contract test for TEAM-REPORT v1 — the one return format every team-dispatched worker
# promises (agents/team-worker.md) and the conductor parses (skills/team/SKILL.md via
# team-run.sh report-ingest). Pattern copied from test-maintain-drain-loop.sh: the prose
# contract is pinned by a REFERENCE parser here; fixtures drive both the reference parser
# and the REAL ingest path, and the two must agree (valid / malformed / CRLF-poisoned /
# split), so the grammar cannot drift between the worker's promise and the machine parser.
# POSIX/bash-3.2/BSD-safe.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TR="$ROOT/scripts/team-run.sh"
WORKER="$ROOT/agents/team-worker.md"
SKILL="$ROOT/skills/team/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Reference implementation of the documented grammar (kept identical to prose):
#   * the report tail is the LAST ```json fenced block in the response;
#   * CR bytes are stripped before parsing (CRLF discipline);
#   * the object must satisfy: v==1, task_id string == expected, status in
#     done|blocked|failed|split, artifacts/evidence/learnings arrays (may be
#     empty), request_team an object ONLY when status=="split";
#   * an optional `BLAME: caller-under-supplied|child-under-delivered` line
#     rides OUTSIDE the tail.
# ---------------------------------------------------------------------------
sb_parse_team_report() { # sb_parse_team_report <text> <expected-task-id> -> echoes status, rc 1 if invalid
  tail_json=$(printf '%s\n' "$1" | tr -d '\r' | awk '
    /^```json[[:space:]]*$/ { buf=""; cap=1; next }
    /^```[[:space:]]*$/     { if (cap) last=buf; cap=0; next }
    cap                     { buf = buf $0 "\n" }
    END                     { printf "%s", last }')
  [ -n "$tail_json" ] || return 1
  printf '%s' "$tail_json" | jq -e --arg task "$2" '
    (type=="object") and (.v==1)
    and ((.task_id|type=="string") and .task_id==$task)
    and (.status|IN("done","blocked","failed","split"))
    and ((.artifacts // [])|type=="array") and ((.evidence // [])|type=="array")
    and (if .status=="split"
         then ((.request_team|type=="object") and ((.request_team.tasks // [])|type=="array"))
         else (has("request_team")|not) end)
    and ((.learnings // [])|type=="array")' >/dev/null 2>&1 || return 1
  printf '%s' "$tail_json" | jq -r '.status'
}
sb_parse_blame() {
  printf '%s\n' "$1" | tr -d '\r' \
    | grep -oE 'BLAME:[[:space:]]*(caller-under-supplied|child-under-delivered)' \
    | tail -1 | sed -E 's/BLAME:[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# Fixtures (name|expected: status word or INVALID).
# ---------------------------------------------------------------------------
F_DONE='Edited both files per contract.
```json
{"v":1,"task_id":"TX","status":"done","artifacts":["a/x.sh"],"evidence":["edit applied"],"learnings":[{"kind":"gotcha","text":"y"}]}
```'
F_SPLIT='Too big for one lane.
```json
{"v":1,"task_id":"TX","status":"split","artifacts":[],"evidence":[],"request_team":{"goal":"sub","tasks":[{"role":"implementer","skills":[],"inputs":"i"}]},"learnings":[]}
```'
F_REFUSAL='packet field 3 (absolute paths) absent
```json
{"v":1,"task_id":"TX","status":"blocked","artifacts":[],"evidence":["packet defective"],"learnings":[]}
```
BLAME: caller-under-supplied'
# earlier ```json block must be ignored; the LAST fence wins
F_TWOFENCE='Here is context I quoted:
```json
{"unrelated":"block"}
```
done now.
```json
{"v":1,"task_id":"TX","status":"done","artifacts":[],"evidence":[],"learnings":[]}
```'
F_NOFENCE='worker crashed, no tail at all'
F_BADV='```json
{"v":2,"task_id":"TX","status":"done"}
```'
F_BADSTATUS='```json
{"v":1,"task_id":"TX","status":"finished"}
```'
F_WRONGTASK='```json
{"v":1,"task_id":"TY","status":"done"}
```'
F_SNEAKSPLIT='```json
{"v":1,"task_id":"TX","status":"done","request_team":{"goal":"g","tasks":[]}}
```'
F_NOTJSON='```json
{this is not json}
```'

expect() { # expect <fixture> <status|INVALID> <label>
  got=$(sb_parse_team_report "$1" "TX") || got=INVALID
  [ "$got" = "$2" ] || fail "$3: reference parser said '$got', want '$2'"
}
expect "$F_DONE" done "valid done"
expect "$F_SPLIT" split "valid split"
expect "$F_REFUSAL" blocked "refusal"
expect "$F_TWOFENCE" done "last-fence-wins"
expect "$F_NOFENCE" INVALID "no fence"
expect "$F_BADV" INVALID "wrong v"
expect "$F_BADSTATUS" INVALID "status outside enum"
expect "$F_WRONGTASK" INVALID "task_id mismatch"
expect "$F_SNEAKSPLIT" INVALID "request_team without split"
expect "$F_NOTJSON" INVALID "non-JSON tail"
# CRLF-poisoned valid report still parses (Windows worker output)
CRLF_DONE=$(printf '%s\n' "$F_DONE" | awk '{printf "%s\r\n", $0}')
expect "$CRLF_DONE" done "CRLF-poisoned done"
[ "$(sb_parse_blame "$F_REFUSAL")" = "caller-under-supplied" ] || fail "blame not parsed from refusal"
[ -z "$(sb_parse_blame "$F_DONE")" ] || fail "phantom blame on a clean report"
pass "reference parser: 11 fixture shapes map to the documented accept/reject decisions"

# ---------------------------------------------------------------------------
# Parity: the REAL ingest path (team-run.sh report-ingest) must agree with the
# reference parser on every fixture — the grammar lives in two places and this
# is the lock that keeps them one grammar.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SB="$TMP/.sb"; mkdir -p "$SB/projects/teamproj"; touch "$SB/projects/teamproj/PROJECT.md"
run(){ BRAIN_DIR="$SB" CLAUDE_PROJECT_DIR="/home/u/Projects/teamproj" bash "$TR" "$@"; }
RUN=$(run init --goal "contract parity") || fail "init failed"
i=0
for fx in "$F_DONE" "$F_SPLIT" "$F_REFUSAL" "$F_TWOFENCE" "$CRLF_DONE" \
          "$F_NOFENCE" "$F_BADV" "$F_BADSTATUS" "$F_WRONGTASK" "$F_SNEAKSPLIT" "$F_NOTJSON"; do
  i=$((i + 1))
  # each fixture claims task_id TX -> register a fresh TX-equivalent per round
  tid="TX"
  RD="$SB/projects/teamproj/teams/$RUN"
  rm -f "$RD/tasks/$tid.json" "$RD/tasks/$tid.report.json"
  run task-add --run "$RUN" --task "$tid" --goal "fixture $i" >/dev/null || fail "task-add fixture $i"
  ref=$(sb_parse_team_report "$fx" "$tid") || ref=INVALID
  if printf '%s\n' "$fx" | run report-ingest --run "$RUN" --task "$tid" >/dev/null 2>&1; then
    real=$(jq -r '.status' "$RD/tasks/$tid.json")
  else
    real=INVALID
  fi
  [ "$ref" = "$real" ] || fail "parity break on fixture $i: reference='$ref' ingest='$real'"
done
pass "parity: report-ingest agrees with the reference parser on all 11 fixtures"

# ---------------------------------------------------------------------------
# The prose carries the exact markers the parser pins — worker promise + skill
# packet field must both name the grammar.
# ---------------------------------------------------------------------------
for f in "$WORKER" "$SKILL"; do
  grep -q 'TEAM-REPORT v1' "$f" || fail "$f lost the literal 'TEAM-REPORT v1'"
  grep -q '"v":1' "$f" || fail "$f lost the literal \"v\":1 tail marker"
  grep -q '```json' "$f" || fail "$f lost the \`\`\`json fence marker"
done
grep -q 'done|blocked|failed|split' "$WORKER" || fail "worker lost the status enum literal"
grep -qE 'BLAME: caller-under-supplied \| child-under-delivered' "$WORKER" \
  || fail "worker lost the BLAME vocabulary line"
pass "prose parity: TEAM-REPORT v1 markers pinned in worker + skill"

echo; echo "ALL PASS"
