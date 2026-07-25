#!/usr/bin/env bash
# team-run.sh — deterministic run ledger CLI for the /second-brain:team conductor (M1, B1).
#
# Layout (spec 2026-07-08, auto-team orchestration):
#   $BRAIN_DIR/projects/<slug>/teams/<run_id>/
#     plan.json      — run goal + metadata (task DAG lives in tasks/)
#     policy.json    — depth/quota/wave caps + the PINNED verify command
#     tasks/<id>.json     — per-task lifecycle record (+ parent_task provenance)
#     tasks/<id>.report.json — validated TEAM-REPORT v1 payload (report-ingest)
#     events.jsonl   — append-only event stream (jq -c one-object-per-line, LF only)
#
# Verbs: init | task-add | task-set | report-ingest | verify | event | status | list-open
#        commit | merge  — RESERVED seams for M2 (A2 git matrix); fail loud now.
#
# Disciplines: slug via sb_resolve_slug (never re-implemented), fail loud via
# sb_log_error + stderr + nonzero exit, jq output CR-stripped (Windows jq emits
# CRLF), bash-3.2/BSD-safe (no mapfile, no ${x,,}, no grep -P).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
SB_SCRIPT_NAME="team-run.sh"

die() { # die <msg> [<exit-code>]
  ec="${2:-1}"
  sb_log_error "team-run.sh" "$1" "$ec"
  echo "team-run.sh: ERROR: $1" >&2
  exit "$ec"
}

sb_require_jq || die "jq is required for the team ledger" 1

VERB="${1:-}"
[ -n "$VERB" ] || die "no verb — usage: team-run.sh <init|task-add|task-set|report-ingest|verify|event|status|list-open> [options]"
shift

# --- option parsing (shared across verbs) ----------------------------------
SLUG="" RUN_ID="" TASK_ID="" GOAL="" TIER="" ROLE="" PARENT="" PATHS="" STATUS=""
BLAME="" NOTE="" KIND="" DATA="" VERIFY_CMD="" MAX_DISPATCHES="" WAVE_CAP="" MAX_DEPTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)           SLUG="${2:-}"; shift 2 ;;
    --run)            RUN_ID="${2:-}"; shift 2 ;;
    --task)           TASK_ID="${2:-}"; shift 2 ;;
    --goal)           GOAL="${2:-}"; shift 2 ;;
    --tier)           TIER="${2:-}"; shift 2 ;;
    --role)           ROLE="${2:-}"; shift 2 ;;
    --parent)         PARENT="${2:-}"; shift 2 ;;
    --paths)          PATHS="${2:-}"; shift 2 ;;
    --status)         STATUS="${2:-}"; shift 2 ;;
    --blame)          BLAME="${2:-}"; shift 2 ;;
    --note)           NOTE="${2:-}"; shift 2 ;;
    --kind)           KIND="${2:-}"; shift 2 ;;
    --data)           DATA="${2:-}"; shift 2 ;;
    --verify-cmd)     VERIFY_CMD="${2:-}"; shift 2 ;;
    --max-dispatches) MAX_DISPATCHES="${2:-}"; shift 2 ;;
    --wave-cap)       WAVE_CAP="${2:-}"; shift 2 ;;
    --max-depth)      MAX_DEPTH="${2:-}"; shift 2 ;;
    *) die "unknown option '$1' for verb '$VERB'" ;;
  esac
done

# --- shared helpers --------------------------------------------------------
resolve_slug() {
  [ -n "$SLUG" ] && return 0
  SLUG=$(sb_resolve_slug)
  [ -n "$SLUG" ] || die "could not resolve project slug (no --slug, no CLAUDE_PROJECT_DIR, no pin)"
}

teams_dir() { printf '%s/projects/%s/teams' "$BRAIN_DIR" "$SLUG"; }

require_run_dir() { # sets RUN_DIR; run must already exist
  [ -n "$RUN_ID" ] || die "verb '$VERB' requires --run <run_id>"
  case "$RUN_ID" in */*|*..*) die "invalid run id '$RUN_ID'" ;; esac
  RUN_DIR="$(teams_dir)/$RUN_ID"
  [ -d "$RUN_DIR" ] || die "run '$RUN_ID' not found under $(teams_dir)"
}

require_task_file() { # sets TASK_FILE; task must already exist
  [ -n "$TASK_ID" ] || die "verb '$VERB' requires --task <id>"
  case "$TASK_ID" in */*|*..*|'') die "invalid task id '$TASK_ID'" ;; esac
  TASK_FILE="$RUN_DIR/tasks/$TASK_ID.json"
  [ -f "$TASK_FILE" ] || die "task '$TASK_ID' not found in run '$RUN_ID'"
}

