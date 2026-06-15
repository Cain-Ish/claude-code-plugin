#!/bin/bash
# simplicity-gate.sh — PostToolUse advisory (Principle 2: Simplicity First). When a single
# Write/Edit/MultiEdit writes more than SB_SIMPLICITY_GATE_LINES (default 150) non-blank lines,
# nudge toward a smaller, naive-correct version. Advisory only (additionalContext, never blocks).
# Kill switch SB_SIMPLICITY_GATE=off. No awk (mawk-safe), fail-soft.
set -u
[ "${SB_SIMPLICITY_GATE:-on}" = "off" ] && exit 0
RAW=$(cat 2>/dev/null || true); [ -z "$RAW" ] && exit 0
TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac
LIMIT="${SB_SIMPLICITY_GATE_LINES:-150}"
case "$LIMIT" in ''|*[!0-9]*) LIMIT=150 ;; esac
# Lines written by this change = Write.content OR Edit.new_string OR sum of MultiEdit new_strings.
LINES=$(printf '%s' "$RAW" | jq -r '
  ((.tool_input.content // .tool_input.new_string // "")
   + "\n"
   + ([.tool_input.edits[]?.new_string // ""] | join("\n")))' 2>/dev/null | grep -c . )
[ "${LINES:-0}" -gt "$LIMIT" ] 2>/dev/null || exit 0
CTX="[Simplicity check — Principle 2] This change writes ~${LINES} lines (> ${LIMIT}). Before continuing: is there a naive-correct version roughly half the size? Drop speculative abstractions/config/flexibility that wasn't requested. Consider /simplify or the code-simplifier. Advisory only — nothing was blocked."
jq -nc --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
exit 0
