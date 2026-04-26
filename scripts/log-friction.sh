#!/bin/bash
# Detect friction signals from user prompts and log them.
# Triggered by UserPromptSubmit hook (no matcher — matchers are silently ignored
# for UserPromptSubmit per Claude Code spec, so we gate the write here).
# Reads hook input from stdin (JSON with session_id, user prompt, etc.)

BRAIN_DIR="$HOME/.second-brain"
FRICTION_LOG="$BRAIN_DIR/friction-log.jsonl"
MAX_LINES=5000  # Rotate when log exceeds this; keep most recent half

mkdir -p "$BRAIN_DIR"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // .prompt // ""' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Gate: only log prompts that look like friction. This is the actual matcher
# (the hooks.json matcher is silently ignored for UserPromptSubmit).
if [ -z "$PROMPT" ]; then
  exit 0
fi

FRICTION_TYPE=""
if echo "$PROMPT" | grep -Eqi 'again|retry|redo|repeat'; then
  FRICTION_TYPE="retry"
elif echo "$PROMPT" | grep -Eqi 'no[, ]|wrong|not what|i said|that.s not|incorrect'; then
  FRICTION_TYPE="rejection"
elif echo "$PROMPT" | grep -Eqi 'fix|bug|broken|error|issue'; then
  FRICTION_TYPE="fix_request"
fi

# No friction match → don't log (privacy: avoids storing every user prompt)
if [ -z "$FRICTION_TYPE" ]; then
  exit 0
fi

# Build the log line via jq so embedded quotes/newlines/control chars stay valid JSON
jq -nc \
  --arg t "$TIMESTAMP" \
  --arg s "$SESSION_ID" \
  --arg ty "$FRICTION_TYPE" \
  --arg p "$PROMPT" \
  '{timestamp:$t, session_id:$s, type:$ty, prompt:$p}' >> "$FRICTION_LOG"

# Rotate if log grew too large — keep the most recent half
if [ -f "$FRICTION_LOG" ]; then
  LINES=$(wc -l < "$FRICTION_LOG" 2>/dev/null | tr -d ' ')
  LINES=${LINES:-0}
  if [ "$LINES" -gt "$MAX_LINES" ]; then
    KEEP=$((MAX_LINES / 2))
    tail -n "$KEEP" "$FRICTION_LOG" > "$FRICTION_LOG.tmp" && mv "$FRICTION_LOG.tmp" "$FRICTION_LOG"
  fi
fi

exit 0
