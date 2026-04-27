#!/bin/bash
# Regression tests for critical plugin bugs.
# Each test simulates a hook invocation and verifies the output/side effects.
#
# Covers:
#   1. /clear creates .pending-reflection.json with trigger=clear
#   2. Stop creates .pending-reflection.json with trigger=stop
#   3. pre-compact creates reflection with trigger=pre-compact
#   4. pre-compact output doesn't reference episodic-memory
#   5. session-load output doesn't reference episodic-memory
#   6. session-load output doesn't duplicate brain file loading
#   7. pre-compact trigger doesn't cause transcript review in session-load
#   8. lib.sh shared functions parse input correctly
#   9. lib.sh transcript resolution fallback works
#  10. lib.sh skips sessions with < 3 user turns
#  11. session-load references reflection-protocol.md instead of inline protocol
#
# Usage: bash tests/test-hooks-regression.sh

set -u

for cmd in jq mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}"
SANDBOX=$(mktemp -d "$TMPDIR_BASE/second-brain-regression.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

# Create a minimal transcript with N user turns
make_transcript() {
  local n="${1:-5}" path="$2"
  for i in $(seq 1 "$n"); do
    echo '{"type":"user","message":{"role":"user","content":"test message '$i'"}}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply '$i'"}]}}'
  done > "$path"
}

# Create fake brain dir with required files
setup_brain() {
  local brain="$SANDBOX/brain"
  rm -rf "$brain"
  mkdir -p "$brain"
  echo '{"auto_improve": false}' > "$brain/config.json"
  touch "$brain/persona.md" "$brain/quality-rules.md" "$brain/learnings.md"
  echo "$brain"
}

assert_pass() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

assert_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
  [ -n "${2:-}" ] && echo "        $2"
}

echo "test-hooks-regression.sh"
echo "========================"

