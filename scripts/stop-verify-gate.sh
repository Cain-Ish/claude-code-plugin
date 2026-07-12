#!/bin/bash
# stop-verify-gate.sh — Stop hook verification gate
# Blocks completion when code was modified but no verification evidence exists.
# Returns {"decision":"block","reason":"..."} to force Claude to run checks.
#
# Kill switch: SB_VERIFY_GATE=off
# Safety valve: blocks at most 2 times per session (marker file).
# Always fails open — parse errors or missing data → approve.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

[ "${SB_VERIFY_GATE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

TRANSCRIPT=$(printf '%s' "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
MARKER="$BRAIN_DIR/.verify-gate-blocks-$SESSION_ID"

# Safety valve: max 2 blocks per session to prevent infinite loops.
BLOCK_COUNT=0
[ -f "$MARKER" ] && BLOCK_COUNT=$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')
BLOCK_COUNT=${BLOCK_COUNT:-0}
if [ "$BLOCK_COUNT" -ge 2 ]; then
  exit 0
fi

# Check if code was modified (Write, Edit, or MultiEdit tool calls).
CODE_MODIFIED=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
  | .input.file_path // ""
  | select(. != "")
  | select((endswith(".md") or endswith(".markdown") or endswith(".txt") or test("(^|/)docs/")) | not)
' "$TRANSCRIPT" 2>/dev/null | head -1)

if [ -z "$CODE_MODIFIED" ]; then
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

# Code was modified — look for verification evidence.
# 1. Bash commands that look like test/lint/build/check runs.
VERIFY_CMDS=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use" and .name == "Bash")
  | .input.command // ""
' "$TRANSCRIPT" 2>/dev/null \
  | grep -iwE '(test|vitest|jest|pytest|mocha|lint|eslint|tsc|typecheck|type-check|build|check|prettier|biome)' \
  | head -1)

# 2. Skill invocations (assistant text referencing review/security skills).
SKILL_EVIDENCE=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "text")
  | .text // ""
' "$TRANSCRIPT" 2>/dev/null \
  | grep -iE '/(review|security-review|simplify|qa|second-brain:verification)' \
  | head -1)

# 3. Skill tool invocations via the Skill tool.
SKILL_TOOL=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use" and .name == "Skill")
  | .input.skill // ""
' "$TRANSCRIPT" 2>/dev/null \
  | grep -iE 'review|security|simplify|qa|verification' \
  | head -1)

# Anti-gaming slice (P0.5, loop-eng research): verification evidence is SUSPECT when
# the same session DELETED a test file — the cheapest reward-hack in the catalog
# (delete the failing test, run the now-green suite, claim verified). TDD test EDITS
# are normal and never flagged; only rm / git rm of a test-shaped path. One pointed
# block through the same 2-block valve. Kill switch: SB_VERIFY_ANTIGAME=off.
# BSD-safe patterns only: [[:space:]] classes, no \b/\s/\w.
TEST_RM=""
if [ "${SB_VERIFY_ANTIGAME:-on}" != "off" ]; then
  TEST_RM=$(jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | .input.command // ""
  ' "$TRANSCRIPT" 2>/dev/null \
    | grep -E '(^|[^[:alnum:]_-])(git[[:space:]]+)?rm[[:space:]]' \
    | grep -E '(tests?/|[._-]test\.|[._-]spec\.|/test_[a-z0-9_]+\.py)' \
    | head -1)
fi

if [ -n "$VERIFY_CMDS" ] || [ -n "$SKILL_EVIDENCE" ] || [ -n "$SKILL_TOOL" ]; then
  if [ -n "$TEST_RM" ]; then
    mkdir -p "$BRAIN_DIR" 2>/dev/null
    echo "$((BLOCK_COUNT + 1))" > "$MARKER"
    jq -nc --arg cmd "$TEST_RM" '{
      decision: "block",
      reason: ("Verification evidence coincides with a test-file deletion in this session: `\($cmd)`. Deleting a test and then claiming green is the cheapest way to fake verification. Re-run the FULL suite and state explicitly why removing that test is correct (obsolete behavior? coverage superseded where?) — or restore it. Suppress this check: SB_VERIFY_ANTIGAME=off.")
    }'
    exit 0
  fi
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

# No verification evidence found — block.
mkdir -p "$BRAIN_DIR" 2>/dev/null
echo "$((BLOCK_COUNT + 1))" > "$MARKER"

jq -nc '{
  decision: "block",
  reason: "Code was modified but no verification ran. Before completing, run applicable checks: tests, lint, type-check. Then invoke relevant review skills (/review, /security-review, /simplify) for quality and security. Evidence before assertions."
}'
