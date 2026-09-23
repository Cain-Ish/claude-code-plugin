#!/bin/bash
# Tests for stop-verify-gate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
GATE="$SCRIPT_DIR/stop-verify-gate.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR"

PASS=0
FAIL=0

assert_approve() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label (approve / no output)"
  else
    local decision
    decision=$(printf '%s' "$output" | jq -r '.decision // empty' 2>/dev/null)
    if [ "$decision" = "block" ]; then
      FAIL=$((FAIL + 1))
      echo "  FAIL: $label — expected approve, got block"
    else
      PASS=$((PASS + 1))
      echo "  PASS: $label (approve)"
    fi
  fi
}

assert_block() {
  local label="$1" output="$2"
  local decision
  decision=$(printf '%s' "$output" | jq -r '.decision // empty' 2>/dev/null)
  if [ "$decision" = "block" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label (block)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected block, got: $output"
  fi
}

# --- Helpers to build transcript fixtures ---
mk_transcript() {
  local file="$SANDBOX/transcript-$RANDOM.jsonl"
  echo "$file"
}

add_qa_turn() {
  local file="$1"
  echo '{"type":"user","message":{"role":"user","content":"what is X?"}}' >> "$file"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"X is..."}]}}' >> "$file"
}

add_edit_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/foo.ts","old_string":"a","new_string":"b"}}]}}' >> "$file"
}

add_write_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"src/new.ts","content":"hello"}}]}}' >> "$file"
}

add_md_write_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"docs/specs/foo.md","content":"# hi"}}]}}' >> "$file"
}

add_test_run() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run test"}}]}}' >> "$file"
}

add_lint_run() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npx eslint src/"}}]}}' >> "$file"
}

add_review_skill() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"review"}}]}}' >> "$file"
}

mk_input() {
  local transcript="$1"
  jq -nc --arg tp "$transcript" --arg sid "test-$$-$RANDOM" '{transcript_path:$tp, session_id:$sid, cwd:"/tmp"}'
}

echo "=== stop-verify-gate.sh tests ==="

# Test 1: Empty stdin → approve
OUT=$(echo "" | bash "$GATE" 2>/dev/null || true)
assert_approve "empty stdin" "$OUT"

# Test 2: Missing transcript → approve
OUT=$(echo '{"transcript_path":"/nonexistent","session_id":"s1"}' | bash "$GATE" 2>/dev/null || true)
assert_approve "missing transcript" "$OUT"

# Test 3: Q&A session (no code modification) → approve
T=$(mk_transcript)
add_qa_turn "$T"
add_qa_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "Q&A only session" "$OUT"

# Test 4: Code modified + no verification → block
T=$(mk_transcript)
add_qa_turn "$T"
add_edit_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "code modified, no verification" "$OUT"

# Test 5: Code modified + test ran → approve
T=$(mk_transcript)
add_edit_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "code modified + tests ran" "$OUT"

# Test 6: Code modified + lint ran → approve
T=$(mk_transcript)
add_write_turn "$T"
add_lint_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "code modified + lint ran" "$OUT"

# Test 7: Code modified + review skill → approve
T=$(mk_transcript)
add_edit_turn "$T"
add_review_skill "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "code modified + review skill" "$OUT"

# Test 8: Safety valve — block count >= 2 → approve
T=$(mk_transcript)
add_edit_turn "$T"
INPUT=$(mk_input "$T")
SID=$(printf '%s' "$INPUT" | jq -r '.session_id')
echo "2" > "$BRAIN_DIR/.verify-gate-blocks-$SID"
OUT=$(printf '%s' "$INPUT" | bash "$GATE" 2>/dev/null || true)
assert_approve "safety valve (2 blocks already)" "$OUT"

# Test 9: Kill switch → approve
T=$(mk_transcript)
add_edit_turn "$T"
OUT=$(mk_input "$T" | SB_VERIFY_GATE=off bash "$GATE" 2>/dev/null || true)
assert_approve "kill switch off" "$OUT"

# Test 10: Doc-only edit (.md) + no verification → approve (file-type filter)
T=$(mk_transcript)
add_qa_turn "$T"
add_md_write_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "doc-only .md write, no verification" "$OUT"

# Test 11: Mixed .md + code (.ts) + no verification → block (code present)
T=$(mk_transcript)
add_md_write_turn "$T"
add_edit_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "mixed md + code, no verification" "$OUT"

