#!/bin/bash
# Runs before context compaction — preserve session insights.
# Creates a pending reflection so PostCompact/SessionStart can process it.

source "$(dirname "$0")/lib.sh"

mkdir -p "$BRAIN_DIR"
sb_parse_input
sb_resolve_transcript  # don't exit on failure — still emit instructions
sb_count_user_turns

SB_FRICTION_COUNT=0
if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
  SB_FRICTION_COUNT=$(jq -s --arg s "$SB_SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  SB_FRICTION_COUNT=${SB_FRICTION_COUNT:-0}
fi

if [ "$SB_USER_TURNS" -ge 3 ]; then
  jq -n \
    --arg s "$SB_SESSION_ID" \
    --arg d "$SB_TIMESTAMP" \
    --argjson ut "$SB_USER_TURNS" \
    --argjson fc "$SB_FRICTION_COUNT" \
    --arg tr "pre-compact" \
    --arg tp "$SB_TRANSCRIPT_PATH" \
    '{session_id:$s, date:$d, user_turns:$ut, friction_count:$fc, trigger:$tr, transcript_path:$tp}' \
    > "$BRAIN_DIR/.pending-reflection.json"
fi

cat << 'EOF'
CONTEXT COMPACTION IMMINENT — Save key knowledge to ~/knowledge/wiki/ NOW while you have full context. Keep entries concise — the wiki is an index, not a dump.

- Session page (wiki/sessions/YYYY-MM-DD-topic.md): 10-20 lines. Topic, key decisions, entities touched, outcome.
- Update entity/concept pages with new knowledge (don't create new pages for things that belong on existing ones).
- Update ~/knowledge/index.md and ~/knowledge/log.md for new pages.

Skip if the session was trivial. Don't duplicate what's in code or git history.
EOF
