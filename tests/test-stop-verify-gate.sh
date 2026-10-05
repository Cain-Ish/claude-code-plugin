#!/bin/bash
# Tests for stop-verify-gate.sh
# run-all-timeout: 240   (93 s alone on a loaded MSYS box 2026-09-30, after F8 added two ~65 KB block controls to RR-SF2)
set -euo pipefail
# pins: TMPDIR, TMP, TEMP — not SB_* (the override census ignores them). The G1 temp-dir cases
#   (g1_env_case) set one per gate call to a dir with no temp word, so the "under the hook's own
#   temp dirs" branch is the only exemption that can fire; hostile values (C:, .) go in TMP/TEMP.
# The gate takes its repo root from CLAUDE_PROJECT_DIR first (G1): an inherited value would move
# every case's root. The G1 cases set it explicitly where it is the subject.
unset CLAUDE_PROJECT_DIR

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
# mktemp, not $RANDOM: ~80 fixtures drawn from 32768 names collided in ~9% of runs,
# and a collision appended one case's records onto another's transcript. The file is
# created empty; every helper appends. The mktemp suffix also seeds the session id
# (mk_input) so per-session markers can never leak between cases either.
mk_transcript() {
  mktemp "$SANDBOX/transcript.XXXXXX"
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
  jq -nc --arg tp "$transcript" --arg sid "test-$$-${transcript##*.}" '{transcript_path:$tp, session_id:$sid, cwd:"/tmp"}'
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
  jq -nc --arg tp "$1" --arg cwd "$2" --arg sid "${3:-test-$$-${1##*.}}" \
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

# --- B6 (borrow-ledger V1): evidence is a TOOL CALL after the last edit ---------
# Prose is never evidence (it can name any skill), Skill calls count only when their
# name is EXACTLY on the verification allowlist and they ran after the last edit, and
# an in-place edit made through Bash moves the "last edit" point like Edit/Write do.
add_text_of() {  # file text
  jq -nc --arg t "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >> "$1"
}
add_skill_of() {  # file skill-name
  jq -nc --arg s "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Skill",input:{skill:$s}}]}}' >> "$1"
}
b6_case() {  # expect(block|approve) label turn-fn...  (each turn fn gets the transcript path)
  local expect="$1" label="$2"; shift 2
  local t; t=$(mk_transcript)
  local fn; for fn in "$@"; do "$fn" "$t"; done
  local out; out=$(mk_input "$t" | bash "$GATE" 2>/dev/null || true)
  if [ "$expect" = "block" ]; then assert_block "B6: $label" "$out"; else assert_approve "B6: $label" "$out"; fi
}

# Prose after the edit: every one of these satisfied the old SKILL_EVIDENCE grep.
_p_review()   { add_text_of "$1" "Done. Run /review before merging."; }
_p_urls()     { add_text_of "$1" "See https://github.com/o/r/pull/107/reviews and docs/qa/notes for context."; }
_p_parrot()   { add_text_of "$1" "I will invoke relevant review skills (/review, /security-review, /simplify)."; }
b6_case block "prose naming /review after the edit"               add_edit_turn _p_review
b6_case block "prose with review/qa URL fragments after the edit" add_edit_turn _p_urls
b6_case block "prose parroting the gate's own block reason"       add_edit_turn _p_parrot

# Skill names that only SUBSTRING-match a verification word.
_s_qa()       { add_skill_of "$1" "sb-validation-and-qa"; }
_s_scan()     { add_skill_of "$1" "ecc:security-scan"; }
_s_dash()     { add_skill_of "$1" "second-brain:review"; }
_s_cr()       { add_skill_of "$1" "code-review"; }
_s_loop()     { add_skill_of "$1" "ecc:verification-loop"; }
b6_case block   "substring skill sb-validation-and-qa is not verification" add_edit_turn _s_qa
b6_case block   "substring skill ecc:security-scan is not verification"    add_edit_turn _s_scan
b6_case block   "second-brain:review (a dashboard) is not verification"    add_edit_turn _s_dash
b6_case approve "allowlisted Skill code-review after the edit"             add_edit_turn _s_cr
b6_case approve "allowlisted Skill ecc:verification-loop after the edit"   add_edit_turn _s_loop
b6_case block   "allowlisted Skill BEFORE the edit does not count"         _s_cr add_edit_turn

