#!/bin/bash
# Shared functions for second-brain hook scripts.
# Source this at the top of any hook script: source "$(dirname "$0")/lib.sh"

BRAIN_DIR="$HOME/.second-brain"

# Parse hook input from stdin. Sets: SB_INPUT, SB_SESSION_ID, SB_TRANSCRIPT_PATH, SB_TIMESTAMP
sb_parse_input() {
  SB_INPUT=$(cat)
  SB_SESSION_ID=$(echo "$SB_INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
  SB_TRANSCRIPT_PATH=$(echo "$SB_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
  SB_TIMESTAMP=$(date +"%Y-%m-%d")
}

# Resolve transcript path from session ID fallback. Updates SB_TRANSCRIPT_PATH.
# Returns 1 if no usable transcript found.
sb_resolve_transcript() {
  if [ -z "$SB_TRANSCRIPT_PATH" ] || [ "$SB_TRANSCRIPT_PATH" = "" ]; then
    if [ -n "$SB_SESSION_ID" ] && [ "$SB_SESSION_ID" != "unknown" ]; then
      local possible="$HOME/.claude/sessions/$SB_SESSION_ID.jsonl"
      [ -f "$possible" ] && SB_TRANSCRIPT_PATH="$possible"
    fi
  fi
  [ -n "$SB_TRANSCRIPT_PATH" ] && [ -f "$SB_TRANSCRIPT_PATH" ]
}

# Count user turns in transcript. Sets SB_USER_TURNS.
sb_count_user_turns() {
  SB_USER_TURNS=0
  if [ -n "$SB_TRANSCRIPT_PATH" ] && [ -f "$SB_TRANSCRIPT_PATH" ]; then
    SB_USER_TURNS=$(jq -r 'select(.type=="user" and (.message.content | type == "string")) | .type' "$SB_TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
    SB_USER_TURNS=${SB_USER_TURNS:-0}
  fi
}

# Count friction/positive signals for current session. Sets SB_FRICTION_COUNT, SB_POSITIVE_COUNT, SB_FIRST_TRY.
sb_count_friction() {
  SB_FRICTION_COUNT=0
  SB_POSITIVE_COUNT=0
  if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
    SB_FRICTION_COUNT=$(jq -s --arg s "$SB_SESSION_ID" '[.[] | select(.session_id == $s and (.direction // "negative") == "negative")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
    SB_POSITIVE_COUNT=$(jq -s --arg s "$SB_SESSION_ID" '[.[] | select(.session_id == $s and .direction == "positive")] | length' "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
    SB_FRICTION_COUNT=${SB_FRICTION_COUNT:-0}
    SB_POSITIVE_COUNT=${SB_POSITIVE_COUNT:-0}
  fi
  SB_FIRST_TRY="false"
  if [ "$SB_FRICTION_COUNT" -eq 0 ] && [ "$SB_USER_TURNS" -ge 3 ]; then
    SB_FIRST_TRY="true"
  fi
}

# Count drift signals for current session. Sets SB_DRIFT_COUNT.
sb_count_drift() {
  SB_DRIFT_COUNT=0
  if [ -f "$BRAIN_DIR/drift-log.jsonl" ]; then
    SB_DRIFT_COUNT=$(jq -s --arg s "$SB_SESSION_ID" '[.[] | select(.session_id == $s)] | length' "$BRAIN_DIR/drift-log.jsonl" 2>/dev/null)
    SB_DRIFT_COUNT=${SB_DRIFT_COUNT:-0}
  fi
}

# Calculate priority based on friction/drift. Sets SB_PRIORITY.
sb_calc_priority() {
  local friction_trigger="${SECOND_BRAIN_FRICTION_TRIGGER:-5}"
  local drift_trigger="${SECOND_BRAIN_DRIFT_TRIGGER:-3}"
  SB_PRIORITY="normal"
  if [ "$SB_FRICTION_COUNT" -ge "$friction_trigger" ] || [ "$SB_DRIFT_COUNT" -ge "$drift_trigger" ]; then
    SB_PRIORITY="high"
  fi
}

# Check auto-improve config and compute whether to suggest. Sets SB_SUGGEST_IMPROVE.
sb_check_auto_improve() {
  SB_SUGGEST_IMPROVE="false"
  local auto_improve
  auto_improve=$(jq -r '.auto_improve // false' "$BRAIN_DIR/config.json" 2>/dev/null)
  [ "$auto_improve" != "true" ] && return

  local last_date=""
  [ -f "$BRAIN_DIR/.last-plugin-improve" ] && last_date=$(cat "$BRAIN_DIR/.last-plugin-improve" 2>/dev/null)

  local learnings_since=0
  if [ -f "$BRAIN_DIR/learnings.md" ]; then
    if [ -n "$last_date" ]; then
      learnings_since=$(awk -v cutoff="$last_date" '
        /^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
          d = substr($0, 5, 10)
          if (d > cutoff) c++
        }
        END { print c+0 }
      ' "$BRAIN_DIR/learnings.md" 2>/dev/null)
    else
      learnings_since=$(grep -c "^## \[" "$BRAIN_DIR/learnings.md" 2>/dev/null)
    fi
    learnings_since=${learnings_since:-0}
  fi

  if [ "$SB_FRICTION_COUNT" -ge 2 ] || [ "$learnings_since" -ge 3 ]; then
    SB_SUGGEST_IMPROVE="true"
  fi
}

# Write pending reflection JSON. Args: $1=trigger
sb_write_reflection() {
  local trigger="${1:-unknown}"
  jq -n \
    --arg s "$SB_SESSION_ID" \
    --arg d "$SB_TIMESTAMP" \
    --argjson ut "$SB_USER_TURNS" \
    --argjson fc "$SB_FRICTION_COUNT" \
    --argjson ps "$SB_POSITIVE_COUNT" \
    --argjson fts "$SB_FIRST_TRY" \
    --argjson dc "$SB_DRIFT_COUNT" \
    --arg pr "$SB_PRIORITY" \
    --argjson spi "$SB_SUGGEST_IMPROVE" \
    --arg tr "$trigger" \
    --arg tp "$SB_TRANSCRIPT_PATH" \
    '{session_id:$s, date:$d, user_turns:$ut, friction_count:$fc, positive_signals:$ps, first_try_success:$fts, drift_count:$dc, priority:$pr, suggest_plugin_improve:$spi, trigger:$tr, transcript_path:$tp}' \
    > "$BRAIN_DIR/.pending-reflection.json"
}

# Write session metadata JSON.
sb_write_session_meta() {
  jq -n \
    --arg s "$SB_SESSION_ID" \
    --arg d "$SB_TIMESTAMP" \
    --argjson ut "$SB_USER_TURNS" \
    --argjson fs "$SB_FRICTION_COUNT" \
    --argjson ps "$SB_POSITIVE_COUNT" \
    --argjson fts "$SB_FIRST_TRY" \
    '{session_id:$s, date:$d, user_turns:$ut, friction_signals:$fs, positive_signals:$ps, first_try_success:$fts}' \
    > "$BRAIN_DIR/.last-session-meta.json"
}

# Full collection pipeline: parse → resolve → count turns → count friction → count drift → calc priority → check improve.
# Returns 1 if transcript unresolvable or too few turns (< $1, default 3).
sb_collect_session_data() {
  local min_turns="${1:-3}"
  mkdir -p "$BRAIN_DIR"
  sb_parse_input
  sb_resolve_transcript || return 1
  sb_count_user_turns
  [ "$SB_USER_TURNS" -lt "$min_turns" ] && return 1
  sb_count_friction
  sb_count_drift
  sb_calc_priority
  sb_check_auto_improve
  return 0
}
