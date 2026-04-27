#!/bin/bash
# Runs after context compaction.
# Writes a compact timestamp marker so session-load.sh can detect compact
# re-init and emit minimal output (prevents compaction loop).

BRAIN_DIR="$HOME/.second-brain"
mkdir -p "$BRAIN_DIR"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BRAIN_DIR/.last-compact-ts" 2>/dev/null

echo "Context compacted. Session reload follows."
