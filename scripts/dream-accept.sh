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

# SECURITY (C/headless-maintainer hardening): staging is written by the consolidation agent —
# under the opt-in headless maintainer that agent is UNATTENDED and could be prompt-injected by
# captured wiki content. A symlink in staging that points OUTSIDE the wiki (e.g. → ~/.claude or
# ~/knowledge/graph) would, on the copy below, plant a write-through/read-through trapdoor into the
# LIVE wiki (a later unjailed write escapes; creds get read into a page). Refuse the accept if any
# staged symlink escapes the staging tree. In-tree relative aliases (e.g. security/latest.md ->
# 2026-06-06.md) are legitimate and preserved.
OOT_LINKS=$(find "$STAGING_WIKI" -type l 2>/dev/null | while read -r _l; do
  _t=$(readlink -f "$_l" 2>/dev/null)
  case "$_t" in "$STAGING_WIKI"/*) : ;; *) printf '%s\n' "$_l" ;; esac
done)
if [ -n "$OOT_LINKS" ]; then
  echo "error: staging contains symlink(s) pointing outside the wiki — refusing accept (escape risk):" >&2
  printf '  %s\n' $OOT_LINKS >&2
  exit 1
fi

# Apply: rsync staging over live wiki (preserves files not in staging). --safe-links drops any
# out-of-tree symlink as defense-in-depth behind the reject guard; the cp fallback is already
# covered by that guard (no out-of-tree symlink can reach it).
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --safe-links "$STAGING_WIKI/" "$LIVE_WIKI/"
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
