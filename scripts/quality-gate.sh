#!/bin/bash
# Quality gate instruction injected after every Write/Edit via a PostToolUse
# hookSpecificOutput.additionalContext envelope (D158 — plain stdout from a
# PostToolUse hook is only ever shown in transcript mode; additionalContext JSON
# is the only PostToolUse path into model context, per the pattern
# simplicity-gate.sh already uses). Kill switch: SB_QUALITY_GATE=off (D077).
set -u
[ "${SB_QUALITY_GATE:-on}" = "off" ] && exit 0
CTX="QUALITY GATE - Silently self-review what you just wrote against the quality rules and persona loaded at session start. Check: gaps, correctness, security, completeness, consistency, human-style code. Fix issues immediately. Do not narrate."
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null && exit 0
fi
# review follow-up: a jq-less host (or a transient jq failure above) used to fall through
# `|| true` and emit NOTHING — silently dropping the quality-gate reminder from every
# single Write/Edit rather than just this one hook invocation. CTX is a fixed literal (no
# attacker-controlled bytes reach this script), so escaping backslash/double-quote is
# sufficient to build the envelope by hand.
_esc=$(printf '%s' "$CTX" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$_esc"
exit 0