# --- Anti-gaming slice (P0.5): test deletion + verification claim ---
add_test_rm_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git rm tests/broken.test.ts"}}]}}' >> "$file"
}
add_tmp_rm_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf \"$TMPDIR/scratch-9\""}}]}}' >> "$file"
}
add_test_edit_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"tests/broken.test.ts","old_string":"a","new_string":"b"}}]}}' >> "$file"
}
# A single &&-chain that runs a test file AND rm's a NON-test path ($TMP). The test
# path and the rm co-occur on one line but the rm's OWN argument is not a test —
# argument-scoped matching must NOT flag this (the live false-positive class).
add_probe_rm_chain_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"bash tests/test-foo.sh --verbose && rm -rf \"$TMP\""}}]}}' >> "$file"
}
# A genuine test deletion whose OWN span carries the test path, on an &&-chain —
# splitting must still surface it (true positive not lost to the split).
add_test_rm_chain_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"rm tests/broken.test.ts && echo removed"}}]}}' >> "$file"
}

# Test 12: code modified + tests ran BUT a test file was rm'd → pointed block.
T=$(mk_transcript)
add_edit_turn "$T"
add_test_rm_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "verification claim + test-file deletion" "$OUT"
printf '%s' "$OUT" | grep -q 'test-file deletion' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block reason should name the deletion"; }

# Test 13: same session with SB_VERIFY_ANTIGAME=off → approve (kill switch).
T=$(mk_transcript)
add_edit_turn "$T"
add_test_rm_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | SB_VERIFY_ANTIGAME=off bash "$GATE" 2>/dev/null || true)
assert_approve "anti-game kill switch off" "$OUT"

# Test 14: ordinary tmp-dir rm (no test-shaped path) + tests ran → approve.
T=$(mk_transcript)
add_edit_turn "$T"
add_tmp_rm_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "non-test rm not flagged" "$OUT"

# Test 15: TDD — test file EDITED (not deleted) + tests ran → approve.
T=$(mk_transcript)
add_edit_turn "$T"
add_test_edit_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "TDD test edit not flagged" "$OUT"

# --- P2.1 deterministic backpressure + P2.2 critic offer ---
mk_input_cwd() { # transcript cwd [sid]
  jq -nc --arg tp "$1" --arg cwd "$2" --arg sid "${3:-test-$$-$RANDOM}" \
    '{transcript_path:$tp, session_id:$sid, cwd:$cwd}'
}
add_edit_of() { # file path
  local file="$1" p="$2"
  jq -nc --arg p "$p" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Edit",input:{file_path:$p,old_string:"a",new_string:"b"}}]}}' >> "$file"
}

# Test 16: block names the discovered verify command + the changed files.
PROJ=$(mktemp -d); mkdir -p "$PROJ/tests"; printf '#!/bin/bash\n' > "$PROJ/tests/run-all.sh"
T=$(mk_transcript)
add_edit_turn "$T"
OUT=$(mk_input_cwd "$T" "$PROJ" | bash "$GATE" 2>/dev/null || true)
assert_block "no-verification block (P2.1)" "$OUT"
printf '%s' "$OUT" | grep -q 'bash tests/run-all.sh' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block should name the discovered command"; }
printf '%s' "$OUT" | grep -q 'src/foo.ts' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block should name the changed file"; }
rm -rf "$PROJ"

