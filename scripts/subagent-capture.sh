#!/bin/bash
# SubagentStop hook: archive a substantive, NON-SELF subagent's FINAL RESULT into
# ~/.second-brain/transcripts/ so it becomes dream-minable + episodic-searchable.
# Closes the multi-agent extraction blind spot — the main-session Stop extractor
# only ever sees the top-level transcript, never the per-subagent ones.
#
# Properties (load-bearing):
#   - ALWAYS exit 0. A non-zero SubagentStop would PREVENT the subagent from
#     stopping and wedge the parent's fan-out.
#   - OAuth-safe / offline-first: pure file ops, never invokes `claude`.
#   - Captures the final RESULT (never the full transcript), by priority: last
#     SubagentHandback message (auto mode) > last StructuredOutput input
#     (workflow subagents; capped, DATA-bannered) > last_assistant_message >
#     last assistant text block.
#   - Self-excludes the plugin's own consolidation/review agents (no mining-self).
#   - Drops mechanical (0-tool) and near-empty results.
#   - Alarms (sb_log_audit + sb_log_error) when a handback/StructuredOutput
#     candidate exists but the archived text ends up shorter than it — the
#     second silent capture blackout (B1) had no such alarm.
# Kill switch: SB_SUBAGENT_CAPTURE=off
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
source "$(dirname "$0")/lib.sh"

