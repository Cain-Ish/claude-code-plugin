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
D2="$TMP/case2"; mkdir -p "$D2"
cat > "$D2/test-pure-skip.sh" <<'EOF'
#!/bin/bash
echo "SKIP: feature unavailable on this platform"
exit 0
EOF
OUT=$(run_suite "$D2")
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

echo
echo "ALL PASS"