# Test 17: substantive verified diff → ONE critic-offer systemMessage, once per session.
T=$(mk_transcript)
add_edit_of "$T" "src/a.ts"; add_edit_of "$T" "src/b.ts"; add_edit_of "$T" "src/c.ts"
add_test_run "$T"
IN=$(mk_input_cwd "$T" "/tmp" "critic-sid-1")
OUT=$(printf '%s' "$IN" | bash "$GATE" 2>/dev/null || true)
[ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.systemMessage | test("persona_think")' >/dev/null \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: substantive verified diff should offer the critic (got: $OUT)"; }
OUT2=$(printf '%s' "$IN" | bash "$GATE" 2>/dev/null || true)
[ -z "$OUT2" ] || { FAIL=$((FAIL + 1)); echo "  FAIL: critic offer must fire once per session (got: $OUT2)"; }
PASS=$((PASS + 1)); echo "  PASS: critic offer fires once on a substantive verified diff"

# Test 18: small diff (1 file) + verified → no offer; kill switch also silences.
T=$(mk_transcript)
add_edit_turn "$T"
add_test_run "$T"
OUT=$(mk_input_cwd "$T" "/tmp" "critic-sid-2" | bash "$GATE" 2>/dev/null || true)
[ -z "$OUT" ] || { FAIL=$((FAIL + 1)); echo "  FAIL: small diff must not trigger the offer (got: $OUT)"; }
T=$(mk_transcript)
add_edit_of "$T" "src/a.ts"; add_edit_of "$T" "src/b.ts"; add_edit_of "$T" "src/c.ts"
add_test_run "$T"
OUT=$(mk_input_cwd "$T" "/tmp" "critic-sid-3" | SB_CRITIC_OFFER=off bash "$GATE" 2>/dev/null || true)
[ -z "$OUT" ] || { FAIL=$((FAIL + 1)); echo "  FAIL: SB_CRITIC_OFFER=off must silence the offer (got: $OUT)"; }
PASS=$((PASS + 1)); echo "  PASS: no offer on small diffs; kill switch honored"

# --- P0.5 gate-precision regressions (argument-scoped + windowed anti-game) ---

# Test 19 (precision-i): probe payload — `bash tests/test-foo.sh && rm -rf "$TMP"`
# on ONE &&-chain must NOT flag. The test path and rm co-occur on the line, but the
# rm's own argument is $TMP, not a test file. This is the live false-positive class.
T=$(mk_transcript)
add_edit_turn "$T"
add_probe_rm_chain_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "probe payload (test-path + rm on one chain) not flagged" "$OUT"

# Test 20 (precision-ii): a real deletion whose OWN span carries the test path —
# `rm tests/broken.test.ts && echo removed` — must STILL flag after the split.
T=$(mk_transcript)
add_edit_turn "$T"
add_test_rm_chain_turn "$T"
add_test_run "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "true test deletion on an &&-chain still flags" "$OUT"
printf '%s' "$OUT" | grep -q 'test-file deletion' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block reason should name the deletion"; }

# Test 21 (window): a deletion BEHIND the anti-game marker must not re-flag on a
# later Stop. Without the window the historical rm re-fired every Stop and burned
# both slots of the 2-block valve. The marker records how far a prior Stop scanned.
T=$(mk_transcript)
add_edit_turn "$T"          # line 1
add_test_rm_turn "$T"       # line 2: git rm tests/broken.test.ts
add_test_run "$T"           # line 3
INPUT=$(mk_input "$T")
SID=$(printf '%s' "$INPUT" | jq -r '.session_id')
echo "3" > "$BRAIN_DIR/.verify-gate-agseen-$SID"   # prior Stop already scanned all 3 lines
OUT=$(printf '%s' "$INPUT" | bash "$GATE" 2>/dev/null || true)
assert_approve "deletion behind anti-game marker does not re-flag" "$OUT"

# --- Session Intent Spine (Gate C): the block quotes the frozen goal + reached phase ---

# Test 22: memo goal + phase present → block reason quotes both (closes the WHY loop).
T=$(mk_transcript)
add_edit_turn "$T"
INPUT=$(mk_input "$T")
SID=$(printf '%s' "$INPUT" | jq -r '.session_id')
mkdir -p "$BRAIN_DIR/.injected"
jq -nc '{goal:"ship the intent spine because sessions forget why"}' > "$BRAIN_DIR/.injected/$SID.json"
printf 'implement' > "$BRAIN_DIR/.injected/$SID.phase"
OUT=$(printf '%s' "$INPUT" | bash "$GATE" 2>/dev/null || true)
assert_block "spine: block with frozen goal on record" "$OUT"
printf '%s' "$OUT" | jq -r '.reason // ""' | grep -q 'Session goal: "ship the intent spine because sessions forget why"' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block reason should quote the frozen goal (got: $OUT)"; }
printf '%s' "$OUT" | grep -q 'phase reached: implement' \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: block reason should name the reached phase (got: $OUT)"; }

# Test 23: SB_INTENT_SPINE=off → same setup, reason carries NO goal quote (kill switch first).
T=$(mk_transcript)
add_edit_turn "$T"
INPUT=$(mk_input "$T")
SID=$(printf '%s' "$INPUT" | jq -r '.session_id')
jq -nc '{goal:"ship the intent spine because sessions forget why"}' > "$BRAIN_DIR/.injected/$SID.json"
printf 'implement' > "$BRAIN_DIR/.injected/$SID.phase"
OUT=$(printf '%s' "$INPUT" | SB_INTENT_SPINE=off bash "$GATE" 2>/dev/null || true)
assert_block "spine off: still blocks (gate unchanged)" "$OUT"
printf '%s' "$OUT" | grep -q 'Session goal' \
  && { FAIL=$((FAIL + 1)); echo "  FAIL: SB_INTENT_SPINE=off must not quote the goal (got: $OUT)"; }

# Test 24: no memo on disk → reason unchanged (fail-open: absent state never mutates the block).
T=$(mk_transcript)
add_edit_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "spine: no memo → plain block" "$OUT"
printf '%s' "$OUT" | grep -q 'Session goal' \
  && { FAIL=$((FAIL + 1)); echo "  FAIL: goal quote must not appear without a frozen goal (got: $OUT)"; }

# --- D181: verification evidence must come AFTER the last edit and reflect a
# real (non-error) result, not just matching command text anywhere in the
# transcript.
add_test_run_with_id() {  # file id command
  local file="$1" id="$2" cmd="$3"
  jq -nc --arg id "$id" --arg cmd "$cmd" \
    '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"Bash",input:{command:$cmd}}]}}' >> "$file"
}
add_bash_result() {  # file id is_error
  local file="$1" id="$2" err="$3"
  jq -nc --arg id "$id" --argjson err "$err" \
    '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:$err,content:"output"}]}}' >> "$file"
}

# Test 25: a test run BEFORE the edit must not count — only evidence AFTER the
# last edit satisfies the gate.
T=$(mk_transcript)
add_test_run "$T"    # verification runs FIRST
add_edit_turn "$T"    # code changes AFTER — nothing verified it
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "D181: verification BEFORE the last edit does not count as evidence" "$OUT"

# Test 26: a test run AFTER the edit whose OWN result reports is_error:true
# must not count as verification evidence (the run failed).
T=$(mk_transcript)
add_edit_turn "$T"
add_test_run_with_id "$T" "tu-fail-1" "npm run test"
add_bash_result "$T" "tu-fail-1" true
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "D181: a FAILED test run (is_error:true) does not count as evidence" "$OUT"

# Test 27 (positive control): a test run AFTER the edit whose result reports
# is_error:false counts as evidence — the exit-status check does not just
# always block.
T=$(mk_transcript)
add_edit_turn "$T"
add_test_run_with_id "$T" "tu-ok-1" "npm run test"
add_bash_result "$T" "tu-ok-1" false
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "D181: a successful test run (is_error:false) still counts as evidence" "$OUT"


# --- ANTI-GAME IS UNCONDITIONAL: every shape below MUST block -----------------
#
# HISTORY — read this before "fixing" the false positive at the bottom.
# Between 2026-09-10 and 2026-09-11 a suppression filter was built here to stop
# the gate flagging a scratch test-shaped file the session itself created and
# deleted. Four adversarial review rounds tried four different predicates and
# every one of them was defeated, each bypass reproduced end-to-end against the
# real script:
#
#   1. index-only (`git ls-files --error-unmatch`)  — `git rm` empties the index
#      mid-command, so the check went silent during the very act it guards.
#   2. current HEAD (`git cat-file -e HEAD:<path>`) — `git rm && git commit`
#      leaves the blob in neither index nor HEAD; a backslash path
#      (`tests\x.test.ts`) missed cat-file's tree walker entirely; a quoted path
#      with a space mis-tokenized into a path that never existed.
#   3. reachable history (`git log -1 -- <path>`)   — `git log` without --all
#      walks only the checked-out ref, so a branch switch, a `reset --hard` past
#      the deletion, or a detached HEAD erased the evidence. Reflog-only history
#      defeats --all too.
#   4. transcript provenance (a `Write` of the path earlier in the window) —
#      `Write` does NOT require the file to be absent. Stubbing a real, covered
#      test and then deleting it produced an identical creation record, which is
#      precisely the reward hack this check exists to catch, reachable with no
#      adversarial intent at all. It was also quadratic: measured 2s at 30
#      scratch write/delete pairs, 5s at 80, 11s at 150 — and past the 10s hook
#      timeout the hook is killed and the ENTIRE gate fails open, not just this
#      check.
#
# The filter prevented exactly one spurious block, against a gate that already
# caps at 2 blocks per session and ships SB_VERIFY_ANTIGAME=off. Negative value.
# It was reverted. These tests pin every defeated shape so a future attempt has
# to clear them all before it can ship.
mk_ag_repo() {  # a repo with a real, committed, covered test file
  local r; r=$(mktemp -d)
  git -C "$r" init -q -b main 2>/dev/null
  git -C "$r" config user.email "t@example.com"
  git -C "$r" config user.name "t"
  mkdir -p "$r/tests" "$r/my tests"
  printf 'test("real",()=>{})\n' > "$r/tests/real.test.ts"
  printf 'test("sp",()=>{})\n'   > "$r/my tests/spaced.test.ts"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q -m init >/dev/null 2>&1
  echo "$r"
}
add_bash_of() {  # file command
  jq -nc --arg c "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >> "$1"
}
add_write_path() {  # file path
  jq -nc --arg p "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Write",input:{file_path:$p,content:"// stub"}}]}}' >> "$1"
}
# every case is "edited code + <deletion shape> + tests ran" — i.e. a verification
# claim standing on a test deletion, which is the whole point of the check.
ag_case() {  # label cwd setup_fn_or_empty command [extra_turn_fn]
  local label="$1" cwd="$2" cmd="$3" pre="$4" post="$5"
  local t; t=$(mk_transcript)
  add_edit_turn "$t"
  [ -n "$pre" ] && "$pre" "$t"
  add_bash_of "$t" "$cmd"
  [ -n "$post" ] && "$post" "$t"
  add_test_run "$t"
  local out; out=$(mk_input_cwd "$t" "$cwd" | bash "$GATE" 2>/dev/null || true)
  assert_block "anti-game: $label" "$out"
}