# Edits made through Bash after the tests leave the tests stale.
_b_sed()      { add_bash_of "$1" "sed -i 's/a/b/' src/foo.ts"; }
_b_perl()     { add_bash_of "$1" "perl -pi -e 's/a/b/' scripts/x.sh"; }
_b_heredoc()  { add_bash_of "$1" "cat > scripts/new.sh <<'EOF'
echo hi
EOF"; }
_b_tee()      { add_bash_of "$1" 'printf x | tee -a src/a.ts'; }
_b_append()   { add_bash_of "$1" 'echo x >> "$ROOT/src/b.py"'; }
_b_xargs()    { add_bash_of "$1" "grep -rl foo src | xargs sed -i 's/a/b/'"; }
_b_tmpl()     { add_bash_of "$1" 'echo x > src/templates/y.ts'; }
b6_case block "Edit -> tests -> sed -i on a source file"          add_edit_turn add_test_run _b_sed
b6_case block "Edit -> tests -> perl -pi on a source file"        add_edit_turn add_test_run _b_perl
b6_case block "Edit -> tests -> heredoc redirect into a script"   add_edit_turn add_test_run _b_heredoc
b6_case block "Edit -> tests -> tee -a into a source file"        add_edit_turn add_test_run _b_tee
b6_case block "Edit -> tests -> >> append into a source file"     add_edit_turn add_test_run _b_append
b6_case block "Edit -> tests -> xargs sed -i (file list hidden)"  add_edit_turn add_test_run _b_xargs
b6_case block "Edit -> tests -> redirect into src/templates (not a tmp dir)" add_edit_turn add_test_run _b_tmpl

# Controls: shell commands after the tests that do NOT edit a source file.
_c_md()       { add_bash_of "$1" "sed -i 's/a/b/' docs/notes.md"; }
_c_tmp()      { add_bash_of "$1" 'echo ok > "$TMPDIR/marker.sh"'; }
_c_awk()      { add_bash_of "$1" "awk '{ if (\$1 > 0) print }' src/a.ts > /dev/null"; }
_c_log()      { add_bash_of "$1" 'npm test 2>&1 | tee test.log'; }
_c_grepi()    { add_bash_of "$1" 'grep -i foo src/a.ts'; }
b6_case approve "Edit -> sed -i -> tests (edit then verify)"   add_edit_turn _b_sed add_test_run
b6_case approve "sed -i on a doc after the tests"              add_edit_turn add_test_run _c_md
b6_case approve "redirect into TMPDIR after the tests"         add_edit_turn add_test_run _c_tmp
b6_case approve "'>' inside a quoted awk program"              add_edit_turn add_test_run _c_awk
b6_case approve "test output tee'd to a log"                   add_edit_turn add_test_run _c_log
b6_case approve "grep -i is not an in-place edit"              add_edit_turn add_test_run _c_grepi

# Doc edits through Write/Edit after the tests do not make the tests stale (same doc
# filter as the changed-file set and the Bash-edit path).
_d_changelog() { add_write_path "$1" "CHANGELOG.md"; }
_d_readme()    { add_edit_of "$1" "README.md"; }
_d_docs()      { add_write_path "$1" "docs/guide/setup.txt"; }
b6_case approve "Edit -> tests -> Write CHANGELOG.md"          add_edit_turn add_test_run _d_changelog
b6_case approve "Edit -> tests -> Edit README.md"              add_edit_turn add_test_run _d_readme
b6_case approve "Edit -> tests -> Write under docs/"           add_edit_turn add_test_run _d_docs
b6_case block   "Edit -> tests -> Edit of another source file" add_edit_turn add_test_run add_write_turn

# Allowlist extensions resolve by EXACT name (spot-check both ends of the list).
_s_qg()       { add_skill_of "$1" "ecc:quality-gate"; }
_s_fastapi()  { add_skill_of "$1" "ecc:fastapi-review"; }
_s_eng()      { add_skill_of "$1" "engineering:code-review"; }
_s_near()     { add_skill_of "$1" "ecc:python-review-extra"; }
b6_case approve "allowlisted Skill ecc:quality-gate after the edit"        add_edit_turn _s_qg
b6_case approve "allowlisted Skill ecc:fastapi-review after the edit"      add_edit_turn _s_fastapi
b6_case approve "allowlisted Skill engineering:code-review after the edit" add_edit_turn _s_eng
b6_case block   "near-miss name ecc:python-review-extra (superset of an entry)" add_edit_turn _s_near

# A malformed transcript line is logged loudly, not swallowed. Since SF-M2 the scans
# parse per line (a bad line no longer aborts them), so the evidence is the skip row
# the changed-file scan writes, and the verdict is still computed from the rest.
T=$(mk_transcript)
add_edit_turn "$T"
echo '{"type":"assistant", broken' >> "$T"
: > "$BRAIN_DIR/error-log.jsonl"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "B6: malformed line after the edit still blocks" "$OUT"
if grep -q 'verify-scan: skipped 1 unparseable or non-object transcript line' "$BRAIN_DIR/error-log.jsonl"; then
  PASS=$((PASS + 1)); echo "  PASS: B6: malformed transcript line leaves an error-log row"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: B6: malformed transcript line was swallowed (no verify-scan skip row)"
fi

# --- SF-M2: every transcript scan is per-line tolerant -------------------------
# One bad line used to stop a whole jq scan: before the first edit it emptied the
# changed-file set and the gate APPROVED before logging anything; between a test run
# and its error result it hid the failure. Each scan now reads raw lines and parses
# them one at a time, so a bad line costs only itself.
sf_rows() {  # count error-log rows matching a fixed string
  grep -cF "$1" "$BRAIN_DIR/error-log.jsonl" 2>/dev/null || true
}
sf_case() {  # expect label turn-fn...  (runs with a fresh error log)
  local expect="$1" label="$2"; shift 2
  local t; t=$(mk_transcript)
  local fn; for fn in "$@"; do "$fn" "$t"; done
  : > "$BRAIN_DIR/error-log.jsonl"
  SF_OUT=$(mk_input "$t" | bash "$GATE" 2>/dev/null || true)
  if [ "$expect" = "block" ]; then assert_block "SF-M2: $label" "$SF_OUT"; else assert_approve "SF-M2: $label" "$SF_OUT"; fi
}
_m_broken()  { echo '{"type":"assistant", broken' >> "$1"; }
_m_nonobj()  { printf '%s\n' '5' '"just a string"' '[1,2]' 'null' >> "$1"; }
# Valid JSON objects with the wrong SHAPE: a string message, scalar content items, a
# string input, a numeric id and command. Guards must skip them without a jq error.
_m_shapes()  {
  printf '%s\n' \
    '{"type":"assistant","message":"x"}' \
    '{"type":"assistant","message":{"content":[1,"a",null]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":"str"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":5,"input":{"command":7}}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":"review"}]}}' \
    '{"type":"user","message":"x"}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"tool_use_id":9}]}}' >> "$1"
}
_m_run_fail() { add_test_run_with_id "$1" "tu-sf-1" "npm run test"; }
_m_res_fail() { add_bash_result "$1" "tu-sf-1" true; }
_m_rm_test()  { add_bash_of "$1" "git rm tests/broken.test.ts"; }
# Evidence on the LAST line with no trailing newline: jq's input_line_number reports
# N-1 there, so a scan windowed on it would drop the evidence. awk's NR (the old
# slice) and the scans' own line counter both say N.
_m_run_nonl() { printf '%s' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run test"}}]}}' >> "$1"; }

sf_case block   "malformed line BEFORE the first edit: the edit is still detected" add_qa_turn _m_broken add_edit_turn
[ "$(sf_rows 'skipped 1 unparseable')" -ge 1 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: the skipped line before the edit is logged"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: no skip row for the malformed line before the edit"; }
sf_case approve "malformed line BEFORE the edit, tests after: still approves"      _m_broken add_edit_turn add_test_run
sf_case block   "non-object lines before the edit: the edit is still detected"     _m_nonobj add_edit_turn
[ "$(sf_rows 'skipped 4 unparseable or non-object')" -ge 1 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: non-object lines are counted as skipped"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: non-object lines were not counted (want 'skipped 4')"; }
sf_case approve "non-object lines between the edit and the tests"                  add_edit_turn _m_nonobj add_test_run
[ "$(sf_rows 'gate=verify-')" -eq 0 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: non-object lines fail no scan"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: a non-object line failed a scan: $(cat "$BRAIN_DIR/error-log.jsonl")"; }
sf_case approve "wrong-shape records between the edit and the tests"               add_edit_turn _m_shapes add_test_run
[ "$(sf_rows 'gate=verify-')" -eq 0 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: wrong-shape records fail no scan"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: a wrong-shape record failed a scan: $(cat "$BRAIN_DIR/error-log.jsonl")"; }
sf_case block   "wrong-shape records alone are not an edit or evidence"            add_edit_turn _m_shapes
sf_case approve "malformed line between the edit and the tests: tests still count" add_edit_turn _m_broken add_test_run
sf_case block   "malformed line between a FAILED run and its error result"         add_edit_turn _m_run_fail _m_broken _m_res_fail
sf_case block   "malformed line before a test deletion: anti-game still fires"     add_edit_turn _m_broken _m_rm_test add_test_run
printf '%s' "$SF_OUT" | grep -q 'test-file deletion' \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: the anti-game reason survives the bad line"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: expected the test-file deletion block (got: $SF_OUT)"; }
sf_case approve "evidence on an unterminated last line counts"                     add_edit_turn _m_run_nonl

# A scan that genuinely FAILS (jq exits non-zero) fails CLOSED: it blocks once per
# session with a reason naming the failure, leaves a gate=verify-<scan>-scan row, and
# only then lets the valve open. A fake jq on PATH fails every call whose arguments
# contain a chosen string and passes everything else to the real binary.
REAL_JQ=$(command -v jq)
FAKE_BIN="$SANDBOX/fakejq"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/jq" <<'FAKEJQ'
#!/bin/bash
for _a in "$@"; do
  case "$_a" in *"$FAKEJQ_FAIL_ON"*) echo "fake jq: forced failure" >&2; exit 3 ;; esac
