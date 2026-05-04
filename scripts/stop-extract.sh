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

# Defensive lib.sh source. If lib.sh is missing the script would crash on
# first $BRAIN_DIR reference under `set -u` and leave no trace. Without
# sb_log_error available we fall back to a raw append so the failure is
# at least diagnosable.
LIB="$(dirname "$0")/lib.sh"
if ! source "$LIB" 2>/dev/null; then
  printf '{"timestamp":"%s","script":"stop-extract.sh","message":"lib.sh source failed: %s","exit_code":0}\n' \
    "$(date -u +%FT%TZ)" "$LIB" >> "$HOME/.second-brain/error-log.jsonl" 2>/dev/null
  exit 0
fi

# Hook trace tag — set by each gate before exit, written by EXIT trap. Lets
# the next /second-brain:status surface exactly which gate the script tripped.
SB_GATE=""
log_gate() { SB_GATE="$1"; }
trap '[ -n "$SB_GATE" ] && sb_log_error "stop-extract.sh" "gate=$SB_GATE" 0' EXIT

EXTRACTOR_MODEL="${SB_EXTRACTOR_MODEL:-claude-haiku-4-5-20251001}"
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-25}"

RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then log_gate "empty-stdin"; exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  log_gate "stdin-not-json-object"
  exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo       "$RAW" | jq -r '.cwd             // empty' 2>/dev/null | tr -d '\r')
if [ -z "$TRANSCRIPT" ]; then log_gate "transcript-path-empty cwd=$CWD"; exit 0; fi
if [ ! -f "$TRANSCRIPT" ]; then log_gate "transcript-file-missing path=$TRANSCRIPT"; exit 0; fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")")
else
  SLUG=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
fi
if [ -z "$SLUG" ]; then log_gate "slug-empty cwd=$CWD pwd=$PWD"; exit 0; fi

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
WIKI_DIR="$BRAIN_DIR/wiki"
if [ ! -f "$PROJECT_MD" ]; then log_gate "project-md-missing slug=$SLUG path=$PROJECT_MD"; exit 0; fi
if ! mkdir -p "$WIKI_DIR" 2>/dev/null; then log_gate "wiki-dir-mkdir-failed path=$WIKI_DIR"; exit 0; fi

# Substantive-session gate: count tool_use entries in the transcript.
TOOL_COUNT=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  # Q&A-only is a normal no-op, NOT an error — but log a one-line schema
  # probe so we can spot the case where the jq query never matches because
  # the transcript schema differs from what we expect.
  TS_LINES=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
  TS_FIRST_TYPE=$(head -1 "$TRANSCRIPT" 2>/dev/null | jq -r '.type // "no-type"' 2>/dev/null | tr -d '\n')
  log_gate "tool-count-zero lines=$TS_LINES first-type=$TS_FIRST_TYPE"
  exit 0
fi

PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
if [ ! -f "$PROMPT_FILE" ]; then log_gate "prompt-file-missing path=$PROMPT_FILE"; exit 0; fi
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

MERGE_ERR=$(mktemp)
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --wiki-dir "$WIKI_DIR" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  log_gate "merge-failed err=$ERR_TAIL"
fi
rm -f "$MERGE_ERR"

rm -f "$BRAIN_DIR/.session-baseline-$SLUG.md"

exit 0
