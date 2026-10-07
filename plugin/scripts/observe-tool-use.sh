#!/bin/bash
# observe-tool-use.sh — PostToolUse hook (capture posture): the deterministic
# observation ledger. Appends ONE compact JSONL line per tool use —
# {ts, tool, target, ok[, err]} — to $BRAIN_DIR/observations/<session>.jsonl.
# Pure jq/bash, zero LLM (sibling of tool-return-scanner.sh).
#
# The failure mode this closes: the whole session's capture rides ONE
# Stop/PreCompact LLM call with known ec=124 timeouts — when that call dies,
# the session's signal is gone, and the preprocessed transcript archive keeps
# tool INPUTS but not their success/failure. This ledger survives extraction
# loss entirely and records the ok|error dimension, so the out-of-band drainer
# can mine error clusters / retry loops / files touched alongside the
# transcript (claude-mem observation grain; P8's declared-vs-observed source).
#
# Kill switch: SB_OBSERVATION_LEDGER=off. Per-session file bounded by
# SB_OBSERVATION_MAX_BYTES (default 1 MiB). Old ledgers are swept by the
# drainer's GC (7 days). Always exits 0 (capture must never block the harness).
set -u

[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_OBSERVATION_LEDGER:=off}" # hook-profile shim: this check runs before lib.sh's mapping (prose-locks pairing)
[ "${SB_OBSERVATION_LEDGER:-on}" = "off" ] && exit 0
# Nested-spawn circuit breaker (R1.1): plugin-spawned headless children must not
# ledger their own tool calls into the parent's observation stream.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

# lib.sh gives BRAIN_DIR its single-source resolution (incl. the MSYS cygpath
# normalization). This is telemetry: if lib.sh is unsourceable, go quiet —
# unlike the PreToolUse guards, there is nothing here that must stay armed.
if ! source "$(dirname "$0")/lib.sh" 2>/dev/null; then exit 0; fi

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
[ -z "$TOOL" ] && exit 0

# Session id names the ledger file — sanitize to a path-safe token (defense in
# depth: the payload is harness-controlled, but the id lands in a filename).
SID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r' | tr -cd 'A-Za-z0-9_-' | cut -c1-64)
[ -n "$SID" ] || SID="unknown"

OBS_DIR="$BRAIN_DIR/observations"
OBS_FILE="$OBS_DIR/$SID.jsonl"

# obs_loud_once <condition> <message>: one sb_log_error row per session and condition, not one per
# tool call (this hook fires on every tool use). A flag remembers the row: <SID>.<condition>.flag in
# observations/, or $BRAIN_DIR/.obs-<SID>.<condition>.flag when observations/ itself is what fails
# (unwritable, or not a directory): a flag kept only in the failing directory was never created, so
# the row repeated on every tool call. Where neither flag can be created the row is skipped, for the
# same reason. The drainer's 7-day GC sweeps both kinds. Message: fixed text, the session id prefix,
# the tool name and numbers only, never the observation itself.
obs_loud_once() {
  local flag="$OBS_DIR/$SID.$1.flag" alt="$BRAIN_DIR/.obs-$SID.$1.flag"
  { [ -e "$flag" ] || [ -e "$alt" ]; } && return 0
  # The braces carry the stderr redirect: `: > f 2>/dev/null` reports a failed `> f` before it
  # applies (the redirections run left to right), so the hook printed "Permission denied" anyway.
  { : > "$flag"; } 2>/dev/null || { : > "$alt"; } 2>/dev/null || return 0
  sb_log_error "observe-tool-use.sh" "$2" 1
}

# A ledger directory that cannot be created loses every observation of the session: said once.
if ! mkdir -p "$OBS_DIR" 2>/dev/null; then
  obs_loud_once mkdir-failed "observation ledger directory $OBS_DIR could not be created; the tool uses of session ${SID:0:8} are not recorded (reported once per session)"
  exit 0
fi

