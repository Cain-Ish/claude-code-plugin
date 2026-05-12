#!/bin/bash
# Generate a human-readable diff between staging wiki and live wiki.
# Also computes summary stats and writes them to status.json outputs.
#
# Usage: dream-diff.sh <dream_id>
# Outputs: diff summary on stdout, writes diff.md to dream directory
set -u
source "$(dirname "$0")/lib.sh"

DREAM_ID="${1:?usage: dream-diff.sh <dream_id>}"
DREAM_DIR="$BRAIN_DIR/dreams/$DREAM_ID"

if [ ! -d "$DREAM_DIR" ]; then
  echo "error: dream directory not found: $DREAM_DIR" >&2
  exit 1
fi

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
LIVE_WIKI="$KNOWLEDGE_DIR/wiki"
STAGING_WIKI="$DREAM_DIR/staging/wiki"

if [ ! -d "$STAGING_WIKI" ]; then
  echo "error: staging wiki not found: $STAGING_WIKI" >&2
  exit 1
fi

DIFF_FILE="$DREAM_DIR/diff.md"

# Compute changes
ADDED=0
MODIFIED=0
REMOVED=0

{
  echo "# Dream Diff: $DREAM_ID"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  # New files (in staging but not in live)
  echo "## New Pages"
  echo ""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$STAGING_WIKI/}"
    if [ ! -f "$LIVE_WIKI/$rel" ]; then
      ADDED=$((ADDED + 1))
      title=$(head -20 "$f" | grep -E '^title:' | head -1 | sed 's/^title: *["]*//;s/["]*$//')
      echo "- **\`$rel\`** — $title"
    fi
  done < <(find "$STAGING_WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort)

  [ "$ADDED" -eq 0 ] && echo "(none)"
  echo ""

  # Modified files
  echo "## Modified Pages"
  echo ""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$STAGING_WIKI/}"
    if [ -f "$LIVE_WIKI/$rel" ]; then
      if ! diff -q "$LIVE_WIKI/$rel" "$f" >/dev/null 2>&1; then
        MODIFIED=$((MODIFIED + 1))
        echo "### \`$rel\`"
        echo '```diff'
        diff -u "$LIVE_WIKI/$rel" "$f" 2>/dev/null | head -60 || true
        echo '```'
        echo ""
      fi
    fi
  done < <(find "$STAGING_WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort)

  [ "$MODIFIED" -eq 0 ] && echo "(none)" && echo ""

  # Removed files (in live but not in staging)
  echo "## Removed Pages"
  echo ""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$LIVE_WIKI/}"
    if [ ! -f "$STAGING_WIKI/$rel" ]; then
      REMOVED=$((REMOVED + 1))
      echo "- ~~\`$rel\`~~"
    fi
  done < <(find "$LIVE_WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort)

  [ "$REMOVED" -eq 0 ] && echo "(none)"
  echo ""

  echo "## Summary"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|-------|"
  echo "| Pages added | $ADDED |"
  echo "| Pages modified | $MODIFIED |"
  echo "| Pages removed | $REMOVED |"
  echo "| **Total changes** | **$((ADDED + MODIFIED + REMOVED))** |"

} > "$DIFF_FILE"

# Update status.json outputs
if [ -f "$DREAM_DIR/status.json" ]; then
  tmp=$(mktemp)
  jq --argjson a "$ADDED" --argjson m "$MODIFIED" --argjson r "$REMOVED" \
    '.outputs.pages_added = $a | .outputs.pages_modified = $m | .outputs.pages_removed = $r' \
    "$DREAM_DIR/status.json" > "$tmp" && mv "$tmp" "$DREAM_DIR/status.json"
fi

echo "Dream diff: +$ADDED ~$MODIFIED -$REMOVED pages"
