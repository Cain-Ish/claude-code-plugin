#!/bin/bash
# Quality gate instruction injected after every Write/Edit via stdout.
# Kept as a script (not inline echo) so the instruction text can evolve.

BRAIN_DIR="$HOME/.second-brain"
COMPACT_COUNT=$(cat "$BRAIN_DIR/.compact-count" 2>/dev/null || echo 0)
[ "$COMPACT_COUNT" -ge 3 ] && exit 0

echo "QUALITY GATE - Silently self-review what you just wrote against the quality rules and persona loaded at session start. Check: gaps, correctness, security, completeness, consistency, human-style code. Fix issues immediately. Do not narrate."
