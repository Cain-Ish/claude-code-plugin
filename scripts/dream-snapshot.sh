#!/bin/bash
# Create a dream: snapshot wiki into staging, select and symlink transcripts,
# write status.json. Exits non-zero on failure with error on stderr.
#
# Usage: dream-snapshot.sh [--instructions "..."] [--slug <project>] [--since <date>] [--max-count N] [--model <id>]
# Outputs: the dream_id on stdout
set -u
source "$(dirname "$0")/lib.sh"

INSTRUCTIONS=""
FILTER_SLUG=""
FILTER_SINCE=""
MAX_COUNT=50
MODEL="claude-sonnet-4-6"

while [ $# -gt 0 ]; do
  case "$1" in
    --instructions) INSTRUCTIONS="$2"; shift 2 ;;
    --slug)         FILTER_SLUG="$2"; shift 2 ;;
    --since)
      if echo "$2" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        FILTER_SINCE="$2"
      else
        echo "error: --since must be YYYY-MM-DD, got: $2" >&2; exit 1
      fi
      shift 2 ;;
    --max-count)    MAX_COUNT="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI_DIR="$KNOWLEDGE_DIR/wiki"

if [ ! -d "$WIKI_DIR" ]; then
  echo "error: wiki directory missing at $WIKI_DIR" >&2
  exit 1
fi

# Guard: only one pending/running dream at a time
DREAMS_DIR="$BRAIN_DIR/dreams"
mkdir -p "$DREAMS_DIR"

for sf in "$DREAMS_DIR"/drm_*/status.json; do
  [ -f "$sf" ] || continue
  s=$(jq -r '.status' "$sf" 2>/dev/null)
  if [ "$s" = "pending" ] || [ "$s" = "running" ]; then
    did=$(jq -r '.id' "$sf" 2>/dev/null)
    echo "error: dream $did is already $s" >&2
    exit 1
  fi
done

# Prune to max 5 dream directories (only delete oldest archived dreams)
DREAM_COUNT=$(find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$DREAM_COUNT" -ge 5 ]; then
  find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | sort | while read -r old; do
    [ "$DREAM_COUNT" -lt 5 ] && break
    old_status=$(jq -r '.archived_at // ""' "$old/status.json" 2>/dev/null)
    if [ -n "$old_status" ] && [ "$old_status" != "null" ]; then
      rm -rf "$old"
      DREAM_COUNT=$((DREAM_COUNT - 1))
    fi
  done
fi

DREAM_ID=$(sb_generate_dream_id)
DREAM_DIR="$DREAMS_DIR/$DREAM_ID"
mkdir -p "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

# Snapshot wiki
cp -r "$WIKI_DIR" "$DREAM_DIR/staging/wiki"
SNAPSHOT_BYTES=$(find "$DREAM_DIR/staging/wiki" -type f -name '*.md' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
WIKI_PAGE_COUNT=$(find "$DREAM_DIR/staging/wiki" -type f -name '*.md' ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')

# Select and symlink transcripts
TRANSCRIPT_DIR="$BRAIN_DIR/transcripts"
SELECTED=0

if [ -d "$TRANSCRIPT_DIR" ]; then
  for tf in $(ls -1 "$TRANSCRIPT_DIR"/*.txt 2>/dev/null | sort -r); do
    [ "$SELECTED" -ge "$MAX_COUNT" ] && break

    if [ -n "$FILTER_SLUG" ]; then
      fname=$(basename "$tf")
      echo "$fname" | grep -q "_${FILTER_SLUG}_" || continue
    fi

    if [ -n "$FILTER_SINCE" ]; then
      fdate=$(basename "$tf" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
      [ -n "$fdate" ] && [ "$fdate" \< "$FILTER_SINCE" ] && continue
    fi

    ln -sf "$tf" "$DREAM_DIR/transcripts/$(basename "$tf")"
    SELECTED=$((SELECTED + 1))
  done
fi

# Write status.json
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
  --arg id "$DREAM_ID" \
  --arg now "$NOW" \
  --arg model "$MODEL" \
  --arg instr "$INSTRUCTIONS" \
  --argjson tc "$SELECTED" \
  --argjson wpc "$WIKI_PAGE_COUNT" \
  --argjson wsb "$SNAPSHOT_BYTES" \
  '{
    id: $id,
    status: "pending",
    created_at: $now,
    started_at: null,
    ended_at: null,
    archived_at: null,
    model: $model,
    instructions: $instr,
    inputs: {
      transcript_count: $tc,
      wiki_page_count: $wpc,
      wiki_snapshot_bytes: $wsb
    },
    outputs: {
      pages_added: 0,
      pages_modified: 0,
      pages_removed: 0
    },
    error: null
  }' > "$DREAM_DIR/status.json"

echo "$DREAM_ID"
