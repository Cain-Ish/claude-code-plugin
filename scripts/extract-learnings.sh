#!/bin/bash
# Extract session data and create a pending reflection request.
# Runs at session Stop — doesn't block the user.
# The actual reflection (LLM analysis) happens at next SessionStart.

BRAIN_DIR="$HOME/.second-brain"
KNOWLEDGE_DIR="$1"
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="$HOME/knowledge" ;;
esac
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$BRAIN_DIR"

# Read hook input from stdin
INPUT=$(cat)

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
TIMESTAMP=$(date +"%Y-%m-%d")

# If no transcript path, try to find it from session ID
if [ -z "$TRANSCRIPT_PATH" ] || [ "$TRANSCRIPT_PATH" = "" ]; then
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    POSSIBLE_PATH="$HOME/.claude/sessions/$SESSION_ID.jsonl"
    if [ -f "$POSSIBLE_PATH" ]; then
      TRANSCRIPT_PATH="$POSSIBLE_PATH"
    fi
  fi
fi

# If we still don't have a transcript, exit gracefully
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Count turns via jq — avoids false positives from assistant messages quoting "role":"user"
USER_TURNS=$(jq -r 'select(.role=="user") | .role' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
USER_TURNS=${USER_TURNS:-0}
if [ "$USER_TURNS" -lt 3 ]; then
  exit 0
fi

# Friction count for this session — match the structured field, not substring
FRICTION_COUNT=0
if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
  FRICTION_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  FRICTION_COUNT=${FRICTION_COUNT:-0}
fi

# Write session metadata
cat > "$BRAIN_DIR/.last-session-meta.json" << JSONEOF
{
  "session_id": "$SESSION_ID",
  "date": "$TIMESTAMP",
  "user_turns": $USER_TURNS,
  "friction_signals": $FRICTION_COUNT
}
JSONEOF

# Check if auto-improve is enabled in config
AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$BRAIN_DIR/config.json" 2>/dev/null)
SUGGEST_PLUGIN_IMPROVE="false"

if [ "$AUTO_IMPROVE" = "true" ]; then
  LAST_IMPROVE_DATE=""
  if [ -f "$BRAIN_DIR/.last-plugin-improve" ]; then
    LAST_IMPROVE_DATE=$(cat "$BRAIN_DIR/.last-plugin-improve" 2>/dev/null)
  fi

  LEARNINGS_SINCE=0
  if [ -f "$BRAIN_DIR/learnings.md" ]; then
    if [ -n "$LAST_IMPROVE_DATE" ]; then
      # Count headers strictly newer than LAST_IMPROVE_DATE (lexicographic works for YYYY-MM-DD)
      LEARNINGS_SINCE=$(awk -v cutoff="$LAST_IMPROVE_DATE" '
        match($0, /^## \[([0-9]{4}-[0-9]{2}-[0-9]{2})\]/, m) {
          if (m[1] > cutoff) c++
        }
        END { print c+0 }
      ' "$BRAIN_DIR/learnings.md" 2>/dev/null)
    else
      # Never improved before — count all
      LEARNINGS_SINCE=$(grep -c "^## \[" "$BRAIN_DIR/learnings.md" 2>/dev/null)
    fi
    LEARNINGS_SINCE=${LEARNINGS_SINCE:-0}
  fi

  if [ "$FRICTION_COUNT" -ge 2 ] || [ "$LEARNINGS_SINCE" -ge 3 ] || [ -z "$LAST_IMPROVE_DATE" ]; then
    SUGGEST_PLUGIN_IMPROVE="true"
  fi
fi

# Create pending reflection for next SessionStart to process
cat > "$BRAIN_DIR/.pending-reflection.json" << JSONEOF
{
  "session_id": "$SESSION_ID",
  "date": "$TIMESTAMP",
  "user_turns": $USER_TURNS,
  "friction_count": $FRICTION_COUNT,
  "suggest_plugin_improve": $SUGGEST_PLUGIN_IMPROVE
}
JSONEOF

exit 0
