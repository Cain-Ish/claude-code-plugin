#!/bin/bash
# Detect friction signals from user prompts and log them.
# Triggered by UserPromptSubmit hook (no matcher — matchers are silently ignored
# for UserPromptSubmit per Claude Code spec, so we gate the write here).
# Reads hook input from stdin (JSON with session_id, user prompt, etc.)

source "$(dirname "$0")/lib.sh"

FRICTION_LOG="$BRAIN_DIR/friction-log.jsonl"
MAX_LINES=5000

mkdir -p "$BRAIN_DIR"

sb_parse_input
SESSION_ID="$SB_SESSION_ID"
PROMPT=$(echo "$SB_INPUT" | jq -r '.user_prompt // .prompt // ""' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Gate: only log prompts that look like friction. This is the actual matcher
# (the hooks.json matcher is silently ignored for UserPromptSubmit).
if [ -z "$PROMPT" ]; then
  exit 0
fi

SIGNAL_TYPE=""
DIRECTION=""

# Negative signals (friction) — checked first so a mixed prompt like
# "no wait actually that's perfect" classifies as friction (the user is
# course-correcting, not praising).
if echo "$PROMPT" | grep -Eqi 'again|retry|redo|repeat'; then
  SIGNAL_TYPE="retry"; DIRECTION="negative"
elif echo "$PROMPT" | grep -Eqi 'no[, ]|wrong|not what|i said|that.s not|incorrect'; then
  SIGNAL_TYPE="rejection"; DIRECTION="negative"
elif echo "$PROMPT" | grep -Eqi 'fix|bug|broken|error|issue'; then
  SIGNAL_TYPE="fix_request"; DIRECTION="negative"

# Positive signals — only matched when no negative pattern fired. High-precision
# only: short standalone praise/acceptance, not generic "ok let me check".
elif echo "$PROMPT" | grep -Eqi '^[[:space:]]*(perfect|exactly|thanks|thank you|nice|great work|works|works perfectly|love it|brilliant)[[:space:]!.,]*$'; then
  SIGNAL_TYPE="praise"; DIRECTION="positive"
elif echo "$PROMPT" | grep -Eqi '^[[:space:]]*(ok|okay|yes|yep|good|sounds good|sgtm|lgtm)[[:space:]!.,]*$'; then
  SIGNAL_TYPE="acceptance"; DIRECTION="positive"
fi

# No signal match → don't log (privacy: avoids storing every user prompt)
if [ -z "$SIGNAL_TYPE" ]; then
  exit 0
fi

# Build the log line via jq so embedded quotes/newlines/control chars stay valid JSON.
# `type` is preserved for backward compat; `direction` is the new field that
# extract-learnings.sh and improve.SKILL.md use to count friction vs. positive.
jq -nc \
  --arg t "$TIMESTAMP" \
  --arg s "$SESSION_ID" \
  --arg ty "$SIGNAL_TYPE" \
  --arg d "$DIRECTION" \
  --arg p "$PROMPT" \
  '{timestamp:$t, session_id:$s, type:$ty, direction:$d, prompt:$p}' >> "$FRICTION_LOG"

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