done
exec "$REAL_JQ" "$@"
FAKEJQ
chmod +x "$FAKE_BIN/jq"
sf_fail_run() {  # key input-json → gate stdout (jq fails on args containing key)
  printf '%s' "$2" | PATH="$FAKE_BIN:$PATH" REAL_JQ="$REAL_JQ" FAKEJQ_FAIL_ON="$1" bash "$GATE" 2>/dev/null || true
}

# (a) every transcript scan fails (they all name tool_use): verified work still gets
# ONE block, then the second Stop approves and the valve marker is kept.
T=$(mk_transcript); add_edit_turn "$T"; add_test_run "$T"
IN=$(mk_input "$T"); SID=$(printf '%s' "$IN" | jq -r '.session_id')
: > "$BRAIN_DIR/error-log.jsonl"
OUT=$(sf_fail_run 'tool_use' "$IN")
assert_block "SF-M2: all scans fail → fail closed (block once)" "$OUT"
printf '%s' "$OUT" | jq -r '.reason // ""' | grep -q 'could not scan' \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: fail-closed reason names the scan failure"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: fail-closed reason should say the gate could not scan (got: $OUT)"; }
grep -F 'gate=verify-changed-scan' "$BRAIN_DIR/error-log.jsonl" | grep -q '"exit_code":3' \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: failed changed-file scan leaves a row with its rc"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: no gate=verify-changed-scan row with exit_code 3: $(cat "$BRAIN_DIR/error-log.jsonl")"; }
OUT=$(sf_fail_run 'tool_use' "$IN")
assert_approve "SF-M2: second Stop after the fail-closed block (block once)" "$OUT"
[ "$(tr -d '[:space:]' < "$BRAIN_DIR/.verify-gate-blocks-$SID" 2>/dev/null)" = "1" ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: untrusted approve keeps the valve marker"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: the valve marker must stay at 1 after an untrusted approve"; }

# (b) only the errored-result scan fails: the one scan that could clear a red test
# run. Evidence exists, so without fail-closed this would approve on unknown results.
T=$(mk_transcript); add_edit_turn "$T"
add_test_run_with_id "$T" "tu-sf-2" "npm run test"; add_bash_result "$T" "tu-sf-2" false
: > "$BRAIN_DIR/error-log.jsonl"
OUT=$(sf_fail_run 'tool_result' "$(mk_input "$T")")
assert_block "SF-M2: errored-result scan fails → fail closed" "$OUT"
[ "$(sf_rows 'gate=verify-errored-scan')" -ge 1 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SF-M2: failed errored-result scan leaves a row"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: no gate=verify-errored-scan row: $(cat "$BRAIN_DIR/error-log.jsonl")"; }

# (c) a scan failure never softens a block: no evidence still blocks normally.
T=$(mk_transcript); add_edit_turn "$T"
OUT=$(sf_fail_run 'tool_result' "$(mk_input "$T")")
assert_block "SF-M2: scan failure with no evidence still blocks" "$OUT"

# Static guard: every scan reads the transcript FILE with jq -R. Piping it (awk NR>s |
# jq) cost ~3 s per Stop on a 27 MB transcript under MSYS, and parsing it as a JSON
# stream stops at the first bad line.
if grep -nE '"\$TRANSCRIPT"[^|]*\|[[:space:]]*jq' "$GATE" >/dev/null; then
  FAIL=$((FAIL + 1)); echo "  FAIL: SF-M2: a transcript scan pipes the transcript into jq: $(grep -nE '"\$TRANSCRIPT"[^|]*\|[[:space:]]*jq' "$GATE")"
else
  PASS=$((PASS + 1)); echo "  PASS: SF-M2: no transcript is piped into jq"
fi

