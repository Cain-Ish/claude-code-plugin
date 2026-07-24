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
# Dedicated anti-game scan window marker: records how far into the
# transcript the last anti-game evaluation scanned, so a historical test-deletion is
# not re-flagged every Stop (which burned both slots of the 2-block valve). This is
# a SEPARATE marker from stop-extract.sh's extraction marker — that one is owned by
# stop-extract.sh, which runs AFTER this hook; advancing it here would skip lines.
AG_MARKER="$BRAIN_DIR/.verify-gate-agseen-$SESSION_ID"

# Safety valve: max 2 blocks per session to prevent infinite loops.
BLOCK_COUNT=0
[ -f "$MARKER" ] && BLOCK_COUNT=$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')
BLOCK_COUNT=${BLOCK_COUNT:-0}
if [ "$BLOCK_COUNT" -ge 2 ]; then
  exit 0
fi

# Check if code was modified (Write, Edit, or MultiEdit tool calls). Keep the
# FULL distinct changed-file set, not just the first hit — the block reason names
# what actually changed, and the critic offer keys on its size.
CHANGED_FILES=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
  | .input.file_path // ""
  | select(. != "")
  | select((endswith(".md") or endswith(".markdown") or endswith(".txt") or test("(^|/)docs/")) | not)
' "$TRANSCRIPT" 2>/dev/null | tr -d '\r' | sort -u)
CODE_MODIFIED=$(printf '%s\n' "$CHANGED_FILES" | head -1)
CHANGED_N=0
[ -n "$CHANGED_FILES" ] && CHANGED_N=$(printf '%s\n' "$CHANGED_FILES" | grep -c .)

if [ -z "$CODE_MODIFIED" ]; then
  rm -f "$MARKER" "$AG_MARKER" 2>/dev/null
  exit 0
fi

# Discover the project's EXACT verify command from cheap cwd probes, so the
# block says "run THIS" instead of a generic nag. NAMING ONLY — auto-running from a
# Stop hook was review-killed (blocks the turn for minutes; breaks the fail-open
# invariant). If/when the auto-team pinned-command resolver lands, reuse it here —
# do NOT grow these probes into a second resolver (single-source discipline).
VERIFY_CMD=""
CWD_DIR=$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
if [ -n "$CWD_DIR" ] && [ -d "$CWD_DIR" ]; then
  if [ -f "$CWD_DIR/tests/run-all.sh" ]; then
    VERIFY_CMD="bash tests/run-all.sh"
  elif [ -f "$CWD_DIR/package.json" ] && jq -e '.scripts.test // empty' "$CWD_DIR/package.json" >/dev/null 2>&1; then
    VERIFY_CMD="npm test"
  elif [ -f "$CWD_DIR/Makefile" ] && grep -qE '^test:' "$CWD_DIR/Makefile" 2>/dev/null; then
    VERIFY_CMD="make test"
  fi
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

# Anti-gaming slice: verification evidence is SUSPECT when
# the same session DELETED a test file — the cheapest reward-hack in the catalog
# (delete the failing test, run the now-green suite, claim verified). TDD test EDITS
# are normal and never flagged; only rm / git rm of a test-shaped path. One pointed
# block through the same 2-block valve. Kill switch: SB_VERIFY_ANTIGAME=off.
# BSD-safe patterns only: [[:space:]] classes, no \b/\s/\w.
# WINDOW-scoped: scan only transcript lines a PRIOR Stop has not already scanned,
# so one historical deletion doesn't re-fire every Stop (reuses stop-extract.sh's
# `awk -v s="$LAST_LINE" 'NR>s'` slice, but keyed on AG_MARKER — see its comment).
AG_LAST=0
[ -f "$AG_MARKER" ] && AG_LAST=$(cat "$AG_MARKER" 2>/dev/null | tr -d '[:space:]')
case "$AG_LAST" in ''|*[!0-9]*) AG_LAST=0 ;; esac