# Append one event record. jq -c is one-object-per-line by construction; tr -d '\r'
# keeps the Windows jq build's CRLF out of the LF-assuming ledger (the
# validate-plugin drift-check bug class).
append_event() { # append_event <event> [<task_id>] [<data-json>]
  ev_data="${3:-{\}}"
  printf '%s' "$ev_data" | jq -e 'type=="object"' >/dev/null 2>&1 || ev_data='{}'
  jq -nc \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg run "$RUN_ID" --arg ev "$1" --arg task "${2:-}" \
    --argjson data "$ev_data" \
    '{ts:$ts, run_id:$run, event:$ev, task_id:$task, data:$data}' \
    | tr -d '\r' >> "$RUN_DIR/events.jsonl" \
    || die "failed to append '$1' event to $RUN_DIR/events.jsonl"
}

# Atomic-ish JSON write: temp file in the same dir, then mv. Runs as the tail
# of a pipeline (a SUBSHELL), so it must RETURN nonzero — an exit here would
# only kill the subshell. Every call site carries `|| die` to fail loud in the
# parent.
write_json() { # write_json <path>  (JSON on stdin)
  wj_tmp="$1.tmp.$$"
  cat > "$wj_tmp" || { rm -f "$wj_tmp"; return 1; }
  jq empty "$wj_tmp" 2>/dev/null || { rm -f "$wj_tmp"; return 1; }
  mv "$wj_tmp" "$1" || { rm -f "$wj_tmp"; return 1; }
}

VALID_STATUSES="pending dispatched done blocked failed split escalated"
check_status() {
  case " $VALID_STATUSES " in
    *" $1 "*) : ;;
    *) die "invalid status '$1' (valid: $VALID_STATUSES)" ;;
  esac
}
check_blame() {
  [ -z "$1" ] && return 0
  case "$1" in
    caller-under-supplied|child-under-delivered) : ;;
    *) die "invalid blame class '$1' (valid: caller-under-supplied | child-under-delivered)" ;;
  esac
}

# --- verbs -----------------------------------------------------------------
case "$VERB" in

init)
  [ -n "$GOAL" ] || die "init requires --goal <text>"
  resolve_slug
  TD="$(teams_dir)"
  mkdir -p "$TD" || die "cannot create $TD"
  RUN_ID="team_$(date -u +%Y%m%dT%H%M%SZ)"
  n=2
  while [ -d "$TD/$RUN_ID" ]; do RUN_ID="team_$(date -u +%Y%m%dT%H%M%SZ)_$n"; n=$((n + 1)); done
  RUN_DIR="$TD/$RUN_ID"
  mkdir -p "$RUN_DIR/tasks" || die "cannot create $RUN_DIR/tasks"

  # Defaults per spec: max_logical_depth 2, max_dispatches 30, wave_cap 5.
  # Env overrides are the spec's flags; explicit options win over both.
  jq -nc \
    --arg run "$RUN_ID" --arg slug "$SLUG" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg vcmd "${VERIFY_CMD:-}" \
    --argjson md "${MAX_DISPATCHES:-${SB_TEAM_MAX_DISPATCHES:-30}}" \
    --argjson wc "${WAVE_CAP:-${SB_TEAM_WAVE_CAP:-5}}" \
    --argjson dep "${MAX_DEPTH:-${SB_TEAM_MAX_DEPTH:-2}}" \
    '{run_id:$run, slug:$slug, created:$ts, max_logical_depth:$dep,
      max_dispatches:$md, wave_cap:$wc, verify_cmd:$vcmd}' \
    | tr -d '\r' | write_json "$RUN_DIR/policy.json" || die "failed writing policy.json"

  jq -nc \
    --arg run "$RUN_ID" --arg slug "$SLUG" --arg goal "$GOAL" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{run_id:$run, slug:$slug, goal:$goal, created:$ts, state:"open"}' \
    | tr -d '\r' | write_json "$RUN_DIR/plan.json" || die "failed writing plan.json"

  append_event "init" "" "$(jq -nc --arg g "$GOAL" '{goal:$g}')"
  sb_log_audit "team-run" "allow" "init" "$RUN_DIR" "team run created" "" '{}'
  printf '%s\n' "$RUN_ID"
  ;;

