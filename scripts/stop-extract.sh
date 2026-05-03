#!/bin/bash
# Stop-hook orchestrator (v1.2.0). Reads the Stop hook payload, decides
# whether the session was substantive enough to extract from, calls the
# `claude` CLI as a subprocess to produce a structured JSON delta, and
# pipes that delta into merge-project-update.sh.
#
# Replaces the older run-stop-predicate.sh entry that only wrote a flag
# file nobody read. The baseline-vs-current PROJECT.md predicate is no
# longer the gate (PROJECT.md only changes if extraction ran, so it's
# circular). The new gate is "transcript has at least one tool_use" —
# pure Q&A sessions skip the LLM call.
#
# Always exits 0 (fail-soft). A crash in this hook must never block
# Claude's stop event.
#
# Honors env overrides:
#   SB_EXTRACTOR_MODEL — model passed via `claude -p --model <id>`
#                        (default: claude-haiku-4-5-20251001)
#   SB_EXTRACT_TIMEOUT — seconds to wait for `claude` (default: 25)
set -u

source "$(dirname "$0")/lib.sh"

EXTRACTOR_MODEL="${SB_EXTRACTOR_MODEL:-claude-haiku-4-5-20251001}"
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-25}"

RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo       "$RAW" | jq -r '.cwd             // empty' 2>/dev/null | tr -d '\r')
[ -n "$TRANSCRIPT" ] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")")
else
  SLUG=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
fi
[ -n "$SLUG" ] || exit 0

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
WIKI_DIR="$BRAIN_DIR/wiki"
[ -f "$PROJECT_MD" ] || exit 0
mkdir -p "$WIKI_DIR" 2>/dev/null || exit 0

# Substantive-session gate: count tool_use entries in the transcript.
TOOL_COUNT=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  exit 0
fi

PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
[ -f "$PROMPT_FILE" ] || exit 0
PROMPT=$(cat "$PROMPT_FILE")

EXTRACT_INPUT=$(mktemp)
EXTRACT_OUT=$(mktemp)
trap 'rm -f "$EXTRACT_INPUT" "$EXTRACT_OUT" 2>/dev/null' EXIT
{
  echo "=== PROJECT.md ==="
  cat "$PROJECT_MD"
  echo
  echo "---SEPARATOR---"
  echo
  echo "=== TRANSCRIPT (truncated to last 500 lines) ==="
  tail -n 500 "$TRANSCRIPT"
} > "$EXTRACT_INPUT"

DELTA_JSON=""

if command -v claude >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "$EXTRACT_TIMEOUT" claude -p "$PROMPT" --model "$EXTRACTOR_MODEL" \
      < "$EXTRACT_INPUT" > "$EXTRACT_OUT" 2>/dev/null || true
  else
    claude -p "$PROMPT" --model "$EXTRACTOR_MODEL" \
      < "$EXTRACT_INPUT" > "$EXTRACT_OUT" 2>/dev/null || true
  fi
  if [ -s "$EXTRACT_OUT" ] && jq -e 'type == "object"' "$EXTRACT_OUT" >/dev/null 2>&1; then
    DELTA_JSON=$(cat "$EXTRACT_OUT")
  fi
fi

# Deterministic fallback when LLM is unavailable or its output was bad.
if [ -z "$DELTA_JSON" ]; then
  FILES_JSON=$(jq -rcs '
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
  ' "$TRANSCRIPT" 2>/dev/null || echo '[]')
  FILES_JSON=$(sb_safe_json_array "$FILES_JSON")
  DELTA_JSON=$(jq -cn --argjson f "$FILES_JSON" '{
    recent_decisions: [],
    open_blockers:    [],
    cross_refs:       [],
    files_touched:    $f
  }')
  # Encode files_touched into a Recent-decisions bullet so the merge has
  # somewhere to actually write — files_touched alone has no destination
  # in the v1.0 PROJECT.md template. Cap at 5 paths to stay terse.
  if echo "$FILES_JSON" | jq -e 'length > 0' >/dev/null 2>&1; then
    FILES_LIST=$(echo "$FILES_JSON" | jq -r '.[0:5] | join(", ")')
    NOTE="files this session: $FILES_LIST"
    DELTA_JSON=$(echo "$DELTA_JSON" | jq -c --arg n "$NOTE" '
      .recent_decisions = [$n]
    ')
  fi
fi

echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --wiki-dir "$WIKI_DIR" >/dev/null 2>&1 || true

rm -f "$BRAIN_DIR/.session-baseline-$SLUG.md"

exit 0