TEST_RM=""
if [ "${SB_VERIFY_ANTIGAME:-on}" != "off" ]; then
  # ARGUMENT-scoped: split each command on &&/;/| into spans and flag only a span
  # whose OWN first token is rm / git rm AND that references a test-shaped path.
  # The old line-level `grep rm-line | grep test-path` false-flagged an innocent
  # `bash tests/test-x.sh && rm -rf "$TMP"` (rm's argument is $TMP, not a test).
  # jq does the split so the SAME regex engine runs on BSD and GNU (no \b/\s/\w).
  TEST_RM=$(awk -v s="$AG_LAST" 'NR>s' "$TRANSCRIPT" 2>/dev/null | jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | .input.command // ""
    | select(. != "")
    | [ split("&&|[;|]"; "")[]
        | sub("^[[:space:]]*[({][[:space:]]*"; "") | sub("^[[:space:]]+"; "")
        | select(test("^(sudo[[:space:]]+)?(git[[:space:]]+)?rm([[:space:]]|$)"))
        | select(test("(tests?/|[._-]test\\.|[._-]spec\\.|/test_[a-z0-9_]+\\.py)")) ]
    | select(length > 0)
    | .[0]
  ' 2>/dev/null | head -1)
fi

if [ -n "$VERIFY_CMDS" ] || [ -n "$SKILL_EVIDENCE" ] || [ -n "$SKILL_TOOL" ]; then
  if [ -n "$TEST_RM" ]; then
    mkdir -p "$BRAIN_DIR" 2>/dev/null
    echo "$((BLOCK_COUNT + 1))" > "$MARKER"
    # Advance the anti-game window past this deletion so it can't re-flag next Stop.
    AG_TOTAL=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]'); echo "${AG_TOTAL:-0}" > "$AG_MARKER" 2>/dev/null || true
    jq -nc --arg cmd "$TEST_RM" '{
      decision: "block",
      reason: ("Verification evidence coincides with a test-file deletion in this session: `\($cmd)`. Deleting a test and then claiming green is the cheapest way to fake verification. Re-run the FULL suite and state explicitly why removing that test is correct (obsolete behavior? coverage superseded where?) — or restore it. Suppress this check: SB_VERIFY_ANTIGAME=off.")
    }'
    exit 0
  fi
  # Critic offer: verification RAN, but rules can't judge design — on a
  # SUBSTANTIVE diff, offer the already-shipped fresh-context critic ONCE per
  # session (non-blocking systemMessage; the model/user decides). This engages the
  # judge rung on the 90% solo path without new machinery or coercion.
  # Kill switch: SB_CRITIC_OFFER=off; threshold SB_CRITIC_OFFER_MIN_FILES (3).
  if [ "${SB_CRITIC_OFFER:-on}" != "off" ]; then
    OFFER_MIN="${SB_CRITIC_OFFER_MIN_FILES:-3}"; case "$OFFER_MIN" in ''|*[!0-9]*) OFFER_MIN=3 ;; esac
    OFFER_MARKER="$BRAIN_DIR/.critic-offer-$SESSION_ID"
    if [ "$CHANGED_N" -ge "$OFFER_MIN" ] && [ ! -f "$OFFER_MARKER" ]; then
      mkdir -p "$BRAIN_DIR" 2>/dev/null
      : > "$OFFER_MARKER" 2>/dev/null
      jq -nc --arg n "$CHANGED_N" '{
        systemMessage: ("second-brain: " + $n + " source files changed and checks ran — rules verified mechanics, not design. For an independent fresh-context critique, dispatch the quality-reviewer agent (or persona_think) on the diff. Suppress: SB_CRITIC_OFFER=off.")
      }'
    fi
  fi
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

# No verification evidence found — block. Name WHAT changed and the EXACT
# command to run (discovered above), not a generic nag — deterministic backpressure.
mkdir -p "$BRAIN_DIR" 2>/dev/null
echo "$((BLOCK_COUNT + 1))" > "$MARKER"

FILES_PREVIEW=$(printf '%s\n' "$CHANGED_FILES" | head -5 | tr '\n' ' ')
CMD_LINE="run the project's checks (tests, lint, type-check)"
[ -n "$VERIFY_CMD" ] && CMD_LINE="run \`$VERIFY_CMD\` (discovered in this project)"
jq -nc --arg n "$CHANGED_N" --arg files "$FILES_PREVIEW" --arg cmd "$CMD_LINE" '{
  decision: "block",
  reason: ("Code was modified (" + $n + " file(s): " + $files + "…) but no verification ran. Before completing: " + $cmd + ", then invoke relevant review skills (/review, /security-review, /simplify). Evidence before assertions.")
}'