task-add)
  resolve_slug; require_run_dir
  [ -n "$TASK_ID" ] || die "task-add requires --task <id>"
  case "$TASK_ID" in */*|*..*) die "invalid task id '$TASK_ID'" ;; esac
  [ -n "$GOAL" ] || die "task-add requires --goal <text>"
  TIER="${TIER:-DO}"
  case "$TIER" in THINK|DO|SCOUT) : ;; *) die "invalid tier '$TIER' (valid: THINK | DO | SCOUT)" ;; esac
  TASK_FILE="$RUN_DIR/tasks/$TASK_ID.json"
  [ -f "$TASK_FILE" ] && die "task '$TASK_ID' already exists in run '$RUN_ID'"
  if [ -n "$PARENT" ]; then
    [ -f "$RUN_DIR/tasks/$PARENT.json" ] || die "parent task '$PARENT' not found (register parents before children)"
  fi
  # Walk the parent_task chain once: it feeds both the logical-depth cap and the
  # split-overlap exception below. Parents must pre-exist (checked above), so the
  # chain is acyclic by construction.
  ANCESTORS=""
  DEPTH=0
  anc="$PARENT"
  while [ -n "$anc" ]; do
    ANCESTORS="$ANCESTORS $anc"
    DEPTH=$((DEPTH + 1))
    anc=$(jq -r '.parent_task // ""' "$RUN_DIR/tasks/$anc.json" | tr -d '\r') \
      || die "task-add: cannot read ancestor record for '$TASK_ID'"
  done
  MAXD=$(jq -r '.max_logical_depth // 2' "$RUN_DIR/policy.json" | tr -d '\r') \
    || die "task-add: cannot read max_logical_depth from policy.json"
  [ "$DEPTH" -le "$MAXD" ] \
    || die "task-add: refusing '$TASK_ID' — logical depth $DEPTH (parent chain:$ANCESTORS) exceeds policy.json max_logical_depth $MAXD"
  # Write-overlap lock: refuse declared paths that intersect any NON-TERMINAL
  # sibling's declared paths (terminal = done | failed — every other status in
  # the enum may still be executing or be re-dispatched). One exception, which
  # the split flow REQUIRES: when a worker returns status:"split", report-ingest
  # marks the parent "split" and the conductor registers children that inherit
  # the parent's paths — a "split" ancestor is no longer executing, so overlap
  # with it (and only it) is legitimate for its own descendants.
  if [ -n "$PATHS" ]; then
    for sib_file in "$RUN_DIR/tasks/"*.json; do
      [ -f "$sib_file" ] || continue
      case "$sib_file" in *.report.json) continue ;; esac
      SIB=$(basename "$sib_file" .json)
      OV=$(jq -r --arg p "$PATHS" '
        if (.status | IN("done","failed")) then empty
        else . as $t
          | [($p | split(","))[] | select(. as $np | $t.paths | index($np))]
          | .[0] // empty
        end' "$sib_file" | tr -d '\r') \
        || die "task-add: cannot read sibling task record $sib_file"
      [ -n "$OV" ] || continue
      case " $ANCESTORS " in
        *" $SIB "*)
          SIB_ST=$(jq -r '.status' "$sib_file" | tr -d '\r')
          [ "$SIB_ST" = "split" ] && continue
          ;;
      esac
      die "task-add: refusing task '$TASK_ID' — path '$OV' overlaps non-terminal task '$SIB' (write scopes must not overlap; wait for '$SIB' to reach done/failed or plan disjoint paths)"
    done
  fi
  jq -nc \
    --arg id "$TASK_ID" --arg goal "$GOAL" --arg tier "$TIER" \
    --arg role "${ROLE:-worker}" --arg parent "$PARENT" --arg paths "$PATHS" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{id:$id, goal:$goal, tier:$tier, role:$role,
      parent_task:(if $parent=="" then null else $parent end),
      paths:(if $paths=="" then [] else ($paths|split(",")) end),
      status:"pending", escalated:false, blame:null, created:$ts}' \
    | tr -d '\r' | write_json "$TASK_FILE" || die "failed writing task record"
  append_event "task-add" "$TASK_ID" "$(jq -nc --arg t "$TIER" --arg p "$PARENT" '{tier:$t, parent:$p}')"
  echo "task-add: $TASK_ID ($TIER) registered in $RUN_ID"
  ;;

task-set)
  resolve_slug; require_run_dir; require_task_file
  [ -n "$STATUS" ] || die "task-set requires --status <s>"
  check_status "$STATUS"; check_blame "$BLAME"
  esc="false"
  if [ "$STATUS" = "escalated" ]; then
    # Escalate at most once (PROTOCOL): a second escalation of the same task is
    # refused mechanically — stop the lane with --status failed + a blame class.
    jq -e '.escalated == true' "$TASK_FILE" >/dev/null \
      && die "task-set: task '$TASK_ID' was already escalated once — escalate at most once; stop the lane (task-set --status failed with a blame class) instead"
    esc="true"
  fi
  jq -c \
    --arg s "$STATUS" --arg b "$BLAME" --arg note "$NOTE" --argjson esc "$esc" \
    '.status=$s
     | (if $esc then .escalated=true else . end)
     | (if $b    != "" then .blame=$b   else . end)
     | (if $note != "" then .note=$note else . end)' \
    "$TASK_FILE" | tr -d '\r' | write_json "$TASK_FILE" || die "failed writing task record"
  append_event "task-set" "$TASK_ID" "$(jq -nc --arg s "$STATUS" --arg b "$BLAME" '{status:$s, blame:$b}')"
  echo "task-set: $TASK_ID -> $STATUS${BLAME:+ (BLAME: $BLAME)}"
  ;;

report-ingest)
  # Reads a worker's full response text on stdin. Validates the TEAM-REPORT v1
  # tail DETERMINISTICALLY (jq schema, not LLM prose compliance), stores the
  # parsed payload, and updates the task record. A malformed tail is a hard
  # nonzero exit — and the RUN LEDGER carries the strike trail: each rejection
  # appends a report-rejected event and increments the task's .strikes, and the
  # SECOND strike mechanically fails the task with BLAME child-under-delivered
  # (two strikes). The conductor's retry-once packet lives in the skill.
  resolve_slug; require_run_dir; require_task_file
  reject_report() { # reject_report <reason> — record the strike in the ledger, then die
    RJ_STRIKES=$(jq -r '(.strikes // 0) + 1' "$TASK_FILE" | tr -d '\r') \
      || die "report-ingest: cannot read strike count for task '$TASK_ID'"
    RJ_FAILED=false
    [ "$RJ_STRIKES" -ge 2 ] && RJ_FAILED=true
    jq -c --argjson n "$RJ_STRIKES" --argjson f "$RJ_FAILED" \
      '.strikes=$n
       | (if $f then .status="failed" | .blame="child-under-delivered" else . end)' \
      "$TASK_FILE" | tr -d '\r' | write_json "$TASK_FILE" \
      || die "report-ingest: failed recording strike on task '$TASK_ID'"
    append_event "report-rejected" "$TASK_ID" \
      "$(jq -nc --arg r "$1" --argjson n "$RJ_STRIKES" --argjson f "$RJ_FAILED" \
           '{reason:$r, strikes:$n, task_failed:$f}')"
    if [ "$RJ_FAILED" = "true" ]; then
      die "report-ingest: $1 — strike $RJ_STRIKES for task '$TASK_ID': two strikes, task marked failed (BLAME: child-under-delivered)" 3
    fi
    die "report-ingest: $1 — strike $RJ_STRIKES of 2 for task '$TASK_ID' (a second malformed report fails the task)" 3
  }
  RAW=$(tr -d '\r')   # CRLF discipline before any parsing
  # Extract the LAST ```json fenced block (workers may quote other fences above it).
  TAIL=$(printf '%s\n' "$RAW" | awk '
    /^```json[[:space:]]*$/ { buf=""; cap=1; next }
    /^```[[:space:]]*$/     { if (cap) last=buf; cap=0; next }
    cap                     { buf = buf $0 "\n" }
    END                     { printf "%s", last }')
  [ -n "$TAIL" ] || reject_report "no \`\`\`json fenced TEAM-REPORT tail found in stdin"
  printf '%s' "$TAIL" | jq -e \
    --arg task "$TASK_ID" '
      (type=="object")
      and (.v == 1)
      and ((.task_id|type=="string") and .task_id == $task)
      and (.status|IN("done","blocked","failed","split"))
      and ((.artifacts // []) | type=="array")
      and ((.evidence  // []) | type=="array")
      and (if .status=="split"
           then ((.request_team|type=="object")
                 and ((.request_team.tasks // []) | type=="array"))
           else (has("request_team") | not) end)
      and ((.learnings // []) | type=="array")
    ' >/dev/null 2>&1 \
    || reject_report "TEAM-REPORT tail failed schema validation (need v:1, matching task_id, status done|blocked|failed|split, request_team only with split)"
  R_STATUS=$(printf '%s' "$TAIL" | jq -r '.status' | tr -d '\r')
  # BLAME line rides OUTSIDE the JSON tail (shipped vocabulary) — capture it too.
  R_BLAME=$(printf '%s\n' "$RAW" \
    | grep -oE 'BLAME:[[:space:]]*(caller-under-supplied|child-under-delivered)' \
    | tail -1 | sed -E 's/BLAME:[[:space:]]*//')
  printf '%s' "$TAIL" | jq -c . | tr -d '\r' | write_json "$RUN_DIR/tasks/$TASK_ID.report.json" || die "failed writing report payload"
  jq -c --arg s "$R_STATUS" --arg b "$R_BLAME" \
    '.status=$s | (if $b != "" then .blame=$b else . end)' \
    "$TASK_FILE" | tr -d '\r' | write_json "$TASK_FILE" || die "failed writing task record"
  append_event "report-ingest" "$TASK_ID" \
    "$(printf '%s' "$TAIL" | jq -c --arg b "$R_BLAME" '{status:.status, artifacts:(.artifacts//[]|length), split:(.status=="split"), blame:$b}')"
  echo "report-ingest: $TASK_ID -> $R_STATUS${R_BLAME:+ (BLAME: $R_BLAME)}"
  ;;

