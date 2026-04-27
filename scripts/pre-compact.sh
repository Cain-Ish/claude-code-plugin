#!/bin/bash
# Runs before context compaction — preserve session insights.
# Creates a pending reflection so PostCompact/SessionStart can process it.

source "$(dirname "$0")/lib.sh"

mkdir -p "$BRAIN_DIR"
sb_parse_input
sb_resolve_transcript
sb_count_user_turns
sb_count_friction
sb_count_drift
sb_calc_priority
sb_check_auto_improve

if [ "$SB_USER_TURNS" -ge 3 ]; then
  sb_write_reflection "pre-compact"
fi

echo "CONTEXT COMPACTION IMMINENT — save key knowledge to ~/knowledge/wiki/ if this session had important decisions. Keep entries to 10-20 lines. Skip if trivial."
