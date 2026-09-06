#!/bin/bash
# PreCompact hook. Runs LLM extraction on the unprocessed transcript
# window BEFORE compaction discards context. Ensures decisions, patterns, and
# knowledge from early in long sessions survive compaction cycles.
#
# Works in tandem with stop-extract.sh: both use a shared line-marker file
# (.last-extracted-line-<slug>--<session_id>) so each processes a disjoint window.
#
# Honors env overrides:
#   SB_EXTRACT_TIMEOUT — seconds to wait for `claude` (default: 30)
#   SB_EXTRACT=off      — kill switch: skip the LLM extraction call entirely (no
#                        API spend). The transcript window is still archived and
#                        the marker still advances — a deterministic files-touched
#                        delta merges instead, same as an LLM failure would produce.
#
# Always exits 0 (fail-soft).
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

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

# Tier intent, not a literal: SB_EXTRACTOR_MODEL is declared as a MID pin in model-ladder.json
# and is applied by sb_resolve_model as rung 0, per attempt, inside sb_call_extractor.
EXTRACTOR_MODEL="tier:mid"
# 30s inside the 45s hooks.json budget: >=15s headroom so the hook can't be
# killed between extraction and the marker write (HOOK-10 kill-after-extract).
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-30}"

# --- Read hook payload from stdin ---
RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then SB_GATE="empty-stdin"; exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  SB_GATE="stdin-not-json-object"; exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
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
if [ ! -f "$PROJECT_MD" ]; then SB_GATE="project-md-missing slug=$SLUG"; exit 0; fi

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
NEW_LINES=$((TOTAL_LINES - LAST_LINE))

if [ "$NEW_LINES" -lt 20 ]; then
  SB_GATE="window-too-small new=$NEW_LINES total=$TOTAL_LINES marker=$LAST_LINE"
  exit 0
fi

START_LINE=$((LAST_LINE + 1))

# Gate: at least one tool_use in the window
TOOL_COUNT=$(sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' 2>/dev/null | wc -l | tr -d ' ')

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  SB_GATE="tool-count-zero-in-window new_lines=$NEW_LINES"
  sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
  exit 0
fi

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

{
  echo "=== PROJECT.md ==="
  cat "$PROJECT_MD"
  echo
  echo "---SEPARATOR---"
  echo
  echo "=== TRANSCRIPT (preprocessed) ==="
  sed -n "${WINDOW_START},${TOTAL_LINES}p" "$TRANSCRIPT" | sb_preprocess_transcript
} > "$EXTRACT_INPUT"

# --- Run LLM extraction ---
DELTA_JSON=""

# sb_call_extractor (lib.sh) tries claude CLI then ANTHROPIC_API_KEY fallback
# and writes .extractor-health.json so session-load.sh can surface failures.
if [ "${SB_EXTRACT:-on}" = "off" ]; then
  SB_GATE="extract-off"
elif sb_call_extractor "$EXTRACT_INPUT" "$EXTRACT_OUT" "$EXTRACTOR_MODEL" "$PROMPT" "$EXTRACT_TIMEOUT"; then
  DELTA_JSON=$(cat "$EXTRACT_OUT")
else
  HEALTH_REASON=$(sb_get_extractor_health | jq -r '.reason // "unknown"' 2>/dev/null | tr -d '\r')
  sb_log_error "pre-compact.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=$HEALTH_REASON" 0
fi

# Deterministic fallback: single [degraded] breadcrumb in a SIDECAR (not PROJECT.md
# decisions — SP-E), deduped per day. The transcript is archived for out-of-band drainer
# recovery of the real knowledge; this just logs the gap.
if [ -z "$DELTA_JSON" ]; then
  TODAY=$(date -u +%Y-%m-%d)
  PENDING_LOG="$(dirname "$PROJECT_MD")/pending-extraction.log"
  if grep -qF "[$TODAY] [degraded]" "$PENDING_LOG" 2>/dev/null; then
    DELTA_JSON='{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
  else
    # Scratch-path filter: /tmp, /var/tmp, /proc, /dev, /run are session-ephemeral
    # and have no value as future-session context — they only bloat the hot tier.
    FILES_JSON=$(sed -n "${WINDOW_START},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -rcs '
      [
        .[]
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
        | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit")
        | .input.file_path
      ]
      | unique
      | map(select(. != null and . != ""))
    ' 2>/dev/null || echo '[]')
    FILES_JSON=$(sb_safe_json_array "$FILES_JSON")
    # D111: sb_filter_scratch_paths (lib.sh) catches Windows AppData\Local\Temp and
    # macOS $TMPDIR (/var/folders/...) forms the old POSIX-only test() missed.
    FILES_JSON=$(sb_filter_scratch_paths "$FILES_JSON")
    FILES_JSON=$(printf '%s' "$FILES_JSON" | jq -c '.[0:5]' 2>/dev/null || echo '[]')
    FILES_LIST=$(echo "$FILES_JSON" | jq -r 'join(", ")' 2>/dev/null | tr -d '\r')
    if [ -n "$FILES_LIST" ]; then
      NOTE="[degraded] LLM extraction unavailable; session touched: $FILES_LIST"
    else
      NOTE="[degraded] LLM extraction unavailable; tool-only session (transcript archived)"
    fi
    # Sidecar (out of PROJECT.md decisions), bounded to 50 lines.
    mkdir -p "$(dirname "$PENDING_LOG")" 2>/dev/null || true
    printf '[%s] %s\n' "$TODAY" "$NOTE" >> "$PENDING_LOG" 2>/dev/null || true
    if [ -f "$PENDING_LOG" ]; then
      tail -n 50 "$PENDING_LOG" > "$PENDING_LOG.tmp" 2>/dev/null && mv "$PENDING_LOG.tmp" "$PENDING_LOG" 2>/dev/null || rm -f "$PENDING_LOG.tmp" 2>/dev/null
    fi
    DELTA_JSON='{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
  fi
fi

# --- Quality gate (D157) ---
# Shared with stop-extract.sh and the out-of-band drainer (sb_gate_extraction_
# delta, lib.sh) so every capture path filters low-quality extractions the
# same way. Fail-open on gate failure.
DELTA_JSON=$(sb_gate_extraction_delta "$DELTA_JSON")

# --- Merge delta into PROJECT.md ---
MERGE_ERR=$(mktemp)
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  sb_log_error "pre-compact.sh" "merge-failed err=$ERR_TAIL" 0
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
    | bash "$(dirname "$0")/merge-persona-signals.sh" 2>"$PERSONA_ERR"; then
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

# --- Archive preprocessed transcript for dream mining ---
# Archive the FULL delta (not the LLM-capped window) so dream-mining never
# loses the middle of a >1000-line delta (deep-review).
sb_archive_transcript "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$START_LINE" "$TOTAL_LINES" "$TOOL_COUNT" 2>/dev/null || true

# --- Incremental episodic index update ---
# D179: redirect BOTH stdout and stderr of the backgrounded node process to a log
# file, never inherit the hook's own stdout (a reader of a pipe only sees EOF once
# every holder closes it). Failures are fail-loud via sb_log_error.
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  EIDX_LOG="$BRAIN_DIR/episodic-index.log"
  ( BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" >>"$EIDX_LOG" 2>&1
    _eidx_ec=$?
    [ "$_eidx_ec" -ne 0 ] && sb_log_error "pre-compact.sh" "episodic-index-cli exited $_eidx_ec (see $EIDX_LOG)" "$_eidx_ec"
  ) &
fi

# --- Update extraction marker ---
sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"

exit 0
