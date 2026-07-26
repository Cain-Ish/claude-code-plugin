#!/bin/bash
# plan-first-nudge.sh — PreToolUse: plan-before-implement gate (A) + drift re-grounding (B).
# Watches substantive edits to distinct code files (a change below SB_PLAN_FIRST_MIN_LINES
# lines never counts a file; docs/config/data files never count). Also flips the session
# phase file (plan → implement) the intent-spine goal line reports.
#
#   Gate A (spine on): the FIRST multi-file write (>= SB_PLAN_FIRST_FILES distinct code
#   files, default 2; single-file quick fixes exempt) with no plan on record is denied
#   ONCE with an instruction to state the plan; the retry auto-passes and records
#   plan_ack + the declared scope into the per-session memo (fact-forcing: the deny
#   demands facts, not confirmation).
#   Gate B (spine on, goal frozen): >= SB_DRIFT_FILES (default 4) CONSECUTIVE code files
#   with zero goal-keyword overlap warn once; a SECOND consecutive zero-overlap set gets
#   ONE deny quoting the frozen goal + declared scope; after that, drift is dampened —
#   the scope change is queued in the memo, never silently merged into the goal.
#   Spine off (SB_INTENT_SPINE=off): the original SOFT once-per-session advisory nudge —
#   additionalContext with permissionDecision "allow", never blocks.
#
# Both gates fail OPEN: any internal error (missing memo, unwritable state) allows the
# call. Every gate verdict is audit-logged via sb_log_audit (lib.sh loaded lazily — the
# per-edit hot path stays lib-less). A PreToolUse hook cannot see whether the user
# already planned in the harness UI, so the memo plan_ack is the only plan-on-record
# signal; the deny fires at most once per session either way.
#
# Kill switches: SB_PLAN_FIRST_NUDGE=off (everything), SB_INTENT_SPINE=off (gates+phase
# → legacy advisory). No awk (mawk-safe). Fail-soft; always exits 0.
set -u
[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_PLAN_FIRST_NUDGE:=off}" "${SB_INTENT_SPINE:=off}" # hook-profile shim: these checks run before lib.sh's mapping (or lib-less)
[ "${SB_PLAN_FIRST_NUDGE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true); [ -z "$RAW" ] && exit 0
printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac

FP=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')
[ -z "$FP" ] && exit 0

# Coding-prompt scope: only source-code files count toward multi-file work. Docs/config/data
# edits (.md/.json/.txt/...) are out of scope for a "plan the code first" gate.
shopt -s nocasematch 2>/dev/null || true
case "$FP" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.kts|*.c|*.h|*.cc|*.cpp|*.hpp|*.cs|*.rb|*.php|*.swift|*.sh|*.bash|*.lua|*.scala|*.clj|*.ex|*.exs|*.vue|*.svelte|*.sql) ;;
  *) exit 0 ;;
esac
shopt -u nocasematch 2>/dev/null || true

