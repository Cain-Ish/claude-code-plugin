#!/bin/bash
# Runs before context compaction — preserve session insights.
# Creates a pending reflection so PostCompact/SessionStart can process it.

source "$(dirname "$0")/lib.sh"
SB_SCRIPT_NAME="pre-compact.sh"

mkdir -p "$BRAIN_DIR"
sb_require_jq || exit 0
sb_parse_input
sb_resolve_transcript
sb_count_user_turns
sb_count_friction
sb_count_drift
sb_calc_priority
sb_check_auto_improve

if [ "$SB_USER_TURNS" -ge 3 ] && { [ "$SB_FRICTION_COUNT" -gt 0 ] || [ "$SB_POSITIVE_COUNT" -gt 0 ] || [ "$SB_PRIORITY" = "high" ]; }; then
  sb_write_reflection "pre-compact"
fi

# Suppress echo under context pressure — reflection is saved to disk regardless
if ! sb_context_pressure; then
  echo "CONTEXT COMPACTION IMMINENT — save key knowledge to ~/knowledge/wiki/ if this session had important decisions. Keep entries to 10-20 lines. Skip if trivial."
fi
