#!/bin/bash
# v1.0 hot-tier loader. Outputs USER.md + active PROJECT.md + active index line.
# Captures SessionStart baseline for Stop-hook predicate.
source "$(dirname "$0")/lib.sh"

USER_FILE="$BRAIN_DIR/USER.md"
INDEX_FILE="$BRAIN_DIR/index.txt"
PROJECTS_DIR="$BRAIN_DIR/projects"
LINE_CAP=66   # ~800 tokens / 12 tokens-per-line

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
project_file="$PROJECTS_DIR/$slug/PROJECT.md"

[ -f "$project_file" ] && cp "$project_file" "$BRAIN_DIR/.session-baseline-$slug.md"

[ -f "$USER_FILE" ] && cat "$USER_FILE"
if [ -f "$project_file" ]; then echo; cat "$project_file"; fi
if [ -f "$INDEX_FILE" ]; then
  echo
  jq --arg s "$slug" -r 'select(.slug == $s)' "$INDEX_FILE" 2>/dev/null | head -1
fi

# Approximate hot-tier size: USER.md + PROJECT.md. The single index.txt line
# emitted above is intentionally not counted (it's ~1 line and conditional on
# a slug match — keeping the math simple).
TOTAL_LINES=$(( $(wc -l < "$USER_FILE" 2>/dev/null || echo 0) + $(wc -l < "$project_file" 2>/dev/null || echo 0) ))
if [ "$TOTAL_LINES" -gt "$LINE_CAP" ]; then
  sb_log_error "session-load.sh" "hot-tier exceeded line cap: $TOTAL_LINES > $LINE_CAP" 0
fi

exit 0