# --- SEC-H3: the block-count marker is DATA, never an arithmetic expression -------
# Bash arithmetic evaluates a variable's VALUE as an expression, so $((BLOCK_COUNT + 1))
# on a marker holding `RAW[$(cmd)]` ran cmd on every Stop. A non-numeric marker now
# reads as 0 (the gate stays armed) and leaves an error-log row.
T=$(mk_transcript); add_edit_turn "$T"
IN=$(mk_input "$T"); SID=$(printf '%s' "$IN" | jq -r '.session_id')
PWNED="$SANDBOX/pwned"
printf '%s' 'RAW[$(touch${IFS}'"$PWNED"')]' > "$BRAIN_DIR/.verify-gate-blocks-$SID"
: > "$BRAIN_DIR/error-log.jsonl"
OUT=$(printf '%s' "$IN" | bash "$GATE" 2>/dev/null || true)
if [ -e "$PWNED" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: SEC-H3: marker content was executed (created $PWNED)"
else
  PASS=$((PASS + 1)); echo "  PASS: SEC-H3: marker content is never executed"
fi
assert_block "SEC-H3: a non-numeric marker keeps the gate armed" "$OUT"
[ "$(tr -d '[:space:]' < "$BRAIN_DIR/.verify-gate-blocks-$SID")" = "1" ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SEC-H3: the marker is rewritten as a number"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SEC-H3: marker should read 1 after the block (got: $(cat "$BRAIN_DIR/.verify-gate-blocks-$SID"))"; }
[ "$(sf_rows 'gate=verify-marker')" -ge 1 ] \
  && { PASS=$((PASS + 1)); echo "  PASS: SEC-H3: a non-numeric marker is logged"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: SEC-H3: no gate=verify-marker row: $(cat "$BRAIN_DIR/error-log.jsonl")"; }

# --- SEC-L2: a Skill counts only when its own result did not error; simplify is not
# verification (it refactors, it checks nothing). Results reuse add_bash_result: a
# tool_result row is keyed only by tool_use_id.
_s_rev_id()   { jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"sk-1",name:"Skill",input:{skill:"review"}}]}}' >> "$1"; }
_s_cr_id()    { jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"sk-2",name:"Skill",input:{skill:"code-review"}}]}}' >> "$1"; }
_s_rev_err()  { add_bash_result "$1" "sk-1" true; }
_s_rev_ok()   { add_bash_result "$1" "sk-1" false; }
_s_cr_ok()    { add_bash_result "$1" "sk-2" false; }
_s_simplify() { add_skill_of "$1" "simplify"; }
_s_devil()    { add_skill_of "$1" "devils-advocate"; }
b6_case block   "allowlisted Skill whose result is an error is not evidence" add_edit_turn _s_rev_id _s_rev_err
b6_case approve "allowlisted Skill whose result is ok is evidence"           add_edit_turn _s_rev_id _s_rev_ok
b6_case approve "errored Skill, then an ok Skill: the ok one counts"         add_edit_turn _s_rev_id _s_rev_err _s_cr_id _s_cr_ok
b6_case block   "simplify is a refactor, not verification"                   add_edit_turn _s_simplify
b6_case approve "devils-advocate stays on the allowlist"                     add_edit_turn _s_devil

# --- T6: single-quoted text is blanked before the Bash-edit heuristic -----------
# A commit message quoting a redirect into a source path is not an edit.
_q_commit() { add_bash_of "$1" "git commit -m 'note: echo x > src/a.ts'"; }
b6_case approve "quoted '> src/a.ts' in a commit message is not an edit" add_edit_turn add_test_run _q_commit
# Control: the same redirect OUTSIDE quotes is an edit.
_q_bare()   { add_bash_of "$1" "echo x > src/a.ts"; }
b6_case block   "the same redirect unquoted is an edit"                   add_edit_turn add_test_run _q_bare

# The block reason must not name a token that prose alone could satisfy.
T=$(mk_transcript)
add_edit_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "B6: plain block" "$OUT"
if printf '%s' "$OUT" | jq -r '.reason // ""' | grep -qE '/(review|security-review|simplify|qa)'; then
  FAIL=$((FAIL + 1)); echo "  FAIL: B6: block reason still names a /slash token (got: $OUT)"
else
  PASS=$((PASS + 1)); echo "  PASS: B6: block reason names no /slash token"
fi

# --- G1: path exemptions are root-relative and separator-agnostic -------------------
# Windows tool paths use a backslash: scratchpad files OUTSIDE the repo used to count as
# source edits (the exemption only matched "/"-separated segments) and demanded the suite.
# Rules (R1 review): the repo root is CLAUDE_PROJECT_DIR, else the git toplevel of the payload cwd
# (matched in its raw, resolved and logical spellings). INSIDE it only docs/ and the TOP-LEVEL tmp/
# or scratch/ dirs are exempt, so a file whose name merely contains sandbox/temp/tmp/scratch arms.
# OUTSIDE it (or with no root at all) an edit ARMS unless the path is temp: under the hook's own
# $TMPDIR/$TMP/$TEMP, an anchored temp segment (tmp, temp, tmpdir, scratch, scratchpad, sandbox, a
# mktemp-style tmp.<alnum> dir), or the macOS /var/folders/<a>/<b>/T/ root; that keeps a Windows
# AppData/Local/Temp scratchpad exempt. Paths are canonicalized first: \ -> /, the //?/ and //./
# prefixes, . and .. and repeated slashes, case-insensitive on MSYS/Cygwin/macOS and for drive-letter
# paths.
# The sandbox lives under a temp dir on every platform (/tmp/..., macOS /var/folders/.../T/...), so a
# canonicalization that fails to see an in-repo path falls through to "outside, temp, exempt" and the
# block assertion catches it.
G1_REPO="$SANDBOX/g1/repo"; mkdir -p "$G1_REPO/src"
# g1_case block|approve label path [cwd]
g1_case() {
  local want="$1" label="$2" path="$3" cwd="${4:-$G1_REPO}" T OUT
  T=$(mk_transcript); add_edit_of "$T" "$path"
  OUT=$(mk_input_cwd "$T" "$cwd" | bash "$GATE" 2>/dev/null || true)
  if [ "$want" = block ]; then assert_block "G1: $label" "$OUT"; else assert_approve "G1: $label" "$OUT"; fi
}
g1_case approve "Windows-form scratchpad .js outside the repo" 'C:''\''Users''\''x''\''AppData''\''Local''\''Temp''\''claude''\''scratchpad''\''probe.js'
g1_case approve "forward-slash scratch .js outside the repo" "/var/tmp/scratchpad/probe.js"
g1_case block "plain source path outside the repo arms (outside-root edits are not exempt)" "/elsewhere/project/src/x.js"
g1_case approve "docs backslash-relative .js inside the repo" 'docs''\''x.js'
g1_case approve "docs backslash-relative .md inside the repo" 'docs''\''x.md'
g1_case approve "docs/ absolute .md inside the repo" "$G1_REPO/docs/x.md"
g1_case approve "tmp/ relative .js inside the repo" "tmp/probe.js"
g1_case approve "top-level scratch/ absolute .ts inside the repo" "$G1_REPO/scratch/a.ts"
g1_case block "src .sh inside the repo (absolute)" "$G1_REPO/src/a.sh"
# In-repo source files whose NAME merely contains sandbox/temp/tmp/scratch must arm (the R1 G1 regression).
for f in src/components/Sandbox.tsx packages/sandbox/index.ts src/tmp_parser.py src/temp-sensor.c \
         src/sandbox.ts src/temp_parser.ts tmp-tools/a.ts src/scratch/x.ts; do
  g1_case block "in-repo $f arms" "$G1_REPO/$f"
