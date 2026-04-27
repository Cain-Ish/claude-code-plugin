#!/bin/bash
# Create a pending reflection when the user clears the session (/clear).
# Runs on SessionStart with "clear" matcher, BEFORE the main hook chain.
# The actual reflection (LLM analysis) happens in the same SessionStart
# via session-load.sh, which picks up .pending-reflection.json.

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

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

USER_TURNS=$(jq -r 'select(.type=="user" and (.message.content | type == "string")) | .type' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
USER_TURNS=${USER_TURNS:-0}
if [ "$USER_TURNS" -lt 3 ]; then
  exit 0
fi

FRICTION_COUNT=0
POSITIVE_COUNT=0
if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
  FRICTION_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s and (.direction // "negative") == "negative")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  POSITIVE_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s and .direction == "positive")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
  FRICTION_COUNT=${FRICTION_COUNT:-0}
  POSITIVE_COUNT=${POSITIVE_COUNT:-0}
fi

FIRST_TRY_SUCCESS="false"
if [ "$FRICTION_COUNT" -eq 0 ] && [ "$USER_TURNS" -ge 3 ]; then
  FIRST_TRY_SUCCESS="true"
fi

DRIFT_COUNT=0
if [ -f "$BRAIN_DIR/drift-log.jsonl" ]; then
  DRIFT_COUNT=$(jq -s --arg s "$SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/drift-log.jsonl" 2>/dev/null)
  DRIFT_COUNT=${DRIFT_COUNT:-0}
fi

FRICTION_TRIGGER="${SECOND_BRAIN_FRICTION_TRIGGER:-5}"
DRIFT_TRIGGER="${SECOND_BRAIN_DRIFT_TRIGGER:-3}"
PRIORITY="normal"
if [ "$FRICTION_COUNT" -ge "$FRICTION_TRIGGER" ] || [ "$DRIFT_COUNT" -ge "$DRIFT_TRIGGER" ]; then
  PRIORITY="high"
fi

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
      LEARNINGS_SINCE=$(awk -v cutoff="$LAST_IMPROVE_DATE" '
        /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
          d = substr($0, 5, 10)
          if (d > cutoff) c++
        }
        END { print c+0 }
      ' "$BRAIN_DIR/learnings.md" 2>/dev/null)
    else
      LEARNINGS_SINCE=$(grep -c "^## \[" "$BRAIN_DIR/learnings.md" 2>/dev/null)
    fi
    LEARNINGS_SINCE=${LEARNINGS_SINCE:-0}
  fi

  if [ "$FRICTION_COUNT" -ge 2 ] || [ "$LEARNINGS_SINCE" -ge 3 ]; then
    SUGGEST_PLUGIN_IMPROVE="true"
  fi
fi

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
  --arg tr "clear" \
  --arg tp "$TRANSCRIPT_PATH" \
  '{session_id:$s, date:$d, user_turns:$ut, friction_count:$fc, positive_signals:$ps, first_try_success:$fts, drift_count:$dc, priority:$pr, suggest_plugin_improve:$spi, trigger:$tr, transcript_path:$tp}' \
  > "$BRAIN_DIR/.pending-reflection.json"

jq -n \
  --arg s "$SESSION_ID" \
  --arg d "$TIMESTAMP" \
  --argjson ut "$USER_TURNS" \
  --argjson fs "$FRICTION_COUNT" \
  --argjson ps "$POSITIVE_COUNT" \
  --argjson fts "$FIRST_TRY_SUCCESS" \
  '{session_id:$s, date:$d, user_turns:$ut, friction_signals:$fs, positive_signals:$ps, first_try_success:$fts}' \
  > "$BRAIN_DIR/.last-session-meta.json"

exit 0
