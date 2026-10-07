#!/bin/bash
# Compaction hooks: PreCompact extraction (default) + PostCompact Pending-Tasks capture (post).
#
# Default (no arg, or any arg other than "post") = PreCompact: runs LLM extraction on the
# unprocessed transcript window BEFORE compaction discards context. Ensures decisions,
# patterns, and knowledge from early in long sessions survive compaction cycles.
#
# Works in tandem with stop-extract.sh: both use a shared line-marker file
# (.last-extracted-line-<slug>--<session_id>) so each processes a disjoint window, and a shared
# archive cursor (.last-archived-line-<slug>--<session_id>, sb_archive_raw_window) so each
# appends a disjoint window to the archive, archive-first.
#
# Honors env overrides:
#   SB_EXTRACT_TIMEOUT — seconds to wait for `claude` (default: 30)
#   SB_EXTRACT=off      — kill switch: skip the LLM extraction call entirely (no
#                        API spend). The transcript window is still archived and
#                        the marker still advances — a deterministic files-touched
#                        delta merges instead, same as an LLM failure would produce.
#
# `post` = PostCompact: Claude Code's own compaction summary ("Pending Tasks" section only,
# F2) sanitized in memory and injection-scanned, then added add-only to ## Plan. Nothing raw
# is ever persisted (C2/C3, Slice 1 §4.3). Honors:
#   SB_COMPACT_CAPTURE=off — kill switch: no-op, no adds.
#
# Always exits 0 (fail-soft).
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
# Foreign headless child (`claude -p` / SDK-cli, nobody attending; R1 review): its window is neither
# archived nor extracted, and its Pending Tasks are not captured (both modes). One gate=headless-child
# audit row. Inline copy of lib.sh sb_is_headless_child (locked by tests/test-persona-context.sh).
[ "${SB_NESTED_SPAWN:-0}" != "1" ] && [ "${SB_HEADLESS_CONTEXT:-off}" != "on" ] && { [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "0" ] || [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "sdk-cli" ]; } && { source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh" && sb_headless_trace pre-compact; exit 0; }  # sb-headless-inline

LIB="$(dirname "$0")/lib.sh"
if ! source "$LIB" 2>/dev/null; then
  printf '{"timestamp":"%s","script":"pre-compact.sh","message":"lib.sh source failed: %s","exit_code":0}\n' \
    "$(date -u +%FT%TZ)" "$LIB" >> "$HOME/.second-brain/error-log.jsonl" 2>/dev/null
  exit 0
fi

SB_GATE=""
EXTRACT_INPUT="" EXTRACT_OUT="" MERGE_ERR="" PERSONA_ERR=""
cleanup() {
  rm -f "$EXTRACT_INPUT" "$EXTRACT_OUT" "$MERGE_ERR" "$PERSONA_ERR" 2>/dev/null
  [ -n "$SB_GATE" ] && sb_log_error "pre-compact.sh" "gate=$SB_GATE" 0
}
trap cleanup EXIT

# --- PostCompact mode (C2/C3, Slice 1 §4.3): Pending Tasks -> ## Plan, add-only ---------------
if [ "${1:-}" = "post" ]; then
  [ "${SB_COMPACT_CAPTURE:-on}" = "off" ] && { SB_GATE="postcompact-capture reason=off"; exit 0; }

  P_RAW=$(cat 2>/dev/null || true)
  if [ -z "$P_RAW" ] || ! echo "$P_RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
    SB_GATE="postcompact-capture reason=bad-stdin"; exit 0
  fi

  { IFS= read -r P_SID; IFS= read -r P_CWD; IFS= read -r P_TPATH; IFS= read -r P_TRIGGER; } < <(
    printf '%s' "$P_RAW" | jq -r '.session_id // "", .cwd // "", .transcript_path // "", .trigger // ""' 2>/dev/null | tr -d '\r'
  )
  P_SID8="${P_SID:0:8}"

  # Provenance FIRST (F11): survives even if everything below gates out.
  sb_session_prov_write "$P_SID" "${CLAUDE_PROJECT_DIR:-$P_CWD}"

  # SF-L5: record WHICH resolver actually produced the slug for the diagnostic row.
  P_SLUG_SRC="cwd"
  if [ -n "$P_CWD" ] && [ -d "$P_CWD" ]; then
    P_SLUG=$(sb_resolve_slug "$P_CWD")
  else
    P_SLUG=$(sb_resolve_slug "$PWD")
    P_SLUG_SRC="pwd"
  fi
  if [ -z "$P_SLUG" ]; then SB_GATE="postcompact-capture sid=$P_SID8 slugsrc=$P_SLUG_SRC reason=slug-empty"; exit 0; fi
  P_PROJECT_MD="$BRAIN_DIR/projects/$P_SLUG/PROJECT.md"
  if [ ! -f "$P_PROJECT_MD" ]; then SB_GATE="postcompact-capture sid=$P_SID8 slug=$P_SLUG slugsrc=$P_SLUG_SRC reason=project-md-missing"; exit 0; fi

  # Summary source: payload .compact_summary, else the transcript's isCompactSummary record
  # (F4 -- written just after compact_boundary, BEFORE PostCompact fires), else no-summary.
  # SF-M1: no-summary is logged with WHY (nopayload|no-transcript|no-record|parse-failed) --
  # a bare reason=no-summary can't distinguish "nothing was ever sent" from a format-drift
  # regression in the isCompactSummary probe below, which would otherwise silently disable
  # this whole capture path forever with no signal pointing at the cause.
  P_SUMMARY="" P_SRC="" P_NOSUM_SRC="nopayload"
  P_CS=$(printf '%s' "$P_RAW" | jq -r '.compact_summary // empty' 2>/dev/null)
  if [ -n "$P_CS" ] && [ "$P_CS" != "null" ]; then
    P_SUMMARY="$P_CS"; P_SRC="payload"
  elif [ -z "$P_TPATH" ]; then
    P_NOSUM_SRC="nopayload"
  elif [ ! -f "$P_TPATH" ]; then
    P_NOSUM_SRC="no-transcript"
  else
    # SEC nit: `--` before a payload-supplied path so a value shaped like an option
    # (e.g. "-e") can never be reinterpreted as a grep/sed flag.
    P_LINE=$(grep -n -- '"isCompactSummary":[[:space:]]*true' "$P_TPATH" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -z "$P_LINE" ]; then
      P_NOSUM_SRC="no-record"
    else
      P_RECORD=$(sed -n -- "${P_LINE}p" "$P_TPATH" 2>/dev/null | tr -d '\r')
      P_SUMMARY=$(printf '%s' "$P_RECORD" | jq -r '
        .message.content
        | if type=="string" then . elif type=="array" then (map(.text? // "") | join("\n")) else "" end
      ' 2>/dev/null)
      if [ -z "$P_SUMMARY" ]; then
        P_NOSUM_SRC="parse-failed"
      else
        # SF-L4: reject a record that is not actually THIS compaction's summary -- a long
        # session's transcript can carry MULTIPLE prior isCompactSummary records; `tail -1`
        # takes the last one, but a mis-pointed/stale transcript_path could still resolve to
        # an old one. Its own `timestamp` field must be within ~120s of now, or the retired
        # tasks it lists could resurrect work already finished since. Fails OPEN on a parse
        # failure (unknown timestamp format) -- this is a freshness nicety, not the primary
        # trust boundary (that is gate_untrusted_items in merge-project-update.sh).
        P_REC_TS=$(printf '%s' "$P_RECORD" | jq -r '.timestamp // empty' 2>/dev/null)
        if [ -n "$P_REC_TS" ]; then
          P_REC_TS_BSD="${P_REC_TS%Z}"; P_REC_TS_BSD="${P_REC_TS_BSD%%.*}"
          # -u is REQUIRED on the BSD branch too: $P_REC_TS is already UTC (ISO "Z"
          # timestamp with the trailing Z stripped above), but `date -j -f` without -u
          # parses its input as LOCAL time -- in any non-UTC zone (e.g. TZ=Asia/Tokyo)
          # that skews the parsed epoch by the zone offset, so a fresh summary reads as
          # hours old and gets rejected as stale-summary.
          P_REC_EPOCH=$(date -u -d "$P_REC_TS" +%s 2>/dev/null \
            || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$P_REC_TS_BSD" +%s 2>/dev/null \
            || echo "")
          case "$P_REC_EPOCH" in ''|*[!0-9]*) P_REC_EPOCH="" ;; esac
          if [ -n "$P_REC_EPOCH" ]; then
            P_NOW_EPOCH=$(date -u +%s)
            P_AGE=$((P_NOW_EPOCH - P_REC_EPOCH))
            [ "$P_AGE" -lt 0 ] && P_AGE=$((-P_AGE))
            if [ "$P_AGE" -gt 120 ]; then
              P_SUMMARY=""
              P_NOSUM_SRC="stale-summary"
            fi
          fi
        fi
        [ -n "$P_SUMMARY" ] && P_SRC="transcript"
      fi
    fi
  fi
  P_SUMMARY=$(printf '%s' "$P_SUMMARY" | tr -d '\r')
  if [ -z "$P_SUMMARY" ]; then
    sb_log_error "pre-compact.sh" "gate=postcompact-capture reason=no-summary src=$P_NOSUM_SRC slug=$P_SLUG sid=$P_SID8" 1
    SB_GATE="postcompact-capture slug=$P_SLUG sid=$P_SID8 slugsrc=$P_SLUG_SRC reason=no-summary src=$P_NOSUM_SRC"; exit 0
  fi

  # Extract ONLY the Pending Tasks section (F2: no other section is ever kept). Heading is
  # "N. Name:" (optionally **bold**, asterisks stripped before matching); body runs to the
  # next heading. <analysis>...</analysis> is dropped first. The awk also reports (via a
  # tagged stderr line) whether a Pending Tasks heading was ever seen at all -- SF-M1:
  # "the heading never matched" (a Claude Code format-drift regression) is a DIFFERENT,
  # much louder failure than "the heading matched and genuinely listed zero tasks".
  P_SECFLAG=$(mktemp)
  P_PENDING=$(printf '%s\n' "$P_SUMMARY" | awk '
    /<analysis>/,/<\/analysis>/ { next }
    {
      stripped = $0
      gsub(/\*/, "", stripped)
      if (stripped ~ /^[0-9]+\.[ \t]+[^:]+:[ \t]*$/) {
        name = stripped
        sub(/^[0-9]+\.[ \t]+/, "", name)
        sub(/:[ \t]*$/, "", name)
        insec = (index(tolower(name), "pending tasks") > 0) ? 1 : 0
        if (insec) sawsec = 1
        next
      }
      if (insec && $0 ~ /^[ \t]*[-*][ \t]+/) {
        text = $0
        sub(/^[ \t]*[-*][ \t]+/, "", text)
        low = tolower(text)
        if (low ~ /^none/ || low ~ /^no /  || low ~ /^n\/a/ || low ~ /^nothing/ || low ~ /^\(none/) next
        if (hits < 5) { hits++; print text }
      }
    }
    END { print (sawsec ? 1 : 0) > "/dev/stderr" }
  ' 2>"$P_SECFLAG")
  P_SAWSEC=$(cat "$P_SECFLAG" 2>/dev/null); rm -f "$P_SECFLAG"
  if [ -z "$P_PENDING" ]; then
    if [ "$P_SAWSEC" = "1" ]; then
      SB_GATE="postcompact-capture slug=$P_SLUG sid=$P_SID8 slugsrc=$P_SLUG_SRC source=$P_SRC pending=0"; exit 0
    fi
    sb_log_error "pre-compact.sh" "gate=postcompact-capture reason=no-pending-section slug=$P_SLUG sid=$P_SID8 source=$P_SRC" 1
    SB_GATE="postcompact-capture slug=$P_SLUG sid=$P_SID8 slugsrc=$P_SLUG_SRC source=$P_SRC reason=no-pending-section"; exit 0
  fi

  # SF-H1/SEC-M3/SEC-M4: cut/sanitize/scan now happen ONCE, inside merge-project-update.sh's
  # shared gate_untrusted_items() -- this hook's job stops at "extract the Pending Tasks
  # bullets and pass them through" so compact_pending and the extractor's own plan[] share
  # exactly one trust boundary instead of two independently-maintained ones.
  P_BULLETS=$(printf '%s' "$P_PENDING" | jq -Rs 'split("\n") | map(select(length>0))' 2>/dev/null)
  if [ -z "$P_BULLETS" ] || ! printf '%s' "$P_BULLETS" | jq -e 'type=="array"' >/dev/null 2>&1; then
    # SF-L2: a jq failure building the bullets array must be LOUD, not a silent fallback
    # to '[]' that looks identical to "the Pending Tasks section genuinely had zero items".
    sb_log_error "pre-compact.sh" "gate=postcompact-capture reason=bullets-build-failed slug=$P_SLUG sid=$P_SID8" 1
    P_BULLETS='[]'
  fi
  P_KNOWLEDGE_DIR="$(sb_knowledge_dir)"
  P_MERGE_ERR=$(mktemp)
  P_MERGE_STATUS="ok"
  if ! jq -nc --argjson b "$P_BULLETS" '{compact_pending: $b}' \
      | bash "$(dirname "$0")/merge-project-update.sh" --project-md "$P_PROJECT_MD" \
          --knowledge-dir "$P_KNOWLEDGE_DIR" --session "$P_SID" >/dev/null 2>"$P_MERGE_ERR"; then
    P_ERR_TAIL=$(tr '\n' ' ' < "$P_MERGE_ERR" | head -c 300)
    sb_log_error "pre-compact.sh" "postcompact-capture merge-failed err=$P_ERR_TAIL" 1
    P_MERGE_STATUS="failed"
  fi
  rm -f "$P_MERGE_ERR"

  # SF-L2: the gate row must say whether the merge actually SUCCEEDED -- pending=N alone
  # looked identical whether those N bullets landed in PROJECT.md or the merge call itself
  # failed outright.
  P_COUNT=$(printf '%s' "$P_BULLETS" | jq 'length' 2>/dev/null); case "$P_COUNT" in ''|*[!0-9]*) P_COUNT=0 ;; esac
  SB_GATE="postcompact-capture slug=$P_SLUG sid=$P_SID8 slugsrc=$P_SLUG_SRC source=$P_SRC pending=$P_COUNT merge=$P_MERGE_STATUS"
  exit 0
fi

# Tier intent, not a literal: SB_EXTRACTOR_MODEL is declared as a MID pin in model-ladder.json
# and is applied by sb_resolve_model as rung 0, per attempt, inside sb_call_extractor.
EXTRACTOR_MODEL="tier:mid"
# 30s inside the 45s hooks.json budget: >=15s headroom so the hook can't be
# killed between extraction and the marker write (HOOK-10 kill-after-extract).
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-30}"

# --- Read hook payload from stdin ---
RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then SB_GATE="empty-stdin"; exit 0; fi

# jq -e status: 1 = not an object, 4/5 = no value / not JSON (2: jq 1.6's parse error); any other
# status is jq itself failing (126/127 not runnable, 128+N killed): an error row with the status,
# never the routine gate (stop-extract.sh does the same). The window is not archived; a later hook
# retries it. The field reads below check jq's status for the same reason.
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; _pc_jq_rc=$?
case "$_pc_jq_rc" in
  0) ;;
  1|2|4|5) SB_GATE="stdin-not-json-object"; exit 0 ;;
  *) sb_log_error "pre-compact.sh" "jq exited $_pc_jq_rc checking the PreCompact payload (jq missing, not executable or killed); the window is neither archived nor extracted, a later hook retries it" 1
     exit 0 ;;
esac

_pc_jq_rc=0
TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r'; exit "${PIPESTATUS[1]}") || _pc_jq_rc=$?
CWD=$(echo "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r'; exit "${PIPESTATUS[1]}") || _pc_jq_rc=$?
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r'; exit "${PIPESTATUS[1]}") || _pc_jq_rc=$?
if [ "$_pc_jq_rc" -ne 0 ]; then
  sb_log_error "pre-compact.sh" "jq exited $_pc_jq_rc reading the PreCompact payload's fields; the window is neither archived nor extracted, a later hook retries it" 1
  exit 0
fi
if [ -z "$TRANSCRIPT" ]; then SB_GATE="transcript-path-empty"; exit 0; fi
if [ ! -f "$TRANSCRIPT" ]; then SB_GATE="transcript-file-missing path=$TRANSCRIPT"; exit 0; fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(sb_resolve_slug "$CWD")
else
  SLUG=$(sb_resolve_slug "$PWD")
fi
if [ -z "$SLUG" ]; then SB_GATE="slug-empty"; exit 0; fi
MARKER_KEY=$(sb_extraction_marker_key "$SLUG" "$SESSION_ID")

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
KNOWLEDGE_DIR="$(sb_knowledge_dir)"

# --- Determine unprocessed window ---
LAST_LINE=$(sb_get_extraction_marker "$MARKER_KEY")
# Record count, NOT `wc -l`: a transcript whose final JSONL line lacks a trailing
# newline (read mid-flush) would be undercounted by one, dropping that record from the
# window + advancing the marker past it permanently. awk NR is newline-safe.
TOTAL_LINES=$(awk 'END{print NR}' "$TRANSCRIPT" 2>/dev/null)
# Stale-marker clamp (deep-review): a marker past EOF would gate forever now
# that markers persist — treat it as no marker.
if [ "$LAST_LINE" -gt "$TOTAL_LINES" ]; then
  LAST_LINE=0
fi

# --- Archive-first (0.56.0, R2#2) ---
# Append the raw window (raw_line cursor, TOTAL_LINES] to the session archive before every
# extraction gate (PROJECT.md present, >= 20 new lines, a tool_use) and before the merge:
# archiving needs none of them, and a window the gates skip is still captured. Same helper and
# cursor (.last-archived-line-*) as stop-extract.sh, so the two hooks append disjoint windows.
sb_archive_raw_window "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$TOTAL_LINES" "$MARKER_KEY" || true

if [ ! -f "$PROJECT_MD" ]; then SB_GATE="project-md-missing slug=$SLUG"; exit 0; fi
NEW_LINES=$((TOTAL_LINES - LAST_LINE))

if [ "$NEW_LINES" -lt 20 ]; then
  SB_GATE="window-too-small new=$NEW_LINES total=$TOTAL_LINES marker=$LAST_LINE"
  exit 0
fi

START_LINE=$((LAST_LINE + 1))

# Gate: at least one tool_use in the window. The buddy's end-of-turn buddy_react call is chat,
# not work (same rule as stop-extract.sh's substantive gate). Per-line parse
# (sb_window_tool_count): a record cut mid-write no longer hides the rest of the window.
# A failed count (sed or jq killed or missing) is not "no tool calls": the marker stays, and the
# next PreCompact or Stop examines the window again (stop-extract.sh does the same).
if ! TOOL_COUNT=$(sb_window_tool_count "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES"); then
  sb_log_error "pre-compact.sh" "the tool count of raw lines ${START_LINE}-${TOTAL_LINES} failed (sed or jq); the marker stays at $LAST_LINE and a later hook examines the window again" 1
  exit 0
fi

if [ "$TOOL_COUNT" -lt 1 ]; then
  SB_GATE="tool-count-zero-in-window new_lines=$NEW_LINES"
  sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
  exit 0
fi

# C4/F3 (Slice 1 §5.1): stamp provenance NOW, right after the substantive gate confirms this
# window is real -- BEFORE the LLM call, so a killed/timed-out extraction still leaves a fresh
# .prov file for a later Stop/PostCompact's Handoff stamp to read.
sb_session_prov_write "$SESSION_ID" "${CLAUDE_PROJECT_DIR:-$CWD}"

# --- Build extraction input ---
PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
if [ ! -f "$PROMPT_FILE" ]; then SB_GATE="prompt-file-missing"; exit 0; fi
PROMPT=$(cat "$PROMPT_FILE")

EXTRACT_INPUT=$(mktemp)
EXTRACT_OUT=$(mktemp)

# Cap window at 1000 JSONL lines to keep LLM input reasonable
WINDOW_CAP=1000
if [ "$NEW_LINES" -gt "$WINDOW_CAP" ]; then
  WINDOW_START=$((TOTAL_LINES - WINDOW_CAP + 1))
else
  WINDOW_START=$START_LINE
fi

# Every part of the input is checked, as stop-extract.sh and the drainer's sb_extract_transcript
# do: a failed render (sb_preprocess_transcript returns 1: jq killed or missing, the scrub failed;
# its output must not be used) is never sent to the extractor; the deterministic floor runs.
EXTRACT_INPUT_OK=1 _ei_why=""
{
  echo "=== PROJECT.md ===" && cat "$PROJECT_MD" && echo && echo "---SEPARATOR---" && echo \
    && echo "=== TRANSCRIPT (preprocessed) ==="
} > "$EXTRACT_INPUT" || { EXTRACT_INPUT_OK=0; _ei_why="its PROJECT.md header could not be written"; }
sed -n -- "${WINDOW_START},${TOTAL_LINES}p" "$TRANSCRIPT" | sb_preprocess_transcript >> "$EXTRACT_INPUT"
_ei_ps="${PIPESTATUS[*]}"
# The row names the part that failed: a header failure used to read "render pipe status 0 0".
[ "$_ei_ps" = "0 0" ] || { EXTRACT_INPUT_OK=0; _ei_why="${_ei_why:+$_ei_why; }the transcript render failed (sed|render status $_ei_ps)"; }

# --- Run LLM extraction ---
DELTA_JSON=""

# sb_call_extractor (lib.sh) tries claude CLI then ANTHROPIC_API_KEY fallback
# and writes .extractor-health.json so session-load.sh can surface failures.
if [ "${SB_EXTRACT:-on}" = "off" ]; then
  SB_GATE="extract-off"
elif [ "$EXTRACT_INPUT_OK" != 1 ]; then
  sb_log_error "pre-compact.sh" "extractor input for raw lines ${WINDOW_START}-${TOTAL_LINES} could not be built: ${_ei_why}; not sent to the extractor, deterministic floor instead (the archived window is mined later)" 1
elif sb_call_extractor "$EXTRACT_INPUT" "$EXTRACT_OUT" "$EXTRACTOR_MODEL" "$PROMPT" "$EXTRACT_TIMEOUT"; then
  DELTA_JSON=$(cat "$EXTRACT_OUT")
else
  HEALTH_REASON=$(sb_get_extractor_health | jq -r '.reason // "unknown"' 2>/dev/null | tr -d '\r')
  sb_log_error "pre-compact.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=$HEALTH_REASON" 0
fi

# Deterministic fallback when the LLM is unavailable (sb_degraded_floor, lib.sh, shared with
# stop-extract.sh): the files-changed floor of the FULL window reaches PROJECT.md, and ONE
# [degraded] breadcrumb per day goes to the pending-extraction.log SIDECAR (SP-E). This path used to
# merge an empty delta, so a compaction under a dead LLM captured no decision at all. The window is
# archived (archive-first) for the drainer's later recovery of the real knowledge.
if [ -z "$DELTA_JSON" ]; then
  DELTA_JSON=$(sb_degraded_floor "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES" "$PROJECT_MD")
fi

# --- Quality gate (D157) ---
# Shared with stop-extract.sh and the out-of-band drainer (sb_gate_extraction_
# delta, lib.sh) so every capture path filters low-quality extractions the
# same way. Fail-open on gate failure.
DELTA_JSON=$(sb_gate_extraction_delta "$DELTA_JSON")

# --- Merge delta into PROJECT.md ---
MERGE_ERR=$(mktemp)
MERGE_FAILED=0
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" --session "$SESSION_ID" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  sb_log_error "pre-compact.sh" "merge-failed err=$ERR_TAIL" 0
  MERGE_FAILED=1
fi
rm -f "$MERGE_ERR"; MERGE_ERR=""

# --- Relationship edges (typed, bi-temporal), D157 ---
# Shared with stop-extract.sh and the drainer (sb_merge_extraction_edges,
# lib.sh). Runs AFTER the merge above so relations[] endpoints can resolve
# against wiki stub pages merge-project-update.sh's cross_refs handling may
# have just scaffolded. Best-effort — never fails the hook.
sb_merge_extraction_edges "$DELTA_JSON" "$KNOWLEDGE_DIR"

# --- Persona signal + rule-candidate extraction ---
PERSONA_PAYLOAD=$(echo "$DELTA_JSON" | jq -c \
  '{persona_signals: (.persona_signals // []), rule_candidates: (.rule_candidates // [])}')
if echo "$PERSONA_PAYLOAD" | jq -e '(.persona_signals | length) + (.rule_candidates | length) > 0' >/dev/null 2>&1; then
  PERSONA_ERR=$(mktemp)
  if ! echo "$PERSONA_PAYLOAD" \
    | bash "$(dirname "$0")/merge-persona-signals.sh" --slug "$SLUG" 2>"$PERSONA_ERR"; then
    ERR_TAIL=$(tr '\n' ' ' < "$PERSONA_ERR" | head -c 200)
    sb_log_error "pre-compact.sh" "persona-merge-failed err=$ERR_TAIL" 0
  fi
  rm -f "$PERSONA_ERR"; PERSONA_ERR=""
fi

# --- Sessions digest (P0 rec 4): same-session entry is REPLACED at the next
# Stop, so a mid-session PreCompact append never duplicates and never goes
# stale past the session's end.
DG_GOAL=$(echo "$DELTA_JSON" | jq -r '.session_goal // ""' 2>/dev/null | tr -d '\r')
DG_OUT=$(echo "$DELTA_JSON" | jq -r '.session_outcome // ""' 2>/dev/null | tr -d '\r')
sb_append_session_digest "$SLUG" "$SESSION_ID" "$DG_GOAL" "$DG_OUT" || true

# (The FULL raw window, not the LLM-capped one, was archived above: archive-first.)

# --- Incremental episodic index update ---
# D179: the backgrounded index build must not inherit the hook's stdout (a reader of a pipe only
# sees EOF once every holder closes it). 0.56.0: the SUBSHELL's fds are redirected too, not only
# node's: the waiting subshell held the pipe open just the same. Failures are fail-loud via
# sb_log_error (it writes files, not stdout).
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  EIDX_LOG="$BRAIN_DIR/episodic-index.log"
  ( BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" >>"$EIDX_LOG" 2>&1
    _eidx_ec=$?
    [ "$_eidx_ec" -ne 0 ] && sb_log_error "pre-compact.sh" "episodic-index-cli exited $_eidx_ec (see $EIDX_LOG)" "$_eidx_ec"
  ) </dev/null >/dev/null 2>&1 &
fi

# --- Update extraction marker ---
# D177 (as stop-extract.sh): a failed merge means this window's decisions never reached PROJECT.md,
# so the marker stays where it is and the next PreCompact or Stop retries the window (the archive
# has its own cursor, so the retry does not re-archive it).
[ "$MERGE_FAILED" = "1" ] || sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"

exit 0
