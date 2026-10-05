#!/bin/bash
# Regression lock for tests/run-all.sh SKIP-vs-FAIL classification.
#
# The bug: run-all.sh detected the SKIP convention with a grep that ran BEFORE
# the exit-code check, so a test that printed a mid-run "SKIP:" line for one
# optional subtest and then FAILED a real assertion (exit != 0) was silently
# counted as SKIP — the whole suite reported ALL GREEN and exited 0. That hides
# real failures, most likely on Windows (no CI lane) where several tests emit
# mid-run SKIP lines. Fix: only classify SKIP when the test also exited 0.
#
# These cases drive run-all.sh at an isolated fixture dir (SB_RUN_ALL_TESTS_DIR)
# with vitest disabled, and assert the aggregate exit code + verdict.
set -u
RUNALL="$(cd "$(dirname "$0")/.." && pwd)/tests/run-all.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

run_suite() {  # $1 = fixture tests dir → prints "<verdict-line>\nEXIT=<ec>"
  SB_RUN_ALL_TESTS_DIR="$1" SB_RUN_ALL_VITEST=0 SB_RUN_ALL_QUIET=1 \
    bash "$RUNALL" 2>&1; printf 'EXIT=%d\n' "$?"
}

# --- Case 1: mid-run SKIP + real failure (exit 1) MUST be counted FAIL ----
D1="$TMP/case1"; mkdir -p "$D1"
cat > "$D1/test-skip-then-fail.sh" <<'EOF'
#!/bin/bash
echo "SKIP: an optional subtest was skipped"
echo "...but a real assertion below fails"
exit 1
EOF
OUT=$(run_suite "$D1")
printf '%s\n' "$OUT" | grep -q 'EXIT=1' \
  || fail "skip-then-fail must make the suite exit 1 (false-green regression): $OUT"
printf '%s\n' "$OUT" | grep -qiE 'fail: *1|FAILED' \
  || fail "skip-then-fail must be reported as FAIL, not SKIP: $OUT"
pass "mid-run SKIP + exit 1 → counted FAIL, suite exits 1"

# --- Case 2: genuine whole-file skip (prints SKIP, exits 0) stays SKIP -----
# Pin the expected-skips manifest to this fixture's skip: this case locks SKIP
# CLASSIFICATION, and must stay green on platforms whose per-platform manifest
# is armed (an unpinned unexpected skip correctly fails the suite there).
D2="$TMP/case2"; mkdir -p "$D2"
cat > "$D2/test-pure-skip.sh" <<'EOF'
#!/bin/bash
echo "SKIP: feature unavailable on this platform"
exit 0
EOF
OUT=$(SB_EXPECTED_SKIPS="test-pure-skip" run_suite "$D2")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' \
  || fail "pure-skip (exit 0) must keep the suite green: $OUT"
printf '%s\n' "$OUT" | grep -qE 'skip: *1' \
  || fail "pure-skip should be counted as SKIP: $OUT"
pass "pure SKIP + exit 0 → counted SKIP, suite exits 0"

# --- Case 3: a passing test with NO skip line stays PASS/green ------------
D3="$TMP/case3"; mkdir -p "$D3"
cat > "$D3/test-plain-pass.sh" <<'EOF'
#!/bin/bash
echo "everything fine"
exit 0
EOF
OUT=$(run_suite "$D3")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' || fail "plain pass must exit 0: $OUT"
printf '%s\n' "$OUT" | grep -qE 'pass: *1' || fail "plain pass should count as PASS: $OUT"
pass "plain pass → counted PASS, suite exits 0"

# --- Case 4: INDENTED partial skip (D206) ----------------------------------
# The test runs real assertions (prints real output), then skips ONE optional
# subtest with an INDENTED "  SKIP: ..." line, and exits 0. Must be counted a
# PASS (its real assertions all held) — but flagged as a partial-skip file, not
# silently folded into a plain PASS (which would hide the skip) nor into the
# whole-file SKIP bucket (which would hide the pass).
D4="$TMP/case4"; mkdir -p "$D4"
cat > "$D4/test-indented-partial-skip.sh" <<'EOF'
#!/bin/bash
echo "step 1: ok"
echo "  SKIP: optional step 2 unavailable on this host"
echo "step 3: ok"
exit 0
EOF
OUT=$(run_suite "$D4")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' \
  || fail "indented partial skip must keep the suite green: $OUT"