done
# Canonicalization: every spelling of an in-repo path is in the repo.
g1_case block "a .. hop back into the repo arms" "$SANDBOX/g1/other/../repo/src/a.ts"
# (The first slash stays single: a leading // is a UNC prefix, which Git-Bash will not translate
# when the fixture hands the path to jq, so the fixture itself would name another file.)
g1_case block "repeated slashes into the repo arm" "$(printf '%s' "$G1_REPO" | sed 's#/#//#g; s#^//#/#')//src//a.ts"
g1_case block "a ./ segment into the repo arms" "$G1_REPO/./src/./a.ts"
# Bash-edit heuristic follows the SAME outside-root rule as Edit/Write: an in-repo edit, the tests,
# then `sed -i` on a file that is NOT in the repo. Outside-root source used to be ignored here, so
# the tests stayed "fresh" while an Edit to the same path would have armed the gate.
g1_bash_case() {  # block|approve label command [cwd] [project_dir]
  local want="$1" label="$2" cmd="$3" cwd="${4:-$G1_REPO}" pd="${5:-}" T OUT
  T=$(mk_transcript); add_edit_turn "$T"; add_test_run "$T"; add_bash_of "$T" "$cmd"
  if [ -n "$pd" ]; then
    OUT=$(mk_input_cwd "$T" "$cwd" | CLAUDE_PROJECT_DIR="$pd" bash "$GATE" 2>/dev/null || true)
  else
    OUT=$(mk_input_cwd "$T" "$cwd" | bash "$GATE" 2>/dev/null || true)
  fi
  if [ "$want" = block ]; then assert_block "G1-bash: $label" "$OUT"; else assert_approve "G1-bash: $label" "$OUT"; fi
}
g1_bash_case block   "sed -i on an outside-root source file moves the last edit" "sed -i 's/a/b/' /other/repo/src/x.ts"
g1_bash_case approve "sed -i on an outside-root temp-segment path stays exempt"  "sed -i 's/a/b/' /var/tmp/scratchpad/x.ts"
g1_bash_case block   "sed -i on an in-repo source file still moves the last edit" "sed -i 's/a/b/' src/foo.ts"
g1_bash_case approve "sed -i on an in-repo doc stays exempt"                      "sed -i 's/a/b/' docs/x.ts"
g1_bash_case approve "redirect into \$TMPDIR stays exempt"                        'echo ok > "$TMPDIR/marker.sh"'

