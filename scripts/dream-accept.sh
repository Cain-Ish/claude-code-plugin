#!/bin/bash
# Accept a completed dream: copy staging wiki to live wiki, reindex, archive dream.
#
# Usage: dream-accept.sh <dream_id>
set -u
source "$(dirname "$0")/lib.sh"

DREAM_ID="${1:?usage: dream-accept.sh <dream_id>}"
DREAM_DIR="$BRAIN_DIR/dreams/$DREAM_ID"

if [ ! -f "$DREAM_DIR/status.json" ]; then
  echo "error: dream not found: $DREAM_ID" >&2
  exit 1
fi

STATUS=$(jq -r '.status' "$DREAM_DIR/status.json" 2>/dev/null)
if [ "$STATUS" != "completed" ]; then
  echo "error: dream $DREAM_ID is $STATUS, not completed" >&2
  exit 1
fi

ARCHIVED=$(jq -r '.archived_at // ""' "$DREAM_DIR/status.json" 2>/dev/null)
if [ -n "$ARCHIVED" ] && [ "$ARCHIVED" != "null" ]; then
  echo "error: dream $DREAM_ID already accepted/archived at $ARCHIVED" >&2
  exit 1
fi

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
LIVE_WIKI="$KNOWLEDGE_DIR/wiki"
STAGING_WIKI="$DREAM_DIR/staging/wiki"

if [ ! -d "$STAGING_WIKI" ]; then
  echo "error: staging wiki not found" >&2
  exit 1
fi

# Apply: rsync staging over live wiki (preserves files not in staging)
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$STAGING_WIKI/" "$LIVE_WIKI/"
else
  rm -rf "$LIVE_WIKI"
  cp -r "$STAGING_WIKI" "$LIVE_WIKI"
fi

# Reindex
sb_reindex_wiki "$KNOWLEDGE_DIR"

# Archive the dream
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg t "$NOW" '.archived_at = $t' "$DREAM_DIR/status.json" > "$tmp" && mv "$tmp" "$DREAM_DIR/status.json"

# Clean up staging to reclaim disk
rm -rf "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

ADDED=$(jq -r '.outputs.pages_added // 0' "$DREAM_DIR/status.json")
MODIFIED=$(jq -r '.outputs.pages_modified // 0' "$DREAM_DIR/status.json")
REMOVED=$(jq -r '.outputs.pages_removed // 0' "$DREAM_DIR/status.json")
echo "Dream $DREAM_ID accepted: +$ADDED ~$MODIFIED -$REMOVED pages applied to live wiki"