# Size cap BEFORE the append: a runaway session must not grow the ledger
# unbounded (1 MiB ≈ 5000+ records — far past any real session). Past the cap every later
# observation of the session is dropped: said once, not silently.
MAX_BYTES="${SB_OBSERVATION_MAX_BYTES:-1048576}"
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=1048576 ;; esac
if [ -f "$OBS_FILE" ]; then
  CUR_BYTES=$(wc -c < "$OBS_FILE" 2>/dev/null | tr -d ' ')
  case "$CUR_BYTES" in ''|*[!0-9]*) CUR_BYTES=0 ;; esac
  if [ "$CUR_BYTES" -ge "$MAX_BYTES" ]; then
    obs_loud_once capped "observation ledger for session ${SID:0:8} reached its cap (${CUR_BYTES} >= SB_OBSERVATION_MAX_BYTES ${MAX_BYTES}); later tool uses of this session are not recorded"
    exit 0
  fi
fi

# ONE jq builds the whole line (hot path — this fires on every matched tool
# return). target = the tool's primary argument; ok/err derived from the
# response's error markers CONSERVATIVELY (absent markers ⇒ ok:true — a wrong
# ok:true is noise, a fabricated error would poison the error→fix mining).
# CRs stripped: jq stdout is CRLF on Windows git-bash (jq discipline, rule 4). The line is captured
# (the same process count as the old jq | tr pipeline) so it can be secret-scrubbed before the
# append (X2 S3): target is command[0:200] and err stderr[0:160], and both carry keys verbatim
# (`ANTHROPIC_API_KEY=... claude -p`, `invalid x-api-key ...`), which the drainer then embedded
# in its extractor input. A builtin literal check keeps the scrub's spawn off key-free lines; a
# scrub that fails drops the observation (logged) rather than writing it unscrubbed.
LINE=$(printf '%s' "$RAW" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  (.tool_response // .tool_output // .tool_result // null) as $resp
  # PostToolUseFailure alone proves failure: upstream PostToolUse fires ONLY on
  # success (live-found 0.40.0 defect — a nonzero-exit Bash left NO ledger line),
  # so the failure event is wired to this same script and forces ok:false even
  # when the payload carries no error markers.
  | ( ((.hook_event_name // "") == "PostToolUseFailure")
      or ( if ($resp | type) == "object" then
        (($resp.is_error // $resp.isError // false) == true)
        or ((($resp.error // "") | tostring) != "")
        or ((($resp.exitCode // $resp.exit_code // 0) | tonumber? // 0) != 0)
      elif ($resp | type) == "string" then
        ($resp | test("^\\s*(Error|error:|fatal:)"))
      else false end ) ) as $err
  | {
      ts: $ts,
      tool: .tool_name,
      target: ((.tool_input.file_path // .tool_input.command // .tool_input.url
                // .tool_input.path // .tool_input.pattern // .tool_input.skill
                // .tool_input.subagent_type // "")
               | tostring | gsub("[\r\n]"; " ") | .[0:200]),
      ok: ($err | not)
    }
  + ( if $err then
        { err: (( if ($resp | type) == "object"
                  then (($resp.error // $resp.stderr // $resp.content // $resp.output // "") | tostring)
                  else ($resp | tostring) end)
                | gsub("[\r\n]"; " ") | .[0:160]) }
      else {} end )
' 2>/dev/null)
LINE="${LINE//$'\r'/}"
# The payload parsed (TOOL came out of it), so an empty record is jq failing (killed, missing).
if [ -z "$LINE" ]; then
  obs_loud_once jq-build-failed "observation ledger: jq could not build the record of a tool use of session ${SID:0:8} (tool=$TOOL); the observation is lost (reported once per session)"
  exit 0
fi
if sb_has_scrub_literal "$LINE"; then
  if ! LINE=$(printf '%s\n' "$LINE" | sb_scrub_secrets) || [ -z "$LINE" ]; then
    sb_log_error "observe-tool-use.sh" "secret scrub of an observation failed; the observation is dropped, not written unscrubbed (session=${SID:0:8} tool=$TOOL)" 1
    exit 0
  fi
fi
if ! { printf '%s\n' "$LINE" >> "$OBS_FILE"; } 2>/dev/null; then   # braces: see obs_loud_once
  obs_loud_once append-failed "observation ledger append failed for session ${SID:0:8} ($OBS_FILE not writable); the observation is lost (reported once per session)"
fi

exit 0