AGR=$(mk_ag_repo)
_w_real()  { add_write_path "$1" "tests/real.test.ts"; }
_w_abs()   { add_write_path "$1" "$AGR/tests/real.test.ts"; }
_w_late()  { add_write_path "$1" "tests/real.test.ts"; }

# Round 1/2 shapes.
ag_case "plain rm of a tracked test"            "$AGR" "rm -f tests/real.test.ts"                        "" ""
ag_case "git rm (index emptied mid-command)"    "$AGR" "git rm tests/real.test.ts"                       "" ""
ag_case "git rm + commit in the same session"   "$AGR" "git rm tests/real.test.ts && git commit -m drop" "" ""
ag_case "backslash-separated path"              "$AGR" 'git rm tests\real.test.ts'                       "" ""
ag_case "quoted path containing a space"        "$AGR" 'rm -f "my tests/spaced.test.ts"'                 "" ""

# Round 3 shapes — git history rewriting must not launder a deletion.
ag_case "deletion mentioned with a reset --hard" "$AGR" "git rm tests/real.test.ts && git commit -m d && git reset --hard HEAD~1" "" ""

# Round 4 shapes — a Write of the path, in either order, is NOT an alibi.
ag_case "Write (stub) of the path, then rm"     "$AGR" "rm -f tests/real.test.ts" _w_real ""
ag_case "absolute Write of the path, then rm"   "$AGR" "rm -f tests/real.test.ts" _w_abs  ""
ag_case "rm, then Write a stub at the path"     "$AGR" "rm -f tests/real.test.ts" ""      _w_late