# --- G1 temp detection (R1 fix round 2) ---------------------------------------------------------
# Outside the root a path is temp when it lies under one of the hook's own temp dirs ($TMPDIR, $TMP,
# $TEMP), has an anchored temp segment (tmp, temp, tmpdir, scratch, scratchpad, sandbox, or a
# mktemp-style tmp.<alnum> DIRECTORY), or sits under a macOS per-user temp root
# /var/folders/<a>/<b>/T/. macOS expands TMPDIR to /var/folders/zz/ab12/T/ and mktemp names look like
# tmp.Ab1XyZ: neither carried a temp word, so every agent scratch file there armed the gate.
# Each row names the wrong implementation it catches. Paths go through add_edit_raw (no MSYS argv
# conversion) so a POSIX-only spelling such as /var/folders/... reaches the gate as written.
add_edit_raw() { # file path
  MSYS_NO_PATHCONV=1 jq -nc --arg p "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Edit",input:{file_path:$p,old_string:"a",new_string:"b"}}]}}' >> "$1"
}
# The native spelling of a POSIX path: what Claude Code on Windows hands a tool, and what MSYS turns
# the gate's own --arg into. Identity off MSYS.
g1_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
g1_raw_case() { # block|approve label path [cwd]
  local want="$1" label="$2" path="$3" cwd="${4:-$G1_REPO}" T OUT
  T=$(mk_transcript); add_edit_raw "$T" "$path"
  OUT=$(mk_input_cwd "$T" "$cwd" | bash "$GATE" 2>/dev/null || true)
  if [ "$want" = block ]; then assert_block "G1: $label" "$OUT"; else assert_approve "G1: $label" "$OUT"; fi
}
# g1_env_case block|approve label edit|bash path-or-command VAR=value... : the gate runs under
# `env VAR=value...`, so the hook's temp-dir variables are the subject.
g1_env_case() {
  local want="$1" label="$2" kind="$3" arg="$4" T OUT
  shift 4
  T=$(mk_transcript)
  if [ "$kind" = edit ]; then add_edit_raw "$T" "$arg"
  else add_edit_turn "$T"; add_test_run "$T"; add_bash_of "$T" "$arg"; fi
  OUT=$(mk_input_cwd "$T" "$G1_REPO" | env "$@" bash "$GATE" 2>/dev/null || true)
  if [ "$want" = block ]; then assert_block "G1-env: $label" "$OUT"; else assert_approve "G1-env: $label" "$OUT"; fi
}
G1_REAL_TMP="${TMPDIR:-/tmp}"
# Write/Edit. Mutations caught: no macOS branch (1); the macOS branch without (private/)? (2);
# a bare ^/var/folders/ match (3); no tmp.<alnum> branch (4); tmp.<alnum> anchored as a FINAL
# segment, exempting a source file named tmp.c (5); tmpdir missing from the segment list (6);
# macOS only: the reported bug, the real $TMPDIR read as source (7).
g1_raw_case approve "macOS expanded TMPDIR /var/folders/<a>/<b>/T/ outside the repo is exempt" "/var/folders/zz/ab12cd34/T/probe/x.sh"
g1_raw_case approve "macOS /private/var/folders/<a>/<b>/T/ spelling is exempt"                  "/private/var/folders/zz/ab12cd34/T/x.ts"
g1_raw_case block   "macOS /var/folders/<a>/<b>/C/ (cache, not temp) arms"                      "/var/folders/zz/ab12cd34/C/x.sh"
g1_raw_case approve "a mktemp-style tmp.Ab1XyZ dir outside the repo is exempt"                  "/other/tmp.Ab1XyZ/x.sh"
g1_raw_case block   "a source file named tmp.c outside the repo arms (tmp.<alnum> is a dir rule)" "/other/src/tmp.c"
g1_raw_case approve "a tmpdir segment outside the repo is exempt"                               "/other/tmpdir/x.sh"
g1_case     approve "a path under the test process's real \$TMPDIR is exempt"                   "$G1_REAL_TMP/g1-probe/x.sh"
# Bash. Same mutations, through bash_counts_as_src (B1-B4).
g1_bash_case approve "sed -i under a macOS expanded TMPDIR is exempt"   "sed -i 's/a/b/' /var/folders/zz/ab12cd34/T/probe/x.sh"
g1_bash_case approve "> into a mktemp-style tmp.Ab1XyZ dir is exempt"   "echo x > /other/tmp.Ab1XyZ/x.sh"
g1_bash_case approve "sed -i under the test process's real \$TMPDIR is exempt" "sed -i 's/a/b/' $G1_REAL_TMP/g1-probe/x.sh"
g1_bash_case approve "sed -i in a tmpdir segment is exempt"             "sed -i 's/a/b/' /other/tmpdir/x.sh"
# Root resolution for Bash edits. No root at all (no CLAUDE_PROJECT_DIR, cwd gone): an outside source
# edit still counts (mutation: no roots -> Bash edits ignored), a temp one does not (mutation: no
# roots -> the temp test skipped). Root = cwd (non-git dir): an in-root source edit counts (mutation:
# the cwd-fallback branch dropped; the path then reads outside, under the temp sandbox, exempt).
G1_NOGIT_B="$SANDBOX/g1/nogit-bash"; mkdir -p "$G1_NOGIT_B/src"
g1_bash_case block   "no root resolvable: sed -i on an outside source file counts" "sed -i 's/a/b/' /other/repo/src/x.ts" "$SANDBOX/g1/no-such-dir"
g1_bash_case approve "no root resolvable: sed -i in a tmp.XXXX dir is exempt"      "sed -i 's/a/b/' /other/tmp.Ab1XyZ/x.ts" "$SANDBOX/g1/no-such-dir"
g1_bash_case block   "root = cwd (non-git): sed -i on its src file counts"          "sed -i 's/a/b/' $(g1_native "$G1_NOGIT_B")/src/x.ts" "$G1_NOGIT_B"
# Temp spellings (mutations: case-sensitive segment match; backslashes not canonicalized; sandbox or
# scratch missing from the segment list).
g1_bash_case approve "/x/Temp/ segment is exempt (any case)"            "sed -i 's/a/b/' /x/Temp/y.ts"
g1_bash_case approve "/x/TMP/ segment is exempt (any case)"             "sed -i 's/a/b/' /x/TMP/y.ts"
g1_bash_case approve "backslash AppData\\Local\\Temp path is exempt"    'sed -i '"'s/a/b/'"' C:\Users\u\AppData\Local\Temp\y.ts'
g1_bash_case approve "/x/sandbox/ segment is exempt"                    "sed -i 's/a/b/' /x/sandbox/y.ts"
g1_bash_case approve "/x/scratch/ segment is exempt"                    "sed -i 's/a/b/' /x/scratch/y.ts"
# Arming outside the root (mutations: an unanchored temp match, i.e. scratchy's boundary, applied to
# outside paths (tmp_parser, temp-sensor); the docs/ exemption applied outside the root).
g1_bash_case block   "/other/src/tmp_parser.py counts (temp-like name, not a segment)" "sed -i 's/a/b/' /other/src/tmp_parser.py"
g1_bash_case block   "/other/src/temp-sensor.c counts (temp-like name, not a segment)" "sed -i 's/a/b/' /other/src/temp-sensor.c"
g1_bash_case block   "/other/docs/x.ts counts (docs/ is exempt only inside the root)"  "sed -i 's/a/b/' /other/docs/x.ts"
# Redirect and tee targets outside the root (mutations: the extension filter skipped for outside
# paths (notes.md, out.json); redirect/tee targets outside the root ignored, the pre-G1 behavior).
g1_bash_case approve "> /other/repo/notes.md stays exempt (not code)"  "echo x > /other/repo/notes.md"
g1_bash_case approve "> /other/out.json stays exempt (not code)"       "echo x > /other/out.json"
g1_bash_case block   "> /other/repo/src/x.ts counts"                   "echo x > /other/repo/src/x.ts"
g1_bash_case block   "tee /other/repo/src/x.ts counts"                 "printf x | tee /other/repo/src/x.ts"
# The hook's own temp dirs, each set to a dir with no temp word (mutations: branch (a) missing;
# only TMPDIR read, not TMP/TEMP; a prefix match without the / boundary; no case fold on drive paths).
g1_env_case approve "TMPDIR=/opt/ci/xdg-cache: an Edit under it (native spelling) is exempt" edit "$(g1_native /opt/ci/xdg-cache)/src/a.ts" TMPDIR=/opt/ci/xdg-cache
g1_env_case approve "TMPDIR=C:\\ci\\xdg-cache: > under it is exempt" bash "echo x > C:/ci/xdg-cache/src/a.ts" 'TMPDIR=C:\ci\xdg-cache'
g1_env_case approve "TMP=C:\\ci\\xdg-tmp: sed -i under it is exempt" bash "sed -i 's/a/b/' C:/ci/xdg-tmp/src/a.ts" 'TMP=C:\ci\xdg-tmp'
g1_env_case approve "TEMP=C:/ci/xdg-temp: an Edit under it (/c/ spelling) is exempt" edit "/c/ci/xdg-temp/src/a.ts" 'TEMP=C:/ci/xdg-temp'
g1_env_case block   "TMP=C:\\ci\\xdg-cache: the sibling xdg-cache2 still counts" bash "sed -i 's/a/b/' C:/ci/xdg-cache2/src/a.ts" 'TMP=C:\ci\xdg-cache'
g1_env_case approve "TMP=C:\\CI\\Xdg-Cache: a drive path folds case" edit "c:/ci/xdg-cache/src/a.ts" 'TMP=C:\CI\Xdg-Cache'
# A temp variable that is not an absolute dir must exempt nothing: canon("C:") is "C:" and
# canon(".") is "", and either plus "/" prefix-matches every path on that side (mutation: the
# temp-dir list not filtered to absolute dirs). These double as the Windows-drive Bash rows.
g1_env_case block   "TMP=C: drive-relative, Edit C:\\other\\src\\x.ts arms" edit 'C:\other\src\x.ts' 'TMP=C:'
g1_env_case block   "TMP=C: drive-relative, sed -i C:\\other\\src\\x.ts counts"      bash 'sed -i '"'s/a/b/'"' C:\other\src\x.ts' 'TMP=C:'
g1_env_case block   "TMP=C: drive-relative, sed -i C:/other/src/x.ts counts"        bash "sed -i 's/a/b/' C:/other/src/x.ts" 'TMP=C:'
g1_env_case block   "TMP=C: drive-relative, > /c/other/src/x.ts counts"             bash "echo x > /c/other/src/x.ts" 'TMP=C:'
g1_env_case block   "TMP=C: drive-relative, sed -i //?/C:/other/src/x.ts counts"    bash "sed -i 's/a/b/' //?/C:/other/src/x.ts" 'TMP=C:'
g1_env_case block   "TEMP=. relative, sed -i /other/src/x.ts counts"          bash "sed -i 's/a/b/' /other/src/x.ts" 'TEMP=.'
if command -v cygpath >/dev/null 2>&1; then
  G1_WIN=$(cygpath -w "$G1_REPO")
  g1_case block "\\\\?\\ extended-length Windows path into the repo arms" "\\\\?\\$G1_WIN\\src\\a.ts" "$G1_WIN"
  g1_case block "\\\\.\\ device-namespace Windows path into the repo arms" "\\\\.\\$G1_WIN\\src\\a.ts" "$G1_WIN"
  g1_case block "forward-slash drive path with doubled slashes arms" "$(cygpath -m "$G1_REPO" | sed 's#/#//#g')//src//a.ts" "$G1_WIN"
