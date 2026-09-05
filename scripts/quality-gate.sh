#!/bin/bash
# Quality gate instruction injected after every Write/Edit via a PostToolUse
# hookSpecificOutput.additionalContext envelope (D158 — plain stdout from a
# PostToolUse hook is only ever shown in transcript mode; additionalContext JSON
# is the only PostToolUse path into model context, per the pattern
# simplicity-gate.sh already uses). Kill switch: SB_QUALITY_GATE=off (D077).
set -u
[ "${SB_QUALITY_GATE:-on}" = "off" ] && exit 0
CTX="QUALITY GATE - Silently self-review what you just wrote against the quality rules and persona loaded at session start. Check: gaps, correctness, security, completeness, consistency, human-style code. Fix issues immediately. Do not narrate."
jq -nc --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
exit 0