printf '%s\n' "$OUT" | grep -qE 'pass: *1 \(1 partial-skip files\)' \
  || fail "indented partial skip must be reported as pass: 1 (1 partial-skip files): $OUT"
printf '%s\n' "$OUT" | grep -qE 'skip: *0' \
  || fail "indented partial skip must NOT be counted in the whole-file skip total: $OUT"
printf '%s\n' "$OUT" | grep -q 'test-indented-partial-skip' \
  || fail "indented partial skip must be named in the partial-skip listing: $OUT"
pass "indented partial SKIP mid-run → counted PASS (1 partial-skip file), suite exits 0"

# --- Case 5: column-0 partial skip AFTER passes (D206) ----------------------
# Same shape as case 4 but the inner SKIP line sits at column 0 (no leading
# whitespace) and only after other passing output — must NOT be reclassified
# as a whole-file skip (the old bug: ANY column-0 SKIP anywhere in the output
# was treated as if the whole file were skipped, hiding the real passes).
D5="$TMP/case5"; mkdir -p "$D5"
cat > "$D5/test-col0-partial-skip-after-pass.sh" <<'EOF'
#!/bin/bash
echo "PASS: subtest A"
echo "PASS: subtest B"
echo "SKIP: subtest C unavailable on this host"
echo "PASS: subtest D"
exit 0
EOF
OUT=$(run_suite "$D5")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' \
  || fail "column-0 partial skip after passes must keep the suite green: $OUT"
printf '%s\n' "$OUT" | grep -qE 'pass: *1 \(1 partial-skip files\)' \
  || fail "column-0 partial skip after passes must be reported as pass: 1 (1 partial-skip files): $OUT"
printf '%s\n' "$OUT" | grep -qE 'skip: *0' \
  || fail "column-0 partial skip after passes must NOT be counted as a whole-file skip (the old false-hidden-pass bug): $OUT"
pass "column-0 partial SKIP after passing output → counted PASS (1 partial-skip file), not whole-file SKIP"

# --- Case 6: whole-file skip via an INDENTED first line (D206) --------------
# The regex gained leading-whitespace tolerance for the partial-skip case
# above; prove it did NOT break the existing whole-file-skip detection when
# the SKIP line itself happens to be indented (e.g. printed inside an `if`
# block with a leading echo indent) and IS the first non-empty output line.
D6="$TMP/case6"; mkdir -p "$D6"
cat > "$D6/test-indented-whole-file-skip.sh" <<'EOF'
#!/bin/bash
  echo "SKIP: feature unavailable on this platform (indented)"
exit 0
EOF
OUT=$(SB_EXPECTED_SKIPS="test-indented-whole-file-skip" run_suite "$D6")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' \
  || fail "indented whole-file skip (exit 0) must keep the suite green: $OUT"
printf '%s\n' "$OUT" | grep -qE 'skip: *1' \
  || fail "indented whole-file skip should be counted as SKIP, not partial-skip or plain pass: $OUT"
printf '%s\n' "$OUT" | grep -qE 'pass: *0($| )' \
  || fail "indented whole-file skip must not also be counted as a pass: $OUT"
pass "indented whole-file SKIP (first line) → counted SKIP, suite exits 0"

# --- Case 7: env sandboxing beyond HOME (D207) ------------------------------
# run-all.sh must scrub BRAIN_DIR/SB_BRAIN_DIR/KNOWLEDGE_DIR/
# CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/CLAUDE_PROJECT_DIR/CLAUDECODE and every
# OTHER inherited SB_* var before invoking each test — a developer's real shell
# config must not leak into a test that believes HOME-sandboxing is enough.
# SB_RUN_ALL_* / SB_EXPECTED_SKIPS are the runner's OWN knobs and must still
# pass through (asserted implicitly: run_suite already relies on
# SB_RUN_ALL_TESTS_DIR/SB_RUN_ALL_VITEST/SB_RUN_ALL_QUIET reaching run-all.sh).
D7="$TMP/case7"; mkdir -p "$D7"
cat > "$D7/test-env-sandbox.sh" <<'EOF'
#!/bin/bash
leaked=0
for v in BRAIN_DIR SB_BRAIN_DIR KNOWLEDGE_DIR CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR CLAUDE_PROJECT_DIR CLAUDECODE SB_MY_RANDOM_OVERRIDE; do
  val=$(eval "printf '%s' \"\${$v:-}\"")
  if [ -n "$val" ]; then
    echo "LEAKED: $v=$val"
    leaked=1
  fi