verify)
  # Runs ONLY the command pinned into policy.json at init — never anything
  # sourced from a worker report (spec B1: poisoned reports must not choose
  # the verify command). Exit code is recorded as ledger evidence and
  # propagated so the caller gates on it, not on log tails.
  resolve_slug; require_run_dir
  VCMD=$(jq -r '.verify_cmd // ""' "$RUN_DIR/policy.json" 2>/dev/null | tr -d '\r')
  [ -n "$VCMD" ] || die "verify: no verify_cmd pinned in policy.json — pin it at init (--verify-cmd); refusing to guess" 2
  set +e
  bash -c "$VCMD"
  VEC=$?
  set -e 2>/dev/null || true
  append_event "verify" "" "$(jq -nc --arg c "$VCMD" --argjson ec "$VEC" '{cmd:$c, exit_code:$ec}')"
  echo "VERIFY-EXIT: $VEC"
  exit "$VEC"
  ;;

event)
  resolve_slug; require_run_dir
  [ -n "$KIND" ] || die "event requires --kind <k>"
  case "$KIND" in
    init|task-add|task-set|report-ingest|report-rejected|verify) die "event kind '$KIND' is reserved for its verb" ;;
  esac
  if [ -n "$TASK_ID" ]; then require_task_file; fi
  append_event "$KIND" "$TASK_ID" "${DATA:-{\}}"
  echo "event: $KIND recorded in $RUN_ID"
  ;;

