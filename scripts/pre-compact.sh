#!/bin/bash
# PreCompact hook (v1.7.0). Runs LLM extraction on the unprocessed transcript
# window BEFORE compaction discards context. Ensures decisions, patterns, and
# knowledge from early in long sessions survive compaction cycles.
#
# Works in tandem with stop-extract.sh: both use a shared line-marker file
# (.last-extracted-line-<slug>) so each processes a disjoint window.
#
# Always exits 0 (fail-soft).
set -u

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

EXTRACTOR_MODEL="${SB_EXTRACTOR_MODEL:-claude-sonnet-4-6}"
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-40}"

# --- Read hook payload from stdin ---
RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then SB_GATE="empty-stdin"; exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  SB_GATE="stdin-not-json-object"; exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
if [ -z "$TRANSCRIPT" ]; then SB_GATE="transcript-path-empty"; exit 0; fi
if [ ! -f "$TRANSCRIPT" ]; then SB_GATE="transcript-file-missing path=$TRANSCRIPT"; exit 0; fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(sb_resolve_slug "$CWD")
else
  SLUG=$(sb_resolve_slug "$PWD")
fi
if [ -z "$SLUG" ]; then SB_GATE="slug-empty"; exit 0; fi

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
if [ ! -f "$PROJECT_MD" ]; then SB_GATE="project-md-missing slug=$SLUG"; exit 0; fi

# --- Determine unprocessed window ---
LAST_LINE=$(sb_get_extraction_marker "$SLUG")
TOTAL_LINES=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
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
  sb_set_extraction_marker "$SLUG" "$TOTAL_LINES"
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

if command -v claude >/dev/null 2>&1; then
  CLAUDE_ARGS=(-p --bare --model "$EXTRACTOR_MODEL" --system-prompt "$PROMPT")
  if command -v timeout >/dev/null 2>&1; then
    timeout "$EXTRACT_TIMEOUT" claude "${CLAUDE_ARGS[@]}" \
      < "$EXTRACT_INPUT" > "$EXTRACT_OUT" 2>/dev/null || true
  else
    claude "${CLAUDE_ARGS[@]}" \
      < "$EXTRACT_INPUT" > "$EXTRACT_OUT" 2>/dev/null || true
  fi
  if [ -s "$EXTRACT_OUT" ]; then
    sb_strip_code_fences < "$EXTRACT_OUT" > "${EXTRACT_OUT}.clean"
    mv "${EXTRACT_OUT}.clean" "$EXTRACT_OUT"
  fi
  if [ -s "$EXTRACT_OUT" ] && jq -e 'type == "object"' "$EXTRACT_OUT" >/dev/null 2>&1; then
    DELTA_JSON=$(cat "$EXTRACT_OUT")
  else
    LLM_ERR=$(head -c 200 "$EXTRACT_OUT" 2>/dev/null | tr '\n' ' ')
    sb_log_error "pre-compact.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=${LLM_ERR:-empty}" 0
  fi
fi

# Deterministic fallback when LLM is unavailable or output was bad
if [ -z "$DELTA_JSON" ]; then
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
  DELTA_JSON=$(jq -cn --argjson f "$FILES_JSON" '{
    recent_decisions: [],
    open_blockers:    [],
    cross_refs:       [],
    files_touched:    $f
  }')
  if echo "$FILES_JSON" | jq -e 'length > 0' >/dev/null 2>&1; then
    FILES_LIST=$(echo "$FILES_JSON" | jq -r '.[0:5] | join(", ")')
    NOTE="files this session: $FILES_LIST"
    DELTA_JSON=$(echo "$DELTA_JSON" | jq -c --arg n "$NOTE" '.recent_decisions = [$n]')
  fi
fi

# --- Merge delta into PROJECT.md ---
MERGE_ERR=$(mktemp)
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  sb_log_error "pre-compact.sh" "merge-failed err=$ERR_TAIL" 0
fi
rm -f "$MERGE_ERR"; MERGE_ERR=""

# --- Persona signal extraction ---
PERSONA_SIGNALS=$(echo "$DELTA_JSON" | jq -c '.persona_signals // []')
if echo "$PERSONA_SIGNALS" | jq -e 'length > 0' >/dev/null 2>&1; then
  PERSONA_ERR=$(mktemp)
  if ! echo "$PERSONA_SIGNALS" \
    | bash "$(dirname "$0")/merge-persona-signals.sh" 2>"$PERSONA_ERR"; then
    ERR_TAIL=$(tr '\n' ' ' < "$PERSONA_ERR" | head -c 200)
    sb_log_error "pre-compact.sh" "persona-merge-failed err=$ERR_TAIL" 0
  fi
  rm -f "$PERSONA_ERR"; PERSONA_ERR=""
fi

# --- Archive preprocessed transcript for dream mining ---
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null)
sb_archive_transcript "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$WINDOW_START" "$TOTAL_LINES" "$TOOL_COUNT" 2>/dev/null || true

# --- Incremental episodic index update ---
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" 2>/dev/null &
fi

# --- Update extraction marker ---
sb_set_extraction_marker "$SLUG" "$TOTAL_LINES"

exit 0
