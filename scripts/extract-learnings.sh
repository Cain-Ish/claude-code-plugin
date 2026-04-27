#!/bin/bash
# Extract session data and create a pending reflection request.
# Runs at session Stop — doesn't block the user.
# The actual reflection (LLM analysis) happens at next SessionStart.

BRAIN_DIR="$HOME/.second-brain"
# Resolve knowledge dir: $1 → CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR → ~/knowledge
# Each step rejects an unsubstituted "${user_config.…}" literal.
KNOWLEDGE_DIR="$1"
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-}" ;;
esac
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

# Count actual user prompts. Claude Code transcripts use top-level .type with the role
# nested under .message.role; tool-result messages also have .type=="user" but their
# .message.content is an array (vs a string for real prompts). Filter to strings.
USER_TURNS=$(jq -r 'select(.type=="user" and (.message.content | type == "string")) | .type' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
USER_TURNS=${USER_TURNS:-0}
if [ "$USER_TURNS" -lt 3 ]; then
  exit 0
fi

# Friction and positive counts for this session. log-friction.sh tags each
# entry with direction: "negative" | "positive" — count them separately so
# we can compute first-try success (no friction in a real-length session).
FRICTION_COUNT=0
POSITIVE_COUNT=0
if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
  FRICTION_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s and (.direction // "negative") == "negative")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  POSITIVE_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s and .direction == "positive")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  FRICTION_COUNT=${FRICTION_COUNT:-0}
  POSITIVE_COUNT=${POSITIVE_COUNT:-0}
fi

# First-try success: substantive session with zero friction. The threshold
# (USER_TURNS >= 3) matches the existing reflection trigger upstream.
FIRST_TRY_SUCCESS="false"
if [ "$FRICTION_COUNT" -eq 0 ] && [ "$USER_TURNS" -ge 3 ]; then
  FIRST_TRY_SUCCESS="true"
fi

# Write session metadata via jq so embedded quotes/newlines/backslashes in
# session_id or timestamp can't break the JSON. Booleans go via --argjson.
jq -n \
  --arg s "$SESSION_ID" \
  --arg d "$TIMESTAMP" \
  --argjson ut "$USER_TURNS" \
  --argjson fs "$FRICTION_COUNT" \
  --argjson ps "$POSITIVE_COUNT" \
  --argjson fts "$FIRST_TRY_SUCCESS" \
  '{session_id:$s, date:$d, user_turns:$ut, friction_signals:$fs, positive_signals:$ps, first_try_success:$fts}' \
  > "$BRAIN_DIR/.last-session-meta.json"

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
      # POSIX awk: no 3-arg match(); use RSTART/RLENGTH + substr() instead.
      # Header format is "## [YYYY-MM-DD] ..." so we match the date inside [] and
      # slice it out of the matched substring.
      LEARNINGS_SINCE=$(awk -v cutoff="$LAST_IMPROVE_DATE" '
        /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
          d = substr($0, 5, 10)
          if (d > cutoff) c++
        }
        END { print c+0 }
      ' "$BRAIN_DIR/learnings.md" 2>/dev/null)
    else
      # Never improved before — count all
      LEARNINGS_SINCE=$(grep -c "^## \[" "$BRAIN_DIR/learnings.md" 2>/dev/null)
    fi
    LEARNINGS_SINCE=${LEARNINGS_SINCE:-0}
  fi

  # Suggest a plugin improvement only when there's a real signal: enough
  # friction in this session, or enough new learnings since the last
  # improve. First-time users with no signal don't auto-trigger anymore.
  if [ "$FRICTION_COUNT" -ge 2 ] || [ "$LEARNINGS_SINCE" -ge 3 ]; then
    SUGGEST_PLUGIN_IMPROVE="true"
  fi
fi

# Importance-triggered priority. Mark "high" when this session shows
# significantly more friction or persona drift than baseline — SessionStart's
# reflection block uses this to surface processing earlier (before normal
# context loading), so urgent learning happens at the next session start
# rather than queued behind everything else.
DRIFT_COUNT=0
if [ -f "$BRAIN_DIR/drift-log.jsonl" ]; then
  DRIFT_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/drift-log.jsonl" 2>/dev/null)
  DRIFT_COUNT=${DRIFT_COUNT:-0}
fi

# Importance-trigger thresholds. Magic numbers exposed as env vars so users
# can tune sensitivity without forking the script.
FRICTION_TRIGGER="${SECOND_BRAIN_FRICTION_TRIGGER:-5}"
DRIFT_TRIGGER="${SECOND_BRAIN_DRIFT_TRIGGER:-3}"
PRIORITY="normal"
if [ "$FRICTION_COUNT" -ge "$FRICTION_TRIGGER" ] || [ "$DRIFT_COUNT" -ge "$DRIFT_TRIGGER" ]; then
  PRIORITY="high"
fi

# Create pending reflection for next SessionStart to process. Same jq-based
# encoding as above so tampered hook input can't malform the JSON file that
# session-load.sh subsequently parses.
jq -n \
  --arg s "$SESSION_ID" \
  --arg d "$TIMESTAMP" \
  --argjson ut "$USER_TURNS" \
  --argjson fc "$FRICTION_COUNT" \
  --argjson ps "$POSITIVE_COUNT" \
  --argjson fts "$FIRST_TRY_SUCCESS" \
  --argjson dc "$DRIFT_COUNT" \
  --arg pr "$PRIORITY" \
  --argjson spi "$SUGGEST_PLUGIN_IMPROVE" \
  --arg tr "stop" \
  --arg tp "$TRANSCRIPT_PATH" \
  '{session_id:$s, date:$d, user_turns:$ut, friction_count:$fc, positive_signals:$ps, first_try_success:$fts, drift_count:$dc, priority:$pr, suggest_plugin_improve:$spi, trigger:$tr, transcript_path:$tp}' \
  > "$BRAIN_DIR/.pending-reflection.json"

exit 0
