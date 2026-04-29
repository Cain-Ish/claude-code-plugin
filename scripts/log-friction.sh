#!/bin/bash
# Detect friction signals from user prompts and log them.
# Triggered by UserPromptSubmit hook (no matcher — matchers are silently ignored
# for UserPromptSubmit per Claude Code spec, so we gate the write here).
# Reads hook input from stdin (JSON with session_id, user prompt, etc.)

source "$(dirname "$0")/lib.sh"
SB_SCRIPT_NAME="log-friction.sh"

FRICTION_LOG="$BRAIN_DIR/friction-log.jsonl"
MAX_LINES=5000

mkdir -p "$BRAIN_DIR"
sb_require_jq || exit 0

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
# course-correcting, not praising). Word boundaries (\b) prevent substring
# false positives like "fix" in "prefix" or "issue" in "tissue".
if echo "$PROMPT" | grep -Eqi '\b(again|retry|redo|repeat)\b'; then
  SIGNAL_TYPE="retry"; DIRECTION="negative"
elif echo "$PROMPT" | grep -Eqi '\b(no[, ]|wrong|not what|i said|that.s not|incorrect)\b'; then
  SIGNAL_TYPE="rejection"; DIRECTION="negative"
elif echo "$PROMPT" | grep -Eqi '\b(fix|bug|broken|error|issue)\b'; then
  SIGNAL_TYPE="fix_request"; DIRECTION="negative"

# Positive signals — only matched when no negative pattern fired.
# Start-anchored to avoid false positives from mid-sentence praise,
# but allows trailing text (e.g. "thanks, now let's move on").
elif echo "$PROMPT" | grep -Eqi '^[[:space:]]*(perfect|exactly|thanks|thank you|nice|great work|works perfectly|love it|brilliant)\b'; then
  SIGNAL_TYPE="praise"; DIRECTION="positive"
elif echo "$PROMPT" | grep -Eqi '^[[:space:]]*(ok|okay|yes|yep|good|sounds good|sgtm|lgtm)[[:space:]!.,]*$'; then
  SIGNAL_TYPE="acceptance"; DIRECTION="positive"
fi

# No signal match → don't log (privacy: avoids storing every user prompt)
if [ -z "$SIGNAL_TYPE" ]; then
  exit 0
fi

# Rate-limit: skip if same signal_type already logged for this session within 60s.
if [ -f "$FRICTION_LOG" ] && [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
  LAST_SAME=$(tail -20 "$FRICTION_LOG" | jq -r --arg s "$SESSION_ID" --arg ty "$SIGNAL_TYPE" \
    'select(.session_id == $s and .type == $ty) | .timestamp' 2>/dev/null | tail -1)
  if [ -n "$LAST_SAME" ]; then
    LAST_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_SAME" +%s 2>/dev/null \
              || date -u -d "$LAST_SAME" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date -u +%s)
    if [ "$((NOW_EPOCH - LAST_EPOCH))" -lt 60 ]; then
      exit 0
    fi
  fi
fi

# Truncate prompt to 200 chars — enough context for learning analysis without
# storing sensitive content from long correction messages.
PROMPT_TRUNC=$(printf '%.200s' "$PROMPT")

jq -nc \
  --arg t "$TIMESTAMP" \
  --arg s "$SESSION_ID" \
  --arg ty "$SIGNAL_TYPE" \
  --arg d "$DIRECTION" \
  --arg p "$PROMPT_TRUNC" \
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