# A path this session genuinely created and removed is STILL flagged. This is a
# known, accepted false positive: it costs one block out of the two the gate
# allows per session, and SB_VERIFY_ANTIGAME=off disables the check outright.
# Four rounds of trying to suppress it produced four bypasses (see above), so the
# over-block is the deliberate trade. Do not "fix" this without reading that list.
ag_case "ACCEPTED FALSE POSITIVE: scratch file created then deleted" \
        "$AGR" "rm -f _rvcheck.test.ts" _w_real ""

rm -rf "$AGR"

# The kill switch and the innocent-chain case still hold under unconditional mode.
AGR2=$(mk_ag_repo)
T=$(mk_transcript)
add_edit_turn "$T"
add_bash_of "$T" "rm -f tests/real.test.ts"
add_test_run "$T"
OUT=$(mk_input_cwd "$T" "$AGR2" | SB_VERIFY_ANTIGAME=off bash "$GATE" 2>/dev/null || true)
assert_approve "anti-game: SB_VERIFY_ANTIGAME=off still disables the check" "$OUT"

T=$(mk_transcript)
add_edit_turn "$T"
add_bash_of "$T" 'bash tests/test-foo.sh --verbose && rm -rf "$TMP"'
add_test_run "$T"
OUT=$(mk_input_cwd "$T" "$AGR2" | bash "$GATE" 2>/dev/null || true)
assert_approve "anti-game: innocent chain (rm's own argument is not a test) not flagged" "$OUT"
rm -rf "$AGR2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
