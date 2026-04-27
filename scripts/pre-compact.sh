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
  jq -n \
    --arg s "$SESSION_ID" \
    --arg d "$TIMESTAMP" \
    --argjson ut "$USER_TURNS" \
    --argjson fc "$FRICTION_COUNT" \
    --arg tr "pre-compact" \
    --arg tp "$TRANSCRIPT_PATH" \
    '{session_id:$s, date:$d, user_turns:$ut, friction_count:$fc, trigger:$tr, transcript_path:$tp}' \
    > "$BRAIN_DIR/.pending-reflection.json"
  REFLECTION_SAVED=true
fi

cat << 'EOF'
CONTEXT COMPACTION IMMINENT — You are about to lose detailed context. Before compaction, save substantive knowledge to disk NOW (you still have full context — after compaction you won't).

Write to ~/knowledge/wiki/ any knowledge from this session that would be lost in a summary:
- Architecture decisions and rationale → wiki/sessions/YYYY-MM-DD-topic.md
- New or updated entities (projects, tools, components) → wiki/entities/name.md
- Design patterns, migration plans, technical debt → appropriate wiki category
- Update ~/knowledge/index.md if you create new pages

Keep writes focused — only knowledge that isn't already in the wiki or derivable from code. Skip if the session was trivial (simple fixes, Q&A). This is your last chance before context degrades.
EOF
