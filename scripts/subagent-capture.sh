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
#   - Captures the final RESULT only (last assistant text), not the full transcript.
#   - Self-excludes the plugin's own consolidation/review agents (no mining-self).
#   - Drops mechanical (0-tool) and near-empty results.
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

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
AGENT_TYPE=$(echo "$RAW" | jq -r '.agent_type // empty' 2>/dev/null | tr -d '\r')
AGENT_ID=$(echo "$RAW"   | jq -r '.agent_id // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
CWD=$(echo "$RAW"        | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')

# Need a readable transcript to capture anything.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
[ -n "$AGENT_ID" ] || AGENT_ID="unknown"

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

# HOOK-5: WORKFLOW subagents return their real answer via a
# StructuredOutput tool call; the last TEXT block is then an interim "holding"
# message. Skip ONLY when the final assistant record carries a StructuredOutput
# call and no substantive text of its own — a normal agent that ends with some
# other trailing tool_use (cleanup, TodoWrite) still has its last prose result
# archived (deep-review: keying on ANY tool_use dropped those).
FINAL_CONTENT=$(jq -c 'select(.type == "assistant") | .message.content' "$TRANSCRIPT" 2>/dev/null | tail -1)
FINAL_SO=$(printf '%s' "$FINAL_CONTENT" | jq -r '[.[]? | select(.type == "tool_use") | select(.name == "StructuredOutput")] | length' 2>/dev/null | tr -d '\r')
FINAL_TEXT_LEN=$(printf '%s' "$FINAL_CONTENT" | jq -r '[.[]? | select(.type == "text") | .text] | join("")' 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
if [ "${FINAL_SO:-0}" -ge 1 ] && [ "${FINAL_TEXT_LEN:-0}" -lt "$MIN" ]; then
  exit 0
fi

# --- Extract the FINAL result = last assistant record's concatenated text blocks. ---
RESULT=$(jq -rc '
  select(.type == "assistant")
  | [.message.content[]? | select(.type == "text") | .text]
  | select(length > 0) | join("\n")
' "$TRANSCRIPT" 2>/dev/null | tail -1)

# --- Substantive gate 2: drop near-empty results (the real 4-byte case). ---
RLEN=$(printf '%s' "$RESULT" | tr -d '[:space:]' | wc -c | tr -d ' ')
[ "${RLEN:-0}" -ge "$MIN" ] || exit 0

SLUG=$(sb_resolve_slug "${CWD:-$PWD}")

# Archive (file ops only; never fatal to the hook).
sb_archive_subagent_result "$AGENT_ID" "${AGENT_TYPE:-unknown}" "$SLUG" "$SESSION_ID" "$TOOL_COUNT" "$RESULT" 2>/dev/null || true

exit 0
