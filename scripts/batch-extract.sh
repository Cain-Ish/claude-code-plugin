#!/bin/bash
# Batch extraction: process all substantive sessions from a Claude project dir
# Usage: bash batch-extract.sh <project-transcripts-dir> <project-slug>
set -u
source "$(dirname "$0")/lib.sh"

TRANSCRIPTS_DIR="${1:?Usage: batch-extract.sh <transcripts-dir> <slug>}"
SLUG="${2:?Usage: batch-extract.sh <transcripts-dir> <slug>}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXTRACT_PROMPT=$(cat "$PLUGIN_DIR/scripts/extract-prompt.txt")
PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
WIKI_DIR="$BRAIN_DIR/wiki"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
MODEL="${SB_EXTRACTOR_MODEL:-claude-sonnet-4-6}"

[ -f "$PROJECT_MD" ] || { echo "ERROR: $PROJECT_MD not found"; exit 1; }

preprocess() {
  local transcript="$1"
  tail -n 500 "$transcript" | sb_preprocess_transcript
}

TOTAL=0
SUCCESS=0
FAILED=0

for f in "$TRANSCRIPTS_DIR"/*.jsonl; do
  [ ! -f "$f" ] && continue
  SIZE=$(wc -c < "$f" | tr -d ' ')
  [ "$SIZE" -lt 100000 ] && continue

  FIRST=$(jq -r 'select(.type == "user") | .message.content' "$f" 2>/dev/null | head -c 60 | tr '\n' ' ')
  echo "$FIRST" | grep -q "session summarizer" && continue
  echo "$FIRST" | grep -q "Context: This summary" && continue
  [ -z "$FIRST" ] && continue

  TOTAL=$((TOTAL + 1))
  BASENAME=$(basename "$f")
  echo "[$TOTAL] Processing $BASENAME ($(( SIZE / 1024 ))KB)..."

  INPUT_FILE=$(mktemp)
  OUTPUT_FILE=$(mktemp)
  {
    echo "=== PROJECT.md ==="
    cat "$PROJECT_MD"
    echo
    echo "---SEPARATOR---"
    echo
    echo "=== TRANSCRIPT (preprocessed) ==="
    preprocess "$f"
  } > "$INPUT_FILE"

  INPUT_SIZE=$(wc -c < "$INPUT_FILE" | tr -d ' ')
  if [ "$INPUT_SIZE" -lt 500 ]; then
    echo "  SKIP: preprocessed input too small (${INPUT_SIZE}B)"
    rm -f "$INPUT_FILE" "$OUTPUT_FILE"
    continue
  fi

  claude -p "$EXTRACT_PROMPT" --model "$MODEL" < "$INPUT_FILE" > "$OUTPUT_FILE" 2>/dev/null

  if jq -e 'type == "object"' "$OUTPUT_FILE" >/dev/null 2>&1; then
    DECISIONS=$(jq -r '.recent_decisions | length' "$OUTPUT_FILE" 2>/dev/null)
    WIKI_UPD=$(jq -r '.wiki_updates | length' "$OUTPUT_FILE" 2>/dev/null)
    echo "  OK: ${DECISIONS} decisions, ${WIKI_UPD} wiki_updates"

    cat "$OUTPUT_FILE" | bash "$PLUGIN_DIR/scripts/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --wiki-dir "$WIKI_DIR" --knowledge-dir "$KNOWLEDGE_DIR" 2>/dev/null

    PERSONA_SIGNALS=$(jq -c '.persona_signals // []' "$OUTPUT_FILE" 2>/dev/null)
    if echo "$PERSONA_SIGNALS" | jq -e 'length > 0' >/dev/null 2>&1; then
      echo "$PERSONA_SIGNALS" | bash "$PLUGIN_DIR/scripts/merge-persona-signals.sh" 2>/dev/null || true
    fi

    SUCCESS=$((SUCCESS + 1))
  else
    echo "  FAIL: invalid JSON output"
    FAILED=$((FAILED + 1))
  fi

  rm -f "$INPUT_FILE" "$OUTPUT_FILE"
done

echo ""
echo "=== BATCH COMPLETE ==="
echo "Total: $TOTAL | Success: $SUCCESS | Failed: $FAILED"