fi
case "${OSTYPE:-}" in
  msys*|cygwin*|darwin*)
    g1_case block "a case-variant spelling of the root arms (case-insensitive file system)" \
      "$(printf '%s' "$G1_REPO" | tr 'a-z' 'A-Z')/src/a.ts" ;;
  *) echo "  note: case-variant root case not run on a case-sensitive file system ($OSTYPE)" ;;
esac
G1_TMPREPO="$SANDBOX/g1/Temp/sandbox/repo"; mkdir -p "$G1_TMPREPO/src"
T=$(mk_transcript); add_edit_of "$T" "$G1_TMPREPO/src/a.sh"
OUT=$(mk_input_cwd "$T" "$G1_TMPREPO" | bash "$GATE" 2>/dev/null || true)
assert_block "G1: src .sh in a repo checked out under /Temp/sandbox/ still arms" "$OUT"
T=$(mk_transcript); add_edit_of "$T" "$G1_TMPREPO/src/a.sh"
OUT=$(mk_input_cwd "$T" "$G1_TMPREPO/src" | bash "$GATE" 2>/dev/null || true)
assert_block "G1: same, with cwd in a subdirectory of that repo" "$OUT"

# The payload cwd moves during a session (one real transcript: 3785 lines in one worktree, 210 in
# main, 191 in another). CLAUDE_PROJECT_DIR is the root first, so an edit to the main checkout made
# while cwd sits in a worktree (its own git toplevel) or in a non-git dir still arms.
if command -v git >/dev/null 2>&1; then
  G1_MAIN="$SANDBOX/g1/main"; G1_WT="$G1_MAIN/.claude/worktrees/wt"; G1_NOGIT="$SANDBOX/g1/nogit"
  mkdir -p "$G1_MAIN/mcp/src/tools" "$G1_WT/src" "$G1_NOGIT"
  git -C "$G1_MAIN" init -q && git -C "$G1_WT" init -q
  g1_pd_case() { # label path cwd
    local T OUT
    T=$(mk_transcript); add_edit_of "$T" "$2"
    OUT=$(mk_input_cwd "$T" "$3" | CLAUDE_PROJECT_DIR="$G1_MAIN" bash "$GATE" 2>/dev/null || true)
    assert_block "G1: $1" "$OUT"
  }
  g1_pd_case "cwd in a worktree, edit to a main-checkout src file arms" "$G1_MAIN/mcp/src/tools/episodic-search.ts" "$G1_WT"
  g1_pd_case "cwd in a worktree, edit to the worktree's own src file arms" "$G1_WT/src/a.ts" "$G1_WT"
  g1_pd_case "cwd in a non-git dir, in-repo src edit arms" "$G1_MAIN/mcp/src/tools/x.ts" "$G1_NOGIT"
  # Bash, root from CLAUDE_PROJECT_DIR (the first branch): cwd sits in a worktree with its own git
  # toplevel. Mutation caught: the CLAUDE_PROJECT_DIR branch dropped, so the root is the worktree and
  # the main-checkout path reads outside, under the temp sandbox, exempt.
  g1_bash_case block "CLAUDE_PROJECT_DIR set, cwd in a worktree: sed -i on a main-checkout src file counts" \
    "sed -i 's/a/b/' $(g1_native "$G1_MAIN")/mcp/src/x.ts" "$G1_WT" "$G1_MAIN"
  T=$(mk_transcript); add_edit_of "$T" 'C:''\''Users''\''x''\''AppData''\''Local''\''Temp''\''claude''\''scratchpad''\''probe.js'
  OUT=$(mk_input_cwd "$T" "$G1_WT" | CLAUDE_PROJECT_DIR="$G1_MAIN" bash "$GATE" 2>/dev/null || true)
  assert_approve "G1: with CLAUDE_PROJECT_DIR set, a Windows scratchpad path outside stays exempt" "$OUT"
  # An outside-root classification is never silent: one gate=verify-outside-root audit row.
  rm -f "$BRAIN_DIR/audit-log.jsonl"
  T=$(mk_transcript); add_edit_of "$T" "/elsewhere/project/src/x.js"
  mk_input_cwd "$T" "$G1_MAIN" | CLAUDE_PROJECT_DIR="$G1_MAIN" bash "$GATE" >/dev/null 2>&1 || true
  if jq -c 'select(.script == "stop-verify-gate.sh" and .exit_code == 0 and ((.message // "") | startswith("gate=verify-outside-root armed=1 exempt=0")))' \
      "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q .; then
    PASS=$((PASS + 1)); echo "  PASS: G1: an outside-root edit writes a gate=verify-outside-root audit row"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: G1: no gate=verify-outside-root armed=1 row for an outside-root edit ($(tail -2 "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null))"
  fi
  # A symlinked checkout: git reports the resolved toplevel, the payload cwd and tool paths the link.
  # Both spellings are the repo. ln -s deep-copies on MSYS, so Windows gets a junction from node
  # (Git-Bash reports it as a link).
  G1_LINK="$SANDBOX/g1/link-main"
  ln -s "$G1_MAIN" "$G1_LINK" 2>/dev/null || true
  if [ ! -L "$G1_LINK" ] && command -v cygpath >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    [ -d "$G1_LINK" ] && mv "$G1_LINK" "$SANDBOX/g1/link-copy"   # ln -s left a deep copy behind
    node -e "require('fs').symlinkSync(process.argv[1], process.argv[2], 'junction')" "$(cygpath -w "$G1_MAIN")" "$(cygpath -w "$G1_LINK")" || true
  fi
  if [ -L "$G1_LINK" ]; then
    T=$(mk_transcript); add_edit_of "$T" "$G1_LINK/mcp/src/tools/x.ts"
    OUT=$(mk_input_cwd "$T" "$G1_LINK/mcp" | bash "$GATE" 2>/dev/null || true)
    assert_block "G1: symlinked root, link-spelled in-repo path arms" "$OUT"
    T=$(mk_transcript); add_edit_of "$T" "$G1_LINK/tmp/probe.js"
    OUT=$(mk_input_cwd "$T" "$G1_LINK/mcp" | bash "$GATE" 2>/dev/null || true)
    assert_approve "G1: symlinked root, link-spelled top-level tmp/ stays exempt" "$OUT"
  else
    echo "  note: symlinked-root cases not run (ln -s makes no real link on this host)"
  fi
else
  FAIL=$((FAIL + 1)); echo "  FAIL: G1: git not on PATH — the worktree/project-dir cases cannot run"
fi

# --- RR-SF2: MSYS here-string hang at 65,536..~65,650 bytes -----------------------------
# `<<< "$VERIFY_CANDIDATES"` and `<<< "$SVG_OUT"` used a plain here-string: on MSYS a text of
# that byte width never fits before the reader starts, so the hook hangs past its timeout and
# APPROVES NOTHING (the gate's evidence is silently forfeited, not just slow — rc=124 measured
# at 12+ s here). bounded_svg LABEL LIM TRANSCRIPT: background run, kill past LIM s. The gate must
# also EXIT 0: an empty output reads as approve to assert_approve, so a crash used to pass as one
# (F8) — and each approve case below has a control that must BLOCK through the same large path,
# so an early size-gated exit cannot pass either.
bounded_svg() {
  local label="$1" lim="$2" t="$3" pid i=0 rc=0
  mk_input "$t" | bash "$GATE" > "$SANDBOX/rr_sf2.out" 2> "$SANDBOX/rr_sf2.err" & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$lim" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    # TERM, then KILL: a gate blocked writing a pipe on MSYS ignores TERM and would outlive the test.
    kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
    FAIL=$((FAIL + 1)); echo "  FAIL: $label: still running after ${lim}s"
    return 1
  fi
  wait "$pid" || rc=$?
  RR_SF2_OUT=$(cat "$SANDBOX/rr_sf2.out" 2>/dev/null); RR_SF2_EL=$i
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $label: the gate exited $rc — a crash is not an approve ($(head -c 300 "$SANDBOX/rr_sf2.err"))"
    return 1
  fi
  return 0
}
# A Bash tool_use after the last edit whose command is a test-shaped string totalling ~65,600
# bytes (well inside the hang window; the guard's own filter needs the word "test" somewhere).
# Built with printf, not add_bash_of's `jq --arg`: a ~65,600-byte argv value overran Windows'
# CreateProcess argument-length cap ("Argument list too long") before the fixture even ran.
T=$(mk_transcript)
add_edit_turn "$T"
PAD65600=$(printf '%*s' 65585 '' | tr ' ' x)
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run test # %s"}}]}}\n' "$PAD65600" >> "$T"
if bounded_svg "RR-SF2: ~65,600-byte post-edit Bash command (VERIFY_CANDIDATES)" 15 "$T"; then
  assert_approve "RR-SF2: ~65,600-byte post-edit test command still approves in ${RR_SF2_EL}s" "$RR_SF2_OUT"
fi
# Control: the same ~65,600-byte candidate blob, but the command is no test run — it must BLOCK.
T=$(mk_transcript)
add_edit_turn "$T"
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo done # %s"}}]}}\n' "$PAD65600" >> "$T"
if bounded_svg "RR-SF2 control: ~65,600-byte post-edit non-test command" 15 "$T"; then
  assert_block "RR-SF2 control: a ~65,600-byte post-edit command that is no test run still blocks in ${RR_SF2_EL}s" "$RR_SF2_OUT"
fi
# The Skill-scan variant (SVG_OUT): many allowlisted Skill calls after the edit, whose joined
# "id<TAB>name\n" lines land the same blob in the hang window. One jq spawn builds the line;
# a bash loop of the `printf` builtin (no fork) repeats it 5,467 times.
T=$(mk_transcript)
add_edit_turn "$T"
SKILL_LINE=$(jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Skill",input:{skill:"review"}}]}}')
n=0
while [ "$n" -lt 5467 ]; do printf '%s\n' "$SKILL_LINE" >> "$T"; n=$((n + 1)); done
if bounded_svg "RR-SF2: 5,467 post-edit Skill calls (SVG_OUT)" 15 "$T"; then
  assert_approve "RR-SF2: 5,467 post-edit 'review' Skill calls still approve in ${RR_SF2_EL}s" "$RR_SF2_OUT"
fi
# Control: 5,467 calls to a skill NOT on the allowlist are no evidence — it must BLOCK.
T=$(mk_transcript)
add_edit_turn "$T"
SKILL_LINE=$(jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Skill",input:{skill:"brainstorm"}}]}}')
n=0
while [ "$n" -lt 5467 ]; do printf '%s\n' "$SKILL_LINE" >> "$T"; n=$((n + 1)); done
if bounded_svg "RR-SF2 control: 5,467 post-edit non-allowlisted Skill calls" 15 "$T"; then
  assert_block "RR-SF2 control: 5,467 calls to a skill off the allowlist still block in ${RR_SF2_EL}s" "$RR_SF2_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
