#!/bin/bash
# Runs before context compaction — preserve session insights.
# Creates a pending reflection so PostCompact/SessionStart can process it.

BRAIN_DIR="$HOME/.second-brain"
mkdir -p "$BRAIN_DIR"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
TIMESTAMP=$(date +"%Y-%m-%d")

if [ -z "$TRANSCRIPT_PATH" ] || [ "$TRANSCRIPT_PATH" = "" ]; then
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    POSSIBLE_PATH="$HOME/.claude/sessions/$SESSION_ID.jsonl"
    [ -f "$POSSIBLE_PATH" ] && TRANSCRIPT_PATH="$POSSIBLE_PATH"
  fi
fi

USER_TURNS=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Claude Code transcripts use top-level .type with role nested under .message.role.
  # Tool-result messages also have .type=="user" but .message.content is an array
  # (vs a string for real prompts) — filter to strings to count actual prompts.
  USER_TURNS=$(jq -r 'select(.type=="user" and (.message.content | type == "string")) | .type' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
  USER_TURNS=${USER_TURNS:-0}
fi

FRICTION_COUNT=0
if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
  FRICTION_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  FRICTION_COUNT=${FRICTION_COUNT:-0}
fi

REFLECTION_SAVED=false
if [ "$USER_TURNS" -ge 3 ]; then
  cat > "$BRAIN_DIR/.pending-reflection.json" << JSONEOF
{
  "session_id": "$SESSION_ID",
  "date": "$TIMESTAMP",
  "user_turns": $USER_TURNS,
  "friction_count": $FRICTION_COUNT,
  "trigger": "pre-compact"
}
JSONEOF
  REFLECTION_SAVED=true
fi

if [ "$REFLECTION_SAVED" = "true" ]; then
  cat << 'EOF'
CONTEXT COMPACTION IMMINENT - Before this context is compressed, note any key session insights (learnings, decisions, patterns) that should survive compaction. A pending reflection has been saved for post-compaction processing.
EOF
else
  cat << 'EOF'
CONTEXT COMPACTION IMMINENT - Before this context is compressed, note any key session insights (learnings, decisions, patterns) that should survive compaction.
EOF
fi
