#!/bin/bash
# Detect friction signals from user prompts and log them.
# Triggered by UserPromptSubmit hook when matcher detects correction patterns.
# Reads hook input from stdin (JSON with session_id, user prompt, etc.)

COMPANION_DIR="$HOME/.claude-companion"
FRICTION_LOG="$COMPANION_DIR/friction-log.jsonl"

mkdir -p "$COMPANION_DIR"

# Read hook input from stdin
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // ""' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$PROMPT" ]; then
  # Determine friction type based on content
  FRICTION_TYPE="correction"
  if echo "$PROMPT" | grep -qi "again\|retry\|redo\|repeat"; then
    FRICTION_TYPE="retry"
  elif echo "$PROMPT" | grep -qi "no[, ]\|wrong\|not what\|I said"; then
    FRICTION_TYPE="rejection"
  elif echo "$PROMPT" | grep -qi "fix\|bug\|broken\|error"; then
    FRICTION_TYPE="fix_request"
  fi

  # Append to friction log (JSONL format)
  echo "{\"timestamp\":\"$TIMESTAMP\",\"session_id\":\"$SESSION_ID\",\"type\":\"$FRICTION_TYPE\",\"prompt\":$(echo "$PROMPT" | jq -Rs .)}" >> "$FRICTION_LOG"
fi

exit 0
