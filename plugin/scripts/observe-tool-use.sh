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
mkdir -p "$OBS_DIR" 2>/dev/null || exit 0
OBS_FILE="$OBS_DIR/$SID.jsonl"

# Size cap BEFORE the append: a runaway session must not grow the ledger
# unbounded (1 MiB ≈ 5000+ records — far past any real session).
MAX_BYTES="${SB_OBSERVATION_MAX_BYTES:-1048576}"
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=1048576 ;; esac
if [ -f "$OBS_FILE" ]; then
  CUR_BYTES=$(wc -c < "$OBS_FILE" 2>/dev/null | tr -d ' ')
  case "$CUR_BYTES" in ''|*[!0-9]*) CUR_BYTES=0 ;; esac
  [ "$CUR_BYTES" -ge "$MAX_BYTES" ] && exit 0
fi

# ONE jq builds the whole line (hot path — this fires on every matched tool
# return). target = the tool's primary argument; ok/err derived from the
# response's error markers CONSERVATIVELY (absent markers ⇒ ok:true — a wrong
# ok:true is noise, a fabricated error would poison the error→fix mining).
# tr -d '\r': jq stdout is CRLF on Windows git-bash (jq discipline, rule 4).
printf '%s' "$RAW" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
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
' 2>/dev/null | tr -d '\r' >> "$OBS_FILE" || true

exit 0