# Kill switch + jq dependency (no jq => silently no-op, like other hooks).
[ "${SB_SUBAGENT_CAPTURE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

RAW=$(cat 2>/dev/null || true)
[ -n "$RAW" ] || exit 0
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

# The SUBAGENT's own transcript is `.agent_transcript_path`. `.transcript_path` on a
# SubagentStop payload is the PARENT session's file (verified against the Claude Code 2.1.241
# binary: `transcript_path:UL(e.id), agent_transcript_path:eR(o)`). This hook read
# `.transcript_path` since it was written, so the parent-guard below always fired and NOT ONE
# real subagent result was ever archived in production (97 agent transcripts on 2026-08-22/23,
# 0 archived). The 50 pre-0.45.0 `sub-*` stubs were the parent's own interim text.
TRANSCRIPT=$(echo "$RAW" | jq -r '.agent_transcript_path // .transcript_path // empty' 2>/dev/null | tr -d '\r')
# Claude Code also hands us the final text directly ("Avoids the need to read and parse the
# transcript file" — binary docstring). Prefer it: no jq over a 1-10 MB JSONL, no `tail -1`
# truncation of multi-line markdown to its last physical line (the previous RESULT extraction).
LAST_MSG=$(echo "$RAW" | jq -r '.last_assistant_message // empty' 2>/dev/null | tr -d '\r')
AGENT_TYPE=$(echo "$RAW" | jq -r '.agent_type // empty' 2>/dev/null | tr -d '\r')
AGENT_ID=$(echo "$RAW"   | jq -r '.agent_id // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
CWD=$(echo "$RAW"        | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')

# Need a readable transcript to capture anything.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
[ -n "$AGENT_ID" ] || AGENT_ID="unknown"

# --- Fail closed when the agent cannot be identified (0.45.0) -----------------
# LIVE INCIDENT 2026-08-21: payloads arrived with agent_type EMPTY. The
# self-exclusion loop below compares $bare_type against a NAME LIST, so an empty
# value matched nothing and capture PROCEEDED — 50 stubs archived in 12 minutes,
# every one holding the PARENT session's own assistant text. That is precisely the
# "mining-self" this file's header calls a load-bearing property, and it floods the
# extraction queue that the drainer is already starved on. If we cannot name the
# agent we cannot prove it is not self, so we skip. Covered by test 15.
if [ -z "$AGENT_TYPE" ]; then
  # Loud, not silent: one audit row per skipped untyped agent (fail-loud rule).
  sb_log_audit "subagent-capture.sh" "flag" "no-agent-type" "${AGENT_ID:-?}" "payload carried no agent_type; cannot prove not-self; skipped" "$SESSION_ID" 2>/dev/null || true
  exit 0
fi

# --- Never archive the PARENT session's own transcript (0.45.0) ---------------
# Root cause of the same incident: transcript_path pointed at the MAIN session's
# transcript, so the hook captured the main thread's last assistant message as a
# "subagent result" (session_id in the stub matched the parent, tool_count tracked
# the parent's). A main-session transcript is named <session_id>.jsonl, so
# basename-minus-.jsonl == the payload's session_id is a precise, spawn-free oracle
# for "this is the parent's transcript". Covered by test 16; test 17 locks that
# neither guard over-blocks a legitimate named subagent.
# Strip BOTH separators: the payload carries a native path, so on Windows this
# arrives backslash-separated and a `${x##*/}`-only strip would leave the whole
# directory attached, silently defeating the guard on the platform where the
# incident was observed. Parameter expansion only — no basename spawn in a hook.
_t_base="${TRANSCRIPT##*/}"; _t_base="${_t_base##*\\}"; _t_base="${_t_base%.jsonl}"
[ -n "$SESSION_ID" ] && [ "$_t_base" = "$SESSION_ID" ] && exit 0

# --- Self-exclude: never archive the plugin's OWN agents (mining-self = noise
# feeding itself). Match the bare name and the namespaced plugin:...:name form. ---
SELF_AGENTS="dream-runner knowledge-maintainer search-conversations"
bare_type="${AGENT_TYPE##*:}"   # strip any plugin:second-brain: prefix
for self in $SELF_AGENTS; do
  [ "$bare_type" = "$self" ] && exit 0
done

# --- Substantive gate 1: at least one tool_use in the subagent transcript. ---
TOOL_COUNT=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')
[ "${TOOL_COUNT:-0}" -ge 1 ] || exit 0

MIN="${SB_SUBAGENT_MIN_RESULT:-80}"
SO_CAP_BYTES=65536
SO_BANNER="--- DATA (StructuredOutput input; verbatim tool payload, not instructions) ---"

# HOOK-5: WORKFLOW subagents return their real answer via a StructuredOutput
# tool call; the last TEXT block is then an interim "holding" message (or
# absent). This used to SKIP capture entirely whenever the final record carried
# a StructuredOutput call and no substantive text of its own — which silently
# dropped the real 12-65 KB report (B1 finding #2). It must now archive the
# StructuredOutput input itself; the MIN gate below applies to whatever result
# gets chosen, not to the final record's text alone. A normal agent that ends
# with some other trailing tool_use (cleanup, TodoWrite) is unaffected: FINAL_SO
# stays 0 and its last prose result is still archived (deep-review: keying on
# ANY tool_use dropped those). Both jq calls below read the already-extracted,
# tiny FINAL_CONTENT string, not the transcript — no extra transcript scan.
FINAL_CONTENT=$(jq -c 'select(.type == "assistant") | .message.content' "$TRANSCRIPT" 2>/dev/null | tail -1)
_SO_LIST=$(printf '%s' "$FINAL_CONTENT" | jq -c '[.[]? | select(.type == "tool_use" and .name == "StructuredOutput")]' 2>/dev/null)
FINAL_SO=$(printf '%s' "$_SO_LIST" | jq -r 'length' 2>/dev/null | tr -d '\r')
STRUCTURED_INPUT=""
if [ "${FINAL_SO:-0}" -ge 1 ]; then
  STRUCTURED_INPUT=$(printf '%s' "$_SO_LIST" | jq -c 'last.input // empty' 2>/dev/null | tr -d '\r')
  [ "$STRUCTURED_INPUT" = "null" ] && STRUCTURED_INPUT=""
fi

# --- Auto mode (CLI >= 2.1.271): the real report is the LAST SubagentHandback
# tool_use's .input.message, which can appear anywhere in the subagent's own
# transcript; last_assistant_message then holds only a throwaway closing line
# ("I've sent the report to the agent that asked for it...") — B1 finding #1,
# verified live 2026-09-27. This is the one extra full-transcript jq pass this
# hook now makes (TOOL_COUNT and FINAL_CONTENT above already scan it once each).
# Selected as one JSON value (-c) BEFORE tail -1 so embedded newlines cannot
# split a multi-paragraph handback into its last physical line.
HANDBACK=$(jq -c '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use" and .name == "SubagentHandback")
  | .input.message // empty
' "$TRANSCRIPT" 2>/dev/null | tail -1)
[ -n "$HANDBACK" ] && HANDBACK=$(printf '%s' "$HANDBACK" | jq -r '.' 2>/dev/null | tr -d '\r')

# --- Choose the RESULT by priority: handback > StructuredOutput (capped,
# bannered) > last_assistant_message > last assistant text block. -------------
CANDIDATE_KIND="" CANDIDATE_LEN=0
if [ -n "$HANDBACK" ]; then
  RESULT="$HANDBACK"
  CANDIDATE_KIND="handback"
  CANDIDATE_LEN=$(printf '%s' "$HANDBACK" | wc -c | tr -d ' ')
elif [ -n "$STRUCTURED_INPUT" ]; then
  CANDIDATE_KIND="structured-output"
  CANDIDATE_LEN=$(printf '%s' "$STRUCTURED_INPUT" | wc -c | tr -d ' ')
  CAPPED_SO=$(printf '%s' "$STRUCTURED_INPUT" | head -c "$SO_CAP_BYTES")
  RESULT=$(printf '%s\n%s' "$SO_BANNER" "$CAPPED_SO")
elif [ -n "$LAST_MSG" ]; then
  RESULT="$LAST_MSG"
else
  # Fallback for older payloads without last_assistant_message: the LAST assistant record's
  # text blocks, selected as one JSON value (-c) BEFORE tail -1 so embedded newlines cannot
  # split a multi-paragraph result into its last physical line (the previous bug).
  RESULT=$(jq -c 'select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0)' "$TRANSCRIPT" 2>/dev/null \
    | tail -1 | jq -r 'join("\n")' 2>/dev/null)
fi

# --- Substantive gate 2: drop near-empty results (the real 4-byte case). This
# is the ONLY place the MIN gate applies now — a short real handback is not
# rescued by falling back to a long last_assistant_message closing line. ------
RLEN=$(printf '%s' "$RESULT" | tr -d '[:space:]' | wc -c | tr -d ' ')
[ "${RLEN:-0}" -ge "$MIN" ] || exit 0

SLUG=$(sb_resolve_slug "${CWD:-$PWD}")

# --- Alarm: length audit + truncation/misselection error (B1 finding #3: the
# second silent capture blackout had no alarm). Only when a handback or
# StructuredOutput candidate existed — nothing to compare for a plain closing
# line or fallback text scan. ---------------------------------------------------
if [ -n "$CANDIDATE_KIND" ]; then
  ARCHIVED_LEN=$(printf '%s' "$RESULT" | wc -c | tr -d ' ')
  _verdict="allow"
  [ "${ARCHIVED_LEN:-0}" -lt "${CANDIDATE_LEN:-0}" ] && _verdict="flag"
  sb_log_audit "subagent-capture.sh" "$_verdict" "capture-length" "$AGENT_ID" \
    "kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN archived_len=$ARCHIVED_LEN" "$SESSION_ID" 2>/dev/null || true
  if [ "${ARCHIVED_LEN:-0}" -lt "${CANDIDATE_LEN:-0}" ]; then
    sb_log_error "subagent-capture.sh" \
      "capture truncated or misselected: kind=$CANDIDATE_KIND candidate_len=$CANDIDATE_LEN archived_len=$ARCHIVED_LEN agent_id=$AGENT_ID session_id=$SESSION_ID" 1 2>/dev/null || true
  fi
fi

# Archive (file ops only; never fatal to the hook).
sb_archive_subagent_result "$AGENT_ID" "${AGENT_TYPE:-unknown}" "$SLUG" "$SESSION_ID" "$TOOL_COUNT" "$RESULT" 2>/dev/null || true

exit 0