status)
  resolve_slug
  TD="$(teams_dir)"
  if [ -z "$RUN_ID" ]; then
    # List runs (newest last by name — run ids are UTC-timestamp-ordered).
    [ -d "$TD" ] || { echo '[]'; exit 0; }
    ls "$TD" 2>/dev/null | tr -d '\r' | jq -R -s -c 'split("\n") | map(select(length>0))'
    exit 0
  fi
  require_run_dir
  # Fold tasks/*.json into one summary. -n + inputs so zero tasks still yields
  # a valid summary (the empty-ledger default branch is covered by test).
  find "$RUN_DIR/tasks" -maxdepth 1 -name '*.json' ! -name '*.report.json' -type f 2>/dev/null \
    | sort | tr -d '\r' \
    | while IFS= read -r tf; do cat "$tf"; done \
    | jq -s -c \
        --slurpfile plan "$RUN_DIR/plan.json" \
        --slurpfile policy "$RUN_DIR/policy.json" '
      { run_id: $plan[0].run_id,
        goal: $plan[0].goal,
        state: $plan[0].state,
        policy: $policy[0],
        tasks: map({id, tier, role, status, parent_task, escalated, blame}),
        counts: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries) }' \
    | tr -d '\r'
  ;;

list-open)
  # Open runs for the project (state:"open" in plan.json), oldest first — the
  # skill's Phase-1 resume check: continue a matching open run, never re-mint.
  resolve_slug
  TD="$(teams_dir)"
  [ -d "$TD" ] || { echo '[]'; exit 0; }
  find "$TD" -mindepth 2 -maxdepth 2 -name plan.json -type f 2>/dev/null \
    | sort | tr -d '\r' \
    | while IFS= read -r pf; do cat "$pf"; done \
    | jq -s -c 'map(select(.state=="open") | {run_id, goal, created})' \
    | tr -d '\r'
  ;;

commit|merge)
  # M2 seam (spec A2 git matrix): serialized pathspec-scoped commits and the
  # branch merge-back land with the autonomy milestone. Fail loud, never guess.
  die "verb '$VERB' is reserved for M2 (A2 git matrix) — not available in M1" 2
  ;;

*)
  die "unknown verb '$VERB' (valid: init | task-add | task-set | report-ingest | verify | event | status | list-open)"
  ;;
esac