# Lines this change writes = Write.content OR Edit.new_string OR sum of MultiEdit new_strings
# (same accounting as simplicity-gate.sh). One-line diffs fall below MIN_LINES and never count.
LINES=$(printf '%s' "$RAW" | jq -r '
  ((.tool_input.content // .tool_input.new_string // "")
   + "\n"
   + ([.tool_input.edits[]?.new_string // ""] | join("\n")))' 2>/dev/null | grep -c . )
MIN_LINES="${SB_PLAN_FIRST_MIN_LINES:-3}"; case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=3 ;; esac
[ "${LINES:-0}" -ge "$MIN_LINES" ] 2>/dev/null || exit 0

THRESH="${SB_PLAN_FIRST_FILES:-2}"; case "$THRESH" in ''|*[!0-9]*) THRESH=2 ;; esac

# State dir under BRAIN_DIR (resolve like lib.sh; Windows git-bash arrives in C:\ form -> cygpath).
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR")
STATE="$BRAIN_DIR/.plan-nudge"
mkdir -p "$STATE" 2>/dev/null || exit 0
# Opportunistic GC: drop session markers older than a day so the dir can't grow unbounded.
find "$STATE" -type f -mmin +1440 -delete 2>/dev/null || true

# Sanitise session_id into a safe filename component (never let it carry path separators).
SID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -dc 'A-Za-z0-9_-' | cut -c1-64)
[ -z "$SID" ] && SID="default"

DONE="$STATE/$SID.done"
SEEN="$STATE/$SID.seen"
MEMO="$BRAIN_DIR/.injected/$SID.json"
SPINE_ON=1
[ "${SB_INTENT_SPINE:-on}" = "off" ] && SPINE_ON=0

# Spine off + advisory already fired: exit BEFORE registering — the legacy fast
# path, and it keeps .seen from growing unbounded in advisory mode (only the
# gates need the registry to keep filling after the one-shot fires).
[ "$SPINE_ON" = "0" ] && [ -f "$DONE" ] && exit 0

# Audit + memo helpers, loaded/used lazily: verdicts are rare (<=3 per session) and
# the per-edit hot path must not pay a lib.sh load.
_audit() { # verdict rule target reason
  command -v sb_log_audit >/dev/null 2>&1 || source "$(dirname "$0")/lib.sh" 2>/dev/null || true
  command -v sb_log_audit >/dev/null 2>&1 && sb_log_audit "plan-first-nudge.sh" "$1" "$2" "$3" "$4" "$SID"
  return 0
}
_memo_set() { # key value — merge ONE string field into the session memo; fail-open
  mkdir -p "$BRAIN_DIR/.injected" 2>/dev/null || return 0
  local prev='{}'
  [ -f "$MEMO" ] && prev=$(jq -c '.' "$MEMO" 2>/dev/null)
  [ -z "$prev" ] && prev='{}'
  # Unique temp + mv: two hook processes racing on a shared name would clobber.
  printf '%s' "$prev" | jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' > "$MEMO.tmp.$$" 2>/dev/null \
    && mv "$MEMO.tmp.$$" "$MEMO" 2>/dev/null || rm -f "$MEMO.tmp.$$" 2>/dev/null
  return 0
}

# Register this file once (distinct count = non-empty lines, since we only append unseen paths).
NEWFILE=0
if ! grep -qxF "$FP" "$SEEN" 2>/dev/null; then
  printf '%s\n' "$FP" >> "$SEEN" 2>/dev/null || true
  NEWFILE=1
fi

# Phase flip (plan → implement): the first substantive code edit means implementation
# began. Absent-only write — implement → verify is owned by persona-tool-guard.sh.
if [ "$SPINE_ON" = "1" ] && [ ! -f "$BRAIN_DIR/.injected/$SID.phase" ]; then
  mkdir -p "$BRAIN_DIR/.injected" 2>/dev/null \
    && printf 'implement' > "$BRAIN_DIR/.injected/$SID.phase" 2>/dev/null || true
fi

# Gate A resolution: a prior deny + this substantive retry = the plan was stated.
# Record the ack + declared scope (the distinct-file registry so far), then Gate A
# stays permanently silent this session. The retry itself passes with NO output.
if [ "$SPINE_ON" = "1" ] && [ -f "$STATE/$SID.gate" ] && [ ! -f "$DONE" ]; then
  SCOPE_DECL=$(tr '\n' ' ' < "$SEEN" 2>/dev/null | head -c 400)
  _memo_set "plan_ack" "1"
  _memo_set "scope" "$SCOPE_DECL"
  : > "$DONE" 2>/dev/null || true
  _audit "allow" "gate-a-retry-pass" "$FP" "plan stated after deny; scope recorded: $SCOPE_DECL"
  exit 0
fi

# Gate B resolution: the first call after the drift deny is the scope-change
# confirmation — merge the queued file set into the declared scope (dedup) and
# clear the queue, so the deny's promise is real and the new files count as
# on-scope from here on. Self-limiting: the queue empties after the merge.
if [ "$SPINE_ON" = "1" ] && [ -f "$STATE/$SID.driftdeny" ]; then
  _SQ=$(jq -r '.scope_queued // ""' "$MEMO" 2>/dev/null | tr -d '\r')
  if [ -n "$_SQ" ]; then
    _SQ_PREV='{}'
    [ -f "$MEMO" ] && _SQ_PREV=$(jq -c '.' "$MEMO" 2>/dev/null)
    [ -z "$_SQ_PREV" ] && _SQ_PREV='{}'
    printf '%s' "$_SQ_PREV" | jq -c '
      .scope = (((.scope // "") + " " + (.scope_queued // ""))
                | split(" ") | map(select(. != "")) | unique | join(" "))
      | del(.scope_queued)' > "$MEMO.tmp.$$" 2>/dev/null \
      && mv "$MEMO.tmp.$$" "$MEMO" 2>/dev/null || rm -f "$MEMO.tmp.$$" 2>/dev/null
    _audit "allow" "gate-b-scope-merged" "$FP" "scope change confirmed; queued drift set merged into declared scope"
  fi
fi

# Re-edits of an already-registered file change nothing the gates evaluate.
[ "$NEWFILE" = "1" ] || exit 0

COUNT=$(grep -c . "$SEEN" 2>/dev/null || echo 0)

if [ ! -f "$DONE" ] && [ "${COUNT:-0}" -ge "$THRESH" ] 2>/dev/null; then
  if [ "$SPINE_ON" = "0" ]; then
    # Legacy advisory nudge (spine off): one-time, never blocks, never asks.
    : > "$DONE" 2>/dev/null || true
    CTX="[Plan-first — think before multi-file work] This session has now made substantive edits to ${COUNT} code files. If you haven't already sketched a plan, consider pausing to plan the change (plan mode, or the brainstorming skill) so the pieces fit before more edits — it reduces code→re-code churn. One-time, advisory nudge; nothing was blocked. Silence: SB_PLAN_FIRST_NUDGE=off."
    jq -nc --arg ctx "$CTX" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        additionalContext: $ctx
      }
    }' 2>/dev/null || true
    exit 0
  fi
  PLAN_ACK=$(jq -r '.plan_ack // ""' "$MEMO" 2>/dev/null | tr -d '\r')
  if [ "$PLAN_ACK" = "1" ]; then
    # Plan already on record (e.g. resumed session) — no deny; fall through to Gate B.
    : > "$DONE" 2>/dev/null || true
  else
    # Gate A deny — fires at most once per session (the .gate marker resolves above).
    : > "$STATE/$SID.gate" 2>/dev/null || true
    REASON="[Plan gate] This session is editing its ${COUNT}th distinct code file with no plan on record. Denied once — state the plan: goal, files in scope, verify command — then retry this exact edit (the retry passes automatically and records the plan). Single-file fixes are exempt. Suppress: SB_INTENT_SPINE=off."
    _audit "deny" "gate-a-plan-first" "$FP" "$REASON"
    jq -nc --arg r "$REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }' 2>/dev/null || true
    exit 0
  fi
fi

# Gate B — drift re-grounding. Armed only when a goal was frozen AND a plan is on
# record (plan_ack or a declared scope): before Gate A resolves there is no scope
# to drift FROM, so pre-plan files never enter a drift set. Overlap = the lowercased
# file path contains a goal keyword (>=3 chars), or sits under a declared-scope
# entry/directory (segment-boundary prefixes), or under a directory already warned
# about (observed_dirs — an area flagged once never re-escalates). Consecutive-run
# semantics: an on-scope file resets the counter; observed files neither count nor
# reset; each warn/deny consumes its set so the next starts clean. One deny max.
if [ "$SPINE_ON" = "1" ] && [ ! -f "$STATE/$SID.driftdeny" ]; then
  # One jq answers all four memo fields — line-per-field protocol, single-line
  # values by construction.
  { IFS= read -r GKW; IFS= read -r SCOPE_DECL; IFS= read -r GB_ACK; IFS= read -r OBS_DIRS; } \
    < <(jq -r '(.goal_kw // ""), (.scope // ""), (.plan_ack // ""), (.observed_dirs // "")' "$MEMO" 2>/dev/null | tr -d '\r')
  : "${GKW:=}" "${SCOPE_DECL:=}" "${GB_ACK:=}" "${OBS_DIRS:=}"
  if [ -n "$GKW" ] && { [ "$GB_ACK" = "1" ] || [ -n "$SCOPE_DECL" ]; }; then
    FP_LOWER=$(printf '%s' "$FP" | tr '[:upper:]' '[:lower:]')
    ONSCOPE=0
    for kw in $GKW; do
      [ "${#kw}" -ge 3 ] || continue
      case "$FP_LOWER" in *"$kw"*) ONSCOPE=1; break ;; esac
    done
    if [ "$ONSCOPE" -eq 0 ] && [ -n "$SCOPE_DECL" ]; then
      # Declared scope covers DIRECTORY siblings: for each recorded entry, both
      # the entry and its dirname count as path prefixes — "files in scope"
      # reasonably covers src/auth/* when src/auth/login.ts was declared.
      _SCOPE_LOWER=$(printf '%s' "$SCOPE_DECL" | tr '[:upper:]' '[:lower:]')
      for _entry in $_SCOPE_LOWER; do
        _dir="${_entry%/*}"
        [ "$_dir" = "$_entry" ] && _dir=""   # bare filename — no directory component
        for _prefix in "$_entry" "$_dir"; do
          [ -n "$_prefix" ] || continue
          # Segment-boundary match only: exact, or followed by '/' — so scope
          # src/utils covers src/utils/x.ts but never src/utils-legacy/x.ts.
          case "$FP_LOWER" in
            "$_prefix"|"$_prefix"/*|*"/$_prefix"/*|*"/$_prefix") ONSCOPE=1; break ;;
          esac
        done
        [ "$ONSCOPE" -eq 1 ] && break
      done
    fi
    DRIFT="$STATE/$SID.drift"
    if [ "$ONSCOPE" -eq 1 ]; then
      rm -f "$DRIFT" 2>/dev/null || true
    else
      # Post-warn absorption: a file under an already-warned directory neither
      # increments NOR resets the consecutive counter — an area flagged once
      # never re-escalates; only NOVEL undeclared/unobserved dirs count toward
      # the second set that denies.
      _OBSERVED=0
      if [ -n "$OBS_DIRS" ]; then
        for _od in $OBS_DIRS; do
          case "$FP_LOWER" in "$_od"|"$_od"/*|*"/$_od"/*|*"/$_od") _OBSERVED=1; break ;; esac
        done
      fi
      if [ "$_OBSERVED" -eq 0 ]; then
        printf '%s\n' "$FP" >> "$DRIFT" 2>/dev/null || true
        DCOUNT=$(grep -c . "$DRIFT" 2>/dev/null || echo 0)
        DTHRESH="${SB_DRIFT_FILES:-4}"; case "$DTHRESH" in ''|*[!0-9]*) DTHRESH=4 ;; esac
        if [ "${DCOUNT:-0}" -ge "$DTHRESH" ] 2>/dev/null; then
          GOAL=$(jq -r '.goal // ""' "$MEMO" 2>/dev/null | tr -d '\r')
          DRIFT_SET=$(tr '\n' ' ' < "$DRIFT" 2>/dev/null | head -c 300)
          # Working-set absorption source: the flagged files' dirnames (lowercased,
          # bare filenames skipped) — computed BEFORE the set is consumed.
          _OBS_NEW=""
          for _wf in $(tr '[:upper:]' '[:lower:]' < "$DRIFT" 2>/dev/null | tr '\n' ' '); do
            _wd="${_wf%/*}"
            [ "$_wd" = "$_wf" ] && continue
            _OBS_NEW="$_OBS_NEW $_wd"
          done
          rm -f "$DRIFT" 2>/dev/null || true
          if [ ! -f "$STATE/$SID.driftwarn" ]; then
            : > "$STATE/$SID.driftwarn" 2>/dev/null || true
            # Record the warned dirs so plausible continuations in the same areas
            # absorb instead of escalating to the deny. Atomic merge (unique union).
            if [ -n "$_OBS_NEW" ]; then
              _OB_PREV='{}'
              [ -f "$MEMO" ] && _OB_PREV=$(jq -c '.' "$MEMO" 2>/dev/null)
              [ -z "$_OB_PREV" ] && _OB_PREV='{}'
              printf '%s' "$_OB_PREV" | jq -c --arg d "$_OBS_NEW" '
                .observed_dirs = (((.observed_dirs // "") + " " + $d)
                                  | split(" ") | map(select(. != "")) | unique | join(" "))' > "$MEMO.tmp.$$" 2>/dev/null \
                && mv "$MEMO.tmp.$$" "$MEMO" 2>/dev/null || rm -f "$MEMO.tmp.$$" 2>/dev/null
            fi
            # Advisory only — deliberately NO permissionDecision (an advisory must
            # never widen permissions; same rationale as persona-tool-guard warn).
            CTX="[Re-ground] ${DCOUNT} consecutive code files (${DRIFT_SET}) share no keyword with the session goal: \"${GOAL}\". If the scope legitimately changed, say so; otherwise return to the goal. Advisory — a second zero-overlap set gets one deny."
            _audit "warn" "gate-b-drift-warn" "$FP" "$CTX"
            jq -nc --arg ctx "$CTX" '{
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                additionalContext: $ctx
              }
            }' 2>/dev/null || true
            exit 0
          fi
          : > "$STATE/$SID.driftdeny" 2>/dev/null || true
          # Queue the scope change on record — never silently merged into the frozen goal.
          _memo_set "scope_queued" "$DRIFT_SET"
          SCOPE_Q=""
          [ -n "$SCOPE_DECL" ] && SCOPE_Q=" Declared scope: ${SCOPE_DECL}."
          REASON="[Re-ground gate] A second consecutive set of ${DCOUNT} code files (${DRIFT_SET}) has zero keyword overlap with the frozen session goal: \"${GOAL}\".${SCOPE_Q} Denied once — confirm scope change or return to goal — then retry this exact edit (the retry passes and merges the new file set into the declared scope). Suppress: SB_INTENT_SPINE=off."
          _audit "deny" "gate-b-drift-deny" "$FP" "$REASON"
          jq -nc --arg r "$REASON" '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: $r
            }
          }' 2>/dev/null || true
          exit 0
        fi
      fi
    fi
  fi
fi

exit 0
