#!/bin/bash
# Extract learnings from the current session transcript.
# Runs async at session Stop — doesn't block the user.
# Reads hook input from stdin for transcript_path and session metadata.

COMPANION_DIR="$HOME/.claude-companion"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$COMPANION_DIR"

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

# Count turns to skip trivial sessions (< 3 user messages)
USER_TURNS=$(grep -c '"role":"user"' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$USER_TURNS" -lt 3 ]; then
  exit 0
fi

# Check friction log for this session
FRICTION_COUNT=0
if [ -f "$COMPANION_DIR/friction-log.jsonl" ]; then
  FRICTION_COUNT=$(grep -c "$SESSION_ID" "$COMPANION_DIR/friction-log.jsonl" 2>/dev/null || echo "0")
fi

# Write session metadata for the agent hook to consume
cat > "$COMPANION_DIR/.last-session-meta.json" << JSONEOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT_PATH",
  "date": "$TIMESTAMP",
  "user_turns": $USER_TURNS,
  "friction_signals": $FRICTION_COUNT,
  "knowledge_dir": "$KNOWLEDGE_DIR",
  "learnings_path": "$COMPANION_DIR/learnings.md",
  "quality_rules_path": "$COMPANION_DIR/quality-rules.md",
  "friction_log_path": "$COMPANION_DIR/friction-log.jsonl"
}
JSONEOF

exit 0