# --- Test 1: /clear creates pending reflection with trigger=clear ---
echo ""
echo "1. /clear creates pending reflection"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript.jsonl"
make_transcript 5 "$TRANSCRIPT"
INPUT=$(jq -nc --arg s "test-session-1" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
echo "$INPUT" | HOME="$SANDBOX" BRAIN_DIR="$BRAIN" bash -c "
  export HOME='$SANDBOX'
  mkdir -p '$SANDBOX/.second-brain'
  ln -sfn '$BRAIN' '$SANDBOX/.second-brain' 2>/dev/null || cp -r '$BRAIN/.' '$SANDBOX/.second-brain/'
  echo '$INPUT' | bash '$REPO_ROOT/scripts/pre-clear.sh'
"
if [ -f "$SANDBOX/.second-brain/.pending-reflection.json" ]; then
  TRIGGER=$(jq -r '.trigger' "$SANDBOX/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ "$TRIGGER" = "clear" ]; then
    assert_pass "trigger=clear in pending reflection"
  else
    assert_fail "trigger should be 'clear', got '$TRIGGER'"
  fi
  TP=$(jq -r '.transcript_path' "$SANDBOX/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ "$TP" = "$TRANSCRIPT" ]; then
    assert_pass "transcript_path preserved"
  else
    assert_fail "transcript_path should be '$TRANSCRIPT', got '$TP'"
  fi
else
  assert_fail "pending reflection not created by pre-clear.sh"
fi

# --- Test 2: Stop creates pending reflection with trigger=stop ---
echo ""
echo "2. Stop creates pending reflection"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript2.jsonl"
make_transcript 5 "$TRANSCRIPT"
INPUT=$(jq -nc --arg s "test-session-2" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
if [ -f "$SANDBOX/.second-brain/.pending-reflection.json" ]; then
  TRIGGER=$(jq -r '.trigger' "$SANDBOX/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ "$TRIGGER" = "stop" ]; then
    assert_pass "trigger=stop in pending reflection"
  else
    assert_fail "trigger should be 'stop', got '$TRIGGER'"
  fi
else
  assert_fail "pending reflection not created by extract-learnings.sh"
fi

# --- Test 3: pre-compact creates reflection with trigger=pre-compact ---
echo ""
echo "3. pre-compact creates pending reflection"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript3.jsonl"
make_transcript 5 "$TRANSCRIPT"
INPUT=$(jq -nc --arg s "test-session-3" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/pre-compact.sh" > "$SANDBOX/pre-compact-out.txt" 2>&1
)
if [ -f "$SANDBOX/.second-brain/.pending-reflection.json" ]; then
  TRIGGER=$(jq -r '.trigger' "$SANDBOX/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ "$TRIGGER" = "pre-compact" ]; then
    assert_pass "trigger=pre-compact in pending reflection"
  else
    assert_fail "trigger should be 'pre-compact', got '$TRIGGER'"
  fi
else
  assert_fail "pending reflection not created by pre-compact.sh"
fi

# --- Test 4: pre-compact output doesn't reference episodic-memory ---
echo ""
echo "4. pre-compact output has no episodic-memory reference"
if grep -qi "episodic.memory" "$SANDBOX/pre-compact-out.txt" 2>/dev/null; then
  assert_fail "pre-compact.sh output references episodic-memory"
else
  assert_pass "no episodic-memory reference in pre-compact output"
fi

# --- Test 5: session-load output doesn't reference episodic-memory ---
echo ""
echo "5. session-load output has no episodic-memory reference"
BRAIN=$(setup_brain)
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-out.txt" 2>&1
)
if grep -qi "episodic.memory" "$SANDBOX/session-load-out.txt" 2>/dev/null; then
  assert_fail "session-load.sh output references episodic-memory"
  grep -i "episodic" "$SANDBOX/session-load-out.txt" | head -3 | sed 's/^/        /'
else
  assert_pass "no episodic-memory reference in session-load output"
fi

# --- Test 6: session-load doesn't duplicate brain file loading ---
echo ""
echo "6. session-load doesn't duplicate file paths"
PERSONA_COUNT=$(grep -c "persona.md" "$SANDBOX/session-load-out.txt" 2>/dev/null)
if [ "$PERSONA_COUNT" -le 1 ]; then
  assert_pass "persona.md mentioned at most once"
else
  assert_fail "persona.md mentioned $PERSONA_COUNT times (duplication)"
fi
QR_COUNT=$(grep -c "quality-rules.md" "$SANDBOX/session-load-out.txt" 2>/dev/null)
if [ "$QR_COUNT" -le 1 ]; then
  assert_pass "quality-rules.md mentioned at most once"
else
  assert_fail "quality-rules.md mentioned $QR_COUNT times (duplication)"
fi

# --- Test 7: pre-compact trigger skips transcript review in session-load ---
echo ""
echo "7. pre-compact trigger doesn't cause transcript review"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript7.jsonl"
make_transcript 10 "$TRANSCRIPT"
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  # Simulate a pre-compact pending reflection
  jq -n --arg tp "$TRANSCRIPT" '{trigger:"pre-compact",transcript_path:$tp,priority:"normal",friction_count:0,user_turns:10}' \
    > "$SANDBOX/.second-brain/.pending-reflection.json"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-compact.txt" 2>&1
)
if grep -q "SESSION REVIEW" "$SANDBOX/session-load-compact.txt" 2>/dev/null; then
  assert_fail "session-load emits SESSION REVIEW for pre-compact trigger (compaction loop risk)"
else
  assert_pass "no SESSION REVIEW for pre-compact trigger"
fi

# --- Test 8: lib.sh parses input correctly ---
echo ""
echo "8. lib.sh input parsing"
RESULT=$(echo '{"session_id":"abc-123","transcript_path":"/tmp/test.jsonl"}' | bash -c "
  source '$REPO_ROOT/scripts/lib.sh'
  sb_parse_input
  echo \"\$SB_SESSION_ID|\$SB_TRANSCRIPT_PATH\"
")
if [ "$RESULT" = "abc-123|/tmp/test.jsonl" ]; then
  assert_pass "lib.sh parses session_id and transcript_path"
else
  assert_fail "lib.sh parse mismatch: got '$RESULT'"
fi

# --- Test 9: lib.sh transcript resolution fallback ---
echo ""
echo "9. lib.sh transcript fallback to ~/.claude/sessions/"
FAKE_SESSION="$SANDBOX/.claude/sessions"
mkdir -p "$FAKE_SESSION"
echo '{}' > "$FAKE_SESSION/fallback-id.jsonl"
RESULT=$(echo '{"session_id":"fallback-id","transcript_path":""}' | bash -c "
  export HOME='$SANDBOX'
  source '$REPO_ROOT/scripts/lib.sh'
  sb_parse_input
  sb_resolve_transcript && echo 'resolved' || echo 'failed'
  echo \"\$SB_TRANSCRIPT_PATH\"
")
RESOLVED_LINE=$(echo "$RESULT" | head -1)
RESOLVED_PATH=$(echo "$RESULT" | tail -1)
if [ "$RESOLVED_LINE" = "resolved" ] && [ "$RESOLVED_PATH" = "$FAKE_SESSION/fallback-id.jsonl" ]; then
  assert_pass "transcript resolved via session_id fallback"
else
  assert_fail "fallback failed: $RESULT"
fi

# --- Test 10: lib.sh skips sessions with fewer than 3 turns ---
echo ""
echo "10. lib.sh enforces minimum turn threshold"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/short-transcript.jsonl"
make_transcript 2 "$TRANSCRIPT"
RESULT=$(echo $(jq -nc --arg tp "$TRANSCRIPT" '{session_id:"short",transcript_path:$tp}') | bash -c "
  export HOME='$SANDBOX'
  mkdir -p '$SANDBOX/.second-brain'
  cp -r '$BRAIN/.' '$SANDBOX/.second-brain/'
  source '$REPO_ROOT/scripts/lib.sh'
  sb_collect_session_data 3 && echo 'collected' || echo 'skipped'
")
if [ "$RESULT" = "skipped" ]; then
  assert_pass "sessions with < 3 turns are skipped"
else
  assert_fail "should skip short sessions, got: $RESULT"
fi

# --- Test 11: session-load references reflection-protocol.md ---
echo ""
echo "11. session-load references reflection-protocol.md file"
BRAIN=$(setup_brain)
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-ref.txt" 2>&1
)
if grep -q "reflection-protocol.md" "$SANDBOX/session-load-ref.txt" 2>/dev/null; then
  assert_pass "session-load references reflection-protocol.md"
else
  assert_fail "session-load should reference reflection-protocol.md"
fi
# Should NOT contain the inline protocol text
if grep -q "PROCESS LEARNINGS" "$SANDBOX/session-load-ref.txt" 2>/dev/null; then
  assert_fail "session-load still contains inline reflection protocol (should be in file)"
else
  assert_pass "inline reflection protocol removed from session-load"
fi

# --- Test 12: stop/clear trigger DOES cause transcript review ---
echo ""
echo "12. stop/clear trigger causes transcript review"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript12.jsonl"
make_transcript 10 "$TRANSCRIPT"
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  jq -n --arg tp "$TRANSCRIPT" '{trigger:"stop",transcript_path:$tp,priority:"normal",friction_count:0,user_turns:10}' \
    > "$SANDBOX/.second-brain/.pending-reflection.json"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-stop.txt" 2>&1
)
if grep -q "SESSION REVIEW" "$SANDBOX/session-load-stop.txt" 2>/dev/null; then
  assert_pass "SESSION REVIEW emitted for stop trigger"
else
  assert_fail "SESSION REVIEW missing for stop trigger"
fi

# --- Test 13: reflection JSON fields are valid ---
echo ""
echo "13. pending reflection JSON has all required fields"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript13.jsonl"
make_transcript 5 "$TRANSCRIPT"
INPUT=$(jq -nc --arg s "field-test" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
REFLECTION="$SANDBOX/.second-brain/.pending-reflection.json"
if [ -f "$REFLECTION" ]; then
  MISSING=""
  for field in session_id date user_turns friction_count positive_signals first_try_success drift_count priority suggest_plugin_improve trigger transcript_path; do
    # Use 'has' instead of '//' — jq's alternative operator treats false/null/0 as falsy
    HAS=$(jq "has(\"$field\")" "$REFLECTION" 2>/dev/null)
    if [ "$HAS" != "true" ]; then
      MISSING="$MISSING $field"
    fi
  done
  if [ -z "$MISSING" ]; then
    assert_pass "all required fields present in reflection JSON"
  else
    assert_fail "missing fields:$MISSING"
  fi
else
  assert_fail "reflection file not created"
fi

# --- Test 14: high-priority reflection surfaces banner ---
echo ""
echo "14. high-priority reflection surfaces urgent banner"
BRAIN=$(setup_brain)
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  jq -n '{trigger:"stop",priority:"high",friction_count:7,drift_count:4,user_turns:15,transcript_path:""}' \
    > "$SANDBOX/.second-brain/.pending-reflection.json"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-high.txt" 2>&1
)
if grep -q "HIGH-PRIORITY" "$SANDBOX/session-load-high.txt" 2>/dev/null; then
  assert_pass "high-priority banner emitted"
else
  assert_fail "high-priority banner missing for priority=high reflection"
fi

# --- Test 15: friction counts are accurate in reflection ---
echo ""
echo "15. friction counts match actual friction signals"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript15.jsonl"
make_transcript 5 "$TRANSCRIPT"
# Write friction signals for this session
mkdir -p "$SANDBOX/.second-brain"
cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
cat > "$SANDBOX/.second-brain/friction-log.jsonl" << 'FLOG'
{"timestamp":"2026-04-27T10:00:00Z","session_id":"friction-test","type":"retry","direction":"negative","prompt":"try again"}
{"timestamp":"2026-04-27T10:01:00Z","session_id":"friction-test","type":"rejection","direction":"negative","prompt":"no thats wrong"}
{"timestamp":"2026-04-27T10:02:00Z","session_id":"friction-test","type":"praise","direction":"positive","prompt":"perfect"}
{"timestamp":"2026-04-27T10:03:00Z","session_id":"other-session","type":"retry","direction":"negative","prompt":"not this session"}
FLOG
INPUT=$(jq -nc --arg s "friction-test" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
REFLECTION="$SANDBOX/.second-brain/.pending-reflection.json"
if [ -f "$REFLECTION" ]; then
  FC=$(jq '.friction_count' "$REFLECTION" 2>/dev/null)
  PS=$(jq '.positive_signals' "$REFLECTION" 2>/dev/null)
  if [ "$FC" = "2" ]; then
    assert_pass "friction_count=2 (only negative signals from this session)"
  else
    assert_fail "friction_count should be 2, got $FC"
  fi
  if [ "$PS" = "1" ]; then
    assert_pass "positive_signals=1 (only positive signals from this session)"
  else
    assert_fail "positive_signals should be 1, got $PS"
  fi
  FTS=$(jq '.first_try_success' "$REFLECTION" 2>/dev/null)
  if [ "$FTS" = "false" ]; then
    assert_pass "first_try_success=false when friction exists"
  else
    assert_fail "first_try_success should be false when friction > 0, got $FTS"
  fi
else
  assert_fail "reflection file not created"
fi

# --- Test 16: zero-friction session sets first_try_success=true ---
echo ""
echo "16. zero-friction session = first_try_success"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript16.jsonl"
make_transcript 5 "$TRANSCRIPT"
mkdir -p "$SANDBOX/.second-brain"
cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
# No friction log at all
rm -f "$SANDBOX/.second-brain/friction-log.jsonl"
INPUT=$(jq -nc --arg s "clean-session" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
REFLECTION="$SANDBOX/.second-brain/.pending-reflection.json"
if [ -f "$REFLECTION" ]; then
  FTS=$(jq '.first_try_success' "$REFLECTION" 2>/dev/null)
  FC=$(jq '.friction_count' "$REFLECTION" 2>/dev/null)
  if [ "$FTS" = "true" ] && [ "$FC" = "0" ]; then
    assert_pass "zero friction → first_try_success=true"
  else
    assert_fail "expected first_try_success=true, friction=0; got fts=$FTS fc=$FC"
  fi
else
  assert_fail "reflection file not created for zero-friction session"
fi

# --- Test 17: corrupt transcript doesn't crash scripts ---
echo ""
echo "17. corrupt transcript handled gracefully"
BRAIN=$(setup_brain)
CORRUPT="$SANDBOX/corrupt.jsonl"
echo "this is not json" > "$CORRUPT"
mkdir -p "$SANDBOX/.second-brain"
cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
INPUT=$(jq -nc --arg s "corrupt-test" --arg tp "$CORRUPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  assert_pass "extract-learnings.sh exits cleanly on corrupt transcript"
else
  assert_fail "extract-learnings.sh crashed on corrupt transcript (exit=$EXIT_CODE)"
fi

# --- Test 18: missing transcript path exits gracefully ---
echo ""
echo "18. missing transcript path exits gracefully"
BRAIN=$(setup_brain)
mkdir -p "$SANDBOX/.second-brain"
cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
rm -f "$SANDBOX/.second-brain/.pending-reflection.json"
INPUT=$(jq -nc '{session_id:"no-path",transcript_path:"/nonexistent/file.jsonl"}')
(
  export HOME="$SANDBOX"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/pre-clear.sh"
)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  assert_pass "pre-clear.sh exits cleanly when transcript missing"
else
  assert_fail "pre-clear.sh crashed when transcript missing (exit=$EXIT_CODE)"
fi
# Should NOT have created a reflection
if [ ! -f "$SANDBOX/.second-brain/.pending-reflection.json" ]; then
  assert_pass "no reflection created when no transcript available"
else
  assert_fail "reflection created despite missing transcript"
fi

# --- Test 19: drift count affects priority ---
echo ""
echo "19. high drift count triggers high priority"
BRAIN=$(setup_brain)
TRANSCRIPT="$SANDBOX/transcript19.jsonl"
make_transcript 5 "$TRANSCRIPT"
mkdir -p "$SANDBOX/.second-brain"
cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
# Write drift signals exceeding threshold (default 3)
for i in 1 2 3 4; do
  jq -nc --arg s "drift-session" '{timestamp:"2026-04-27T10:00:00Z",session_id:$s,signal_id:"test",claim:"test",excerpt:"test"}'
done > "$SANDBOX/.second-brain/drift-log.jsonl"
INPUT=$(jq -nc --arg s "drift-session" --arg tp "$TRANSCRIPT" '{session_id:$s, transcript_path:$tp}')
(
  export HOME="$SANDBOX"
  echo "$INPUT" | bash "$REPO_ROOT/scripts/extract-learnings.sh"
)
REFLECTION="$SANDBOX/.second-brain/.pending-reflection.json"
if [ -f "$REFLECTION" ]; then
  PRIORITY=$(jq -r '.priority' "$REFLECTION" 2>/dev/null)
  DC=$(jq '.drift_count' "$REFLECTION" 2>/dev/null)
  if [ "$PRIORITY" = "high" ] && [ "$DC" = "4" ]; then
    assert_pass "drift_count=4 → priority=high"
  else
    assert_fail "expected priority=high drift=4, got priority=$PRIORITY drift=$DC"
  fi
else
  assert_fail "reflection not created for drift test"
fi

# --- Test 20: session-load output stays under token budget ---
echo ""
echo "20. session-load output stays under 3000 chars (no pending reflection)"
BRAIN=$(setup_brain)
(
  export HOME="$SANDBOX"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  mkdir -p "$SANDBOX/.second-brain"
  cp -r "$BRAIN/." "$SANDBOX/.second-brain/"
  rm -f "$SANDBOX/.second-brain/.pending-reflection.json"
  echo '{}' | bash "$REPO_ROOT/scripts/session-load.sh" > "$SANDBOX/session-load-budget.txt" 2>&1
)
CHARS=$(wc -c < "$SANDBOX/session-load-budget.txt" | tr -d ' ')
if [ "$CHARS" -lt 3000 ]; then
  assert_pass "session-load output = ${CHARS} chars (under 3000)"
else
  assert_fail "session-load output = ${CHARS} chars (over budget, was ~2800 before)"
fi

echo ""
echo "========================"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
