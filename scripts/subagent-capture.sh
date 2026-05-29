#!/bin/bash
# SubagentStop hook: archive a substantive, NON-SELF subagent's FINAL RESULT into
# ~/.second-brain/transcripts/ so it becomes dream-minable + episodic-searchable.
# Closes the multi-agent extraction blind spot — the main-session Stop extractor
# only ever sees the top-level transcript, never the per-subagent ones.
#
# Design: docs/specs/2026-05-29-subagent-capture-design.md
# Properties (load-bearing):
#   - ALWAYS exit 0. A non-zero SubagentStop would PREVENT the subagent from
#     stopping and wedge the parent's fan-out.
#   - OAuth-safe / offline-first: pure file ops, never invokes `claude`.
#   - Captures the final RESULT only (last assistant text), not the full transcript.
#   - Self-excludes the plugin's own consolidation/review agents (no mining-self).
#   - Drops mechanical (0-tool) and near-empty results.
# Kill switch: SB_SUBAGENT_CAPTURE=off
set -u
source "$(dirname "$0")/lib.sh"

# Kill switch + jq dependency (no jq => silently no-op, like other hooks).
[ "${SB_SUBAGENT_CAPTURE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

RAW=$(cat 2>/dev/null || true)
[ -n "$RAW" ] || exit 0
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$RAW" | jq -r '.agent_type // empty' 2>/dev/null)
AGENT_ID=$(echo "$RAW"   | jq -r '.agent_id // empty' 2>/dev/null)
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null)
CWD=$(echo "$RAW"        | jq -r '.cwd // empty' 2>/dev/null)

# Need a readable transcript to capture anything.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
[ -n "$AGENT_ID" ] || AGENT_ID="unknown"

# --- Self-exclude: never archive the plugin's OWN agents (mining-self = noise
# feeding itself). Match the bare name and the namespaced plugin:...:name form. ---
SELF_AGENTS="dream-runner knowledge-maintainer code-review-unit-reviewer code-review-scorer code-review-history-reviewer quality-reviewer search-conversations"
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

# --- Extract the FINAL result = last assistant record's concatenated text blocks. ---
RESULT=$(jq -rc '
  select(.type == "assistant")
  | [.message.content[]? | select(.type == "text") | .text]
  | select(length > 0) | join("\n")
' "$TRANSCRIPT" 2>/dev/null | tail -1)

# --- Substantive gate 2: drop near-empty results (the real 4-byte case). ---
MIN="${SB_SUBAGENT_MIN_RESULT:-80}"
RLEN=$(printf '%s' "$RESULT" | tr -d '[:space:]' | wc -c | tr -d ' ')
[ "${RLEN:-0}" -ge "$MIN" ] || exit 0

SLUG=$(sb_resolve_slug "${CWD:-$PWD}")

# Archive (file ops only; never fatal to the hook).
sb_archive_subagent_result "$AGENT_ID" "${AGENT_TYPE:-unknown}" "$SLUG" "$SESSION_ID" "$TOOL_COUNT" "$RESULT" 2>/dev/null || true

exit 0
