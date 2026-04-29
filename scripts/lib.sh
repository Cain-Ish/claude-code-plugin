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
  if [ -z "$SB_TRANSCRIPT_PATH" ]; then
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
    SB_USER_TURNS=$(jq -r 'select(.type=="user") | "x"' "$SB_TRANSCRIPT_PATH" 2>/dev/null | wc -l | tr -d ' ')
    SB_USER_TURNS=${SB_USER_TURNS:-0}
  fi
}

# Count friction/positive signals for current session. Sets SB_FRICTION_COUNT, SB_POSITIVE_COUNT, SB_FIRST_TRY.
sb_count_friction() {
  SB_FRICTION_COUNT=0
  SB_POSITIVE_COUNT=0
  if [ -f "$BRAIN_DIR/friction-log.jsonl" ]; then
    local session_lines
    session_lines=$(grep -F "$SB_SESSION_ID" "$BRAIN_DIR/friction-log.jsonl" 2>/dev/null)
    if [ -n "$session_lines" ]; then
      SB_FRICTION_COUNT=$(echo "$session_lines" | jq -r --arg s "$SB_SESSION_ID" 'select(.session_id == $s and (.direction // "negative") == "negative") | "x"' 2>/dev/null | wc -l | tr -d ' ')
      SB_POSITIVE_COUNT=$(echo "$session_lines" | jq -r --arg s "$SB_SESSION_ID" 'select(.session_id == $s and .direction == "positive") | "x"' 2>/dev/null | wc -l | tr -d ' ')
    fi
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
    SB_DRIFT_COUNT=$(grep -cF "$SB_SESSION_ID" "$BRAIN_DIR/drift-log.jsonl" 2>/dev/null) || true
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

# Migrate old singular reflection file to new JSONL queue (one-time, idempotent).
sb_migrate_reflection() {
  local old_file="$BRAIN_DIR/.pending-reflection.json"
  local new_file="$BRAIN_DIR/.pending-reflections.jsonl"
  if [ -f "$old_file" ]; then
    jq -c '.' "$old_file" >> "$new_file" 2>/dev/null
    rm -f "$old_file"
  fi
}

# Snapshot last ~100 lines of transcript so content survives compaction.
# Sets SB_CONTEXT_SNAPSHOT to the snapshot path (empty if unavailable).
sb_snapshot_transcript() {
  SB_CONTEXT_SNAPSHOT=""
  if [ -z "$SB_TRANSCRIPT_PATH" ] || [ ! -f "$SB_TRANSCRIPT_PATH" ]; then
    return
  fi
  local snap_dir="$BRAIN_DIR/.reflection-context"
  mkdir -p "$snap_dir"
  local epoch
  epoch=$(date +%s)-$$
  local snap_file="$snap_dir/${SB_SESSION_ID}-${epoch}.txt"
  tail -100 "$SB_TRANSCRIPT_PATH" > "$snap_file" 2>/dev/null
  SB_CONTEXT_SNAPSHOT="$snap_file"
}

# Echo $1 if it parses as a JSON array; otherwise echo "[]". Used to harden
# --argjson against non-JSON or non-array handoff values. Requires jq.
sb_safe_json_array() {
  local val="${1:-[]}"
  if echo "$val" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$val"
  else
    echo "[]"
  fi
}

# Append a reflection entry to the JSONL queue. Args: $1=trigger
# Optional handoff fields: set SB_GOALS, SB_COMPLETED, SB_IN_PROGRESS, SB_BLOCKERS as JSON arrays before calling.
# Handoff vars are validated via sb_safe_json_array — a malformed value (non-JSON
# string, non-array JSON, etc.) falls back to "[]" instead of crashing the jq
# call and losing the entire reflection.
sb_write_reflection() {
  local trigger="${1:-unknown}"
  sb_migrate_reflection
  sb_snapshot_transcript
  local appended_at goals completed in_progress blockers
  appended_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  goals=$(sb_safe_json_array "${SB_GOALS:-[]}")
  completed=$(sb_safe_json_array "${SB_COMPLETED:-[]}")
  in_progress=$(sb_safe_json_array "${SB_IN_PROGRESS:-[]}")
  blockers=$(sb_safe_json_array "${SB_BLOCKERS:-[]}")
  jq -nc \
    --arg s "$SB_SESSION_ID" \
    --arg d "$SB_TIMESTAMP" \
    --arg at "$appended_at" \
    --argjson ut "$SB_USER_TURNS" \
    --argjson fc "$SB_FRICTION_COUNT" \
    --argjson ps "$SB_POSITIVE_COUNT" \
    --argjson fts "$SB_FIRST_TRY" \
    --argjson dc "$SB_DRIFT_COUNT" \
    --arg pr "$SB_PRIORITY" \
    --argjson spi "$SB_SUGGEST_IMPROVE" \
    --arg tr "$trigger" \
    --arg tp "$SB_TRANSCRIPT_PATH" \
    --arg cs "$SB_CONTEXT_SNAPSHOT" \
    --argjson goals "$goals" \
    --argjson completed "$completed" \
    --argjson in_progress "$in_progress" \
    --argjson blockers "$blockers" \
    '{session_id:$s, date:$d, appended_at:$at, user_turns:$ut, friction_count:$fc, positive_signals:$ps, first_try_success:$fts, drift_count:$dc, priority:$pr, suggest_plugin_improve:$spi, trigger:$tr, transcript_path:$tp, context_snapshot:$cs, goals:$goals, completed:$completed, in_progress:$in_progress, blockers:$blockers}' \
    >> "$BRAIN_DIR/.pending-reflections.jsonl" || \
    sb_log_error "sb_write_reflection" "jq failed writing reflection (trigger=$trigger)" $?
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

# Log an error to error-log.jsonl for session-load.sh to surface.
# Precondition: caller must ensure $BRAIN_DIR exists (e.g. mkdir -p before
# calling). The 2>/dev/null on the redirect would otherwise swallow the
# "no such file" error and the log entry would be lost silently.
# Falls back to printf-built JSON when jq is missing — otherwise the very
# error we want to log (jq absent) would itself fail silently. The printf
# path strips C0 control chars (U+0000-U+001F) before escaping so a multi-
# line error_msg can't fragment the JSONL record into two malformed lines.
sb_log_error() {
  local script_name="${1:-unknown}"
  local error_msg="${2:-}"
  local exit_code="${3:-1}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg t "$ts" \
      --arg s "$script_name" \
      --arg m "$error_msg" \
      --argjson c "$exit_code" \
      '{timestamp:$t, script:$s, message:$m, exit_code:$c}' \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
  else
    local esc_script esc_msg
    esc_script=$(printf '%s' "$script_name" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_msg=$(printf '%s' "$error_msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"timestamp":"%s","script":"%s","message":"%s","exit_code":%s}\n' \
      "$ts" "$esc_script" "$esc_msg" "$exit_code" \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
  fi
}

# Verify jq is available. If missing, log to error-log.jsonl and return 1.
# Caller pattern: `sb_require_jq || exit 0` — the hook then exits cleanly
# rather than running jq commands that would silently no-op. The error is
# surfaced to the user at next SessionStart via the error-nudge banner.
# Cached per-process via SB_JQ_OK to avoid repeated PATH lookups.
sb_require_jq() {
  if [ -n "${SB_JQ_OK:-}" ]; then
    [ "$SB_JQ_OK" = "1" ] && return 0 || return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    SB_JQ_OK=1
    return 0
  fi
  SB_JQ_OK=0
  local caller="${SB_SCRIPT_NAME:-${0##*/}}"
  sb_log_error "$caller" "jq not on PATH — hook no-op'd. Install: brew install jq / apt install jq / winget install jqlang.jq" 127
  return 1
}

# Check if context pressure is high (3+ compacts without a fresh session start).
# Returns 0 (true) if hooks should suppress stdout to avoid compaction loops.
sb_context_pressure() {
  local count_file="$BRAIN_DIR/.compact-count"
  local count
  count=$(cat "$count_file" 2>/dev/null || echo 0)
  [ "$count" -ge 3 ]
}

# Full collection pipeline: parse → resolve → count turns → count friction → count drift → calc priority → check improve.
# Returns 1 if transcript unresolvable or too few turns (< $1, default 3).
sb_collect_session_data() {
  local min_turns="${1:-3}"
  mkdir -p "$BRAIN_DIR"
  sb_require_jq || return 1
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
