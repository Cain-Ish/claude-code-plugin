#!/bin/bash
# Runs after context compaction.
# Writes a compact timestamp marker so session-load.sh can detect compact
# re-init and emit minimal output (prevents compaction loop).
# Increments compact counter for context pressure detection.

BRAIN_DIR="$HOME/.second-brain"
mkdir -p "$BRAIN_DIR"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BRAIN_DIR/.last-compact-ts" 2>/dev/null

COUNT_FILE="$BRAIN_DIR/.compact-count"
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE"

if [ "$COUNT" -lt 3 ]; then
  echo "Context compacted. Session reload follows."
fi