done
[ "$leaked" -eq 0 ] && echo "sandbox clean"
exit "$leaked"
EOF
OUT=$(BRAIN_DIR="/leak/brain" SB_BRAIN_DIR="/leak/sb-brain" KNOWLEDGE_DIR="/leak/knowledge" \
  CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="/leak/opt-knowledge" CLAUDE_PROJECT_DIR="/leak/proj" \
  CLAUDECODE=1 SB_MY_RANDOM_OVERRIDE="leak-value" \
  run_suite "$D7")
printf '%s\n' "$OUT" | grep -q 'EXIT=0' \
  || fail "run-all must scrub BRAIN_DIR/KNOWLEDGE_DIR/CLAUDE_*/SB_* overrides before invoking a test (D207): $OUT"
printf '%s\n' "$OUT" | grep -qE 'pass: *1($| )' \
  || fail "the sandboxed test should PASS once the overrides are scrubbed: $OUT"
pass "run-all scrubs dir-resolution vars + inherited SB_* overrides (D207)"

# --- Case 8: a tripped G3 suite guard fails the WHOLE run (R1 review) ------------------------
# lib.sh's suite guard no longer exits the sourcing script (that killed PreToolUse guards with no
# verdict): it quarantines the dir and writes the marker run-all hands every test in
# SB_SUITE_GUARD_MARKER. A test that otherwise PASSES must still turn the run red when the marker
# exists at the end, and the summary must say so. The inner run gets a scratch HOME, so the "real
# home" run-all passes on (SB_SUITE_REAL_HOME_PATH) is a scratch dir too.
D8="$TMP/case8"; mkdir -p "$D8" "$TMP/fakehome8"
cat > "$D8/test-plants-marker.sh" <<'EOF'
#!/bin/bash
[ -n "${SB_SUITE_GUARD_MARKER:-}" ] || { echo "no SB_SUITE_GUARD_MARKER from run-all"; exit 1; }
: > "$SB_SUITE_GUARD_MARKER"
echo "PASS: everything this test checks"
exit 0
EOF
OUT=$(HOME="$TMP/fakehome8" run_suite "$D8")
printf '%s\n' "$OUT" | grep -q 'EXIT=1' \
  || fail "a planted suite-guard marker must fail the whole run although every test passed: $OUT"
printf '%s\n' "$OUT" | grep -qi 'suite guard' \
  || fail "the summary must name the tripped suite guard: $OUT"
# End to end: a test that sources lib.sh with BRAIN_DIR = <real home>/.second-brain gets the
# quarantine (sourcing continues, the real dir is never created) and the run fails on the marker.
D8B="$TMP/case8b"; mkdir -p "$D8B" "$TMP/fakehome8b"
cat > "$D8B/test-leaks-real-brain.sh" <<EOF
#!/bin/bash
export BRAIN_DIR="\$SB_SUITE_REAL_HOME_PATH/.second-brain"
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib.sh"
echo "BRAIN_DIR=\$BRAIN_DIR"
case "\$BRAIN_DIR" in "\$SB_SUITE_REAL_HOME_PATH"*) echo "FAIL: lib.sh kept the real brain dir"; exit 1 ;; esac
exit 0
EOF
OUT=$(HOME="$TMP/fakehome8b" run_suite "$D8B")
printf '%s\n' "$OUT" | grep -q 'EXIT=1' && printf '%s\n' "$OUT" | grep -qi 'suite guard' \
  || fail "a test that sourced lib.sh with the real brain dir did not fail the run through the marker: $OUT"
[ ! -e "$TMP/fakehome8b/.second-brain" ] || fail "the quarantined run still created <real home>/.second-brain"
pass "a tripped suite guard (planted marker, or lib.sh quarantining a real brain dir) fails the whole run"

echo
echo "ALL PASS"
