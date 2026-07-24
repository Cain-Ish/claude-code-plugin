#!/usr/bin/env bash
# Aggregate test runner for the second-brain plugin.
#
# Runs every `tests/test-*.sh` script plus the Vitest suite under `mcp/`.
# Prints a per-test verdict + summary, exits non-zero on any failure.
#
# Use this from CI, from a `.githooks/pre-push` gate, or by hand before
# tagging a release. The contract: a release tag is valid ONLY when this
# script exits 0 with all green.
#
# Env knobs:
#   SB_RUN_ALL_QUIET=1   suppress per-test stdout (just show verdicts)
#   SB_RUN_ALL_VITEST=0  skip the mcp/ vitest suite (default: run it)
#   SB_RUN_ALL_TIMEOUT=N per-test timeout in seconds (default: 120)
#   SB_EXPECTED_SKIPS="a b"  space/comma list of test names (no .sh) EXPECTED to
#                        whole-file-SKIP on this host. Setting it (even to "")
#                        ARMS the false-green guard: any UNEXPECTED skip then fails
#                        the suite. Unset + no per-platform default = warn-only.
#                        See the expected-skips reconciliation block near the end.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SB_RUN_ALL_TESTS_DIR overrides the shell-test directory (defaults to the
# repo's tests/). Used by test-run-all-skip-semantics.sh to point the runner at
# a fixture dir; production runs never set it.
TESTS_DIR="${SB_RUN_ALL_TESTS_DIR:-$ROOT/tests}"
MCP_DIR="$ROOT/mcp"
QUIET="${SB_RUN_ALL_QUIET:-0}"
RUN_VITEST="${SB_RUN_ALL_VITEST:-1}"
PER_TEST_TIMEOUT="${SB_RUN_ALL_TIMEOUT:-120}"
SUITE_T0=$(date +%s)

# R8 structural isolation: every test runs under a PER-TEST temp HOME so a
# test that FORGETS its own sandbox cannot touch the real KB (the 0.24.32
# tmp.* leak class). HOME alone is enough: BRAIN_DIR and KNOWLEDGE_DIR both
# derive from $HOME when unset, so test-local derivations keep working —
# presetting those two directly would OVERRIDE tests that sandbox HOME and
# rely on the derivation (5 tests broke that way in the first cut). Tests
# that need the real HOME read SB_SUITE_REAL_HOME_PATH.
SUITE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sb-suite-home.XXXXXX")
trap 'rm -rf "$SUITE_SANDBOX"' EXIT

# Color codes (skipped if not a TTY).
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_RST=''
fi

PASS=0
FAIL=0
SKIP=0
declare -a FAILED_TESTS=()
declare -a SKIPPED_TESTS=()

print_header() {
  echo "${C_BOLD}=== second-brain test suite ===${C_RST}"
  echo "root: $ROOT"
  echo "per-test timeout: ${PER_TEST_TIMEOUT}s"
  echo
}

run_one_sh() {
  local script="$1"
  local name; name=$(basename "$script" .sh)
  local logfile; logfile=$(mktemp)
  local started; started=$(date +%s)
  local ec=0

  # (R6 sweep: the chmod +x block was deleted — tests are invoked via `bash`
  # below, so the exec bit was never used, and the chmod dirtied the working
  # tree on every suite run. Exec bits are git-recorded; test-exec-bits gates.)

  # R8: per-test temp HOME (see header). The real HOME is passed through as
  # SB_SUITE_REAL_HOME_PATH for tests that genuinely need it.
  local iso_home="$SUITE_SANDBOX/$(basename "$script" .sh)"
  mkdir -p "$iso_home"
  local -a iso_env=(
    "SB_SUITE_REAL_HOME_PATH=$HOME"
    "HOME=$iso_home"
  )
  if command -v timeout >/dev/null 2>&1; then
    env "${iso_env[@]}" timeout "$PER_TEST_TIMEOUT" bash "$script" >"$logfile" 2>&1; ec=$?
  else
    env "${iso_env[@]}" bash "$script" >"$logfile" 2>&1; ec=$?
  fi
  local elapsed=$(( $(date +%s) - started ))

  # Detect the whole-file SKIP convention used by some existing tests.
  # CRITICAL: only honor SKIP when the test also EXITED 0. A test that prints a
  # mid-run "SKIP:" line for one optional subtest and then FAILS a real
  # assertion (exit != 0) must count as FAIL, not SKIP — otherwise a genuine
  # failure (e.g. a security-check regression on Windows, which has no CI lane)
  # is silently reclassified as SKIP and the suite reports ALL GREEN. The grep
  # must NOT precede the exit-code gate. ('[: ]', not '[:\s]': in ERE the class
  # [:\s] is the literal set {':','\','s'} — it never matched a space.)
  if [ "$ec" -eq 0 ] && grep -qE '^SKIP[: ]' "$logfile" 2>/dev/null; then
    SKIP=$((SKIP+1))
    SKIPPED_TESTS+=("$name")
    printf '  %sSKIP%s  %-50s %ds\n' "$C_YELLOW" "$C_RST" "$name" "$elapsed"
    [ "$QUIET" = "1" ] || sed 's/^/         /' "$logfile" | head -5
    rm -f "$logfile"
    return 0
  fi

  if [ "$ec" -eq 0 ]; then
    PASS=$((PASS+1))
    printf '  %sPASS%s  %-50s %ds\n' "$C_GREEN" "$C_RST" "$name" "$elapsed"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
    printf '  %sFAIL%s  %-50s %ds (ec=%d)\n' "$C_RED" "$C_RST" "$name" "$elapsed" "$ec"
    sed 's/^/         /' "$logfile" | tail -40
  fi
  rm -f "$logfile"
}

print_header

echo "${C_BOLD}--- shell tests ($TESTS_DIR/test-*.sh) ---${C_RST}"
shopt -s nullglob
for script in "$TESTS_DIR"/test-*.sh; do
  # Skip the runner itself if someone named one test-run-all.sh
  [ "$script" = "$TESTS_DIR/run-all.sh" ] && continue
  run_one_sh "$script"
done
shopt -u nullglob
echo

if [ "$RUN_VITEST" = "1" ] && [ -d "$MCP_DIR" ] && [ -f "$MCP_DIR/package.json" ]; then
  echo "${C_BOLD}--- vitest ($MCP_DIR) ---${C_RST}"
  vitest_log=$(mktemp)
  vitest_ec=0
  # R8: vitest gets the same sandbox-HOME treatment as the bash lane (mcp/src
  # resolves os.homedir() in 10+ modules; today's tests are mkdtemp-hermetic,
  # this keeps a future homedir()-touching test from re-opening the leak).
  VITEST_HOME="$SUITE_SANDBOX/vitest-home"; mkdir -p "$VITEST_HOME"
  if command -v timeout >/dev/null 2>&1; then
    (cd "$MCP_DIR" && env "SB_SUITE_REAL_HOME_PATH=$HOME" "HOME=$VITEST_HOME" timeout "$PER_TEST_TIMEOUT" npx vitest run --reporter=default) >"$vitest_log" 2>&1
  else
    (cd "$MCP_DIR" && env "SB_SUITE_REAL_HOME_PATH=$HOME" "HOME=$VITEST_HOME" npx vitest run --reporter=default) >"$vitest_log" 2>&1
  fi
  vitest_ec=$?
  if [ "$vitest_ec" -eq 0 ]; then
    PASS=$((PASS+1))
    tests_line=$(grep -E '^\s*Tests' "$vitest_log" | tail -1)
    printf '  %sPASS%s  %-50s  %s\n' "$C_GREEN" "$C_RST" "vitest (mcp)" "$tests_line"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("vitest")
    printf '  %sFAIL%s  %-50s  (ec=%d)\n' "$C_RED" "$C_RST" "vitest (mcp)" "$vitest_ec"
    tail -50 "$vitest_log" | sed 's/^/         /'
  fi
  rm -f "$vitest_log"
  echo
fi

echo "${C_BOLD}--- summary ---${C_RST}"
echo "  pass: $PASS"
echo "  fail: $FAIL"
echo "  skip: $SKIP"
# R8: wall time in the summary (recorded Pi 5 baseline: ~156s full suite) so a
# perf regression is visible at a glance, not only by forensic timing.
echo "  wall: $(( $(date +%s) - SUITE_T0 ))s"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "${C_RED}FAILED:${C_RST}"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
# --- expected-skips reconciliation (false-green guard) -----------------------
# A test that SKIPs when it should have RUN silently hides a real failure — the
# Windows-no-CI-lane risk. Reconcile the ACTUAL whole-file skips against a per-host
# allowlist. The guard is ARMED when SB_EXPECTED_SKIPS is set (even to ""), or when
# a per-platform default below is pinned; an UNEXPECTED skip then fails the suite.
# UNARMED (no observed baseline for this OS) → skips are WARN-ONLY: a spurious
# hard-fail is worse than a missed skip, and we cannot observe every OS from here.
#
# To arm a platform: observe its real skip set, then pin the kebab test names (no
# .sh) into its case arm. Derive candidates WITHOUT running the full suite:
#   grep -nE '^[[:space:]]*echo "SKIP[: ]' tests/test-*.sh
# A whole-file skip prints a COLUMN-0 'SKIP:'/'SKIP ' line and exits 0. Tool-absence
# skips (node/jq/python/esbuild/bundles) don't fire on a provisioned box.
# Windows (MINGW*/MSYS*/CYGWIN*) is ARMED below with its observed skip set
# (dream lifecycle/accept-guard + real-symlink skips); Linux, Darwin, and the
# fallback arm remain UNARMED (__unset__) — their skip sets were never measured.
EXPECTED_SKIPS_ARMED=0
if [ "${SB_EXPECTED_SKIPS+set}" = "set" ]; then
  EXPECTED_SKIPS_LIST="$SB_EXPECTED_SKIPS"; EXPECTED_SKIPS_ARMED=1
else
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux)                EXPECTED_SKIPS_LIST="__unset__" ;;
    Darwin)               EXPECTED_SKIPS_LIST="__unset__" ;;
    MINGW*|MSYS*|CYGWIN*) EXPECTED_SKIPS_LIST="test-dream-accept-guards test-dream-lifecycle test-symlink-guard" ;;
    *)                    EXPECTED_SKIPS_LIST="__unset__" ;;
  esac
  [ "$EXPECTED_SKIPS_LIST" != "__unset__" ] && EXPECTED_SKIPS_ARMED=1
fi

if [ "$SKIP" -gt 0 ]; then
  EXP_NORM=" $(printf '%s' "${EXPECTED_SKIPS_LIST:-}" | tr ',' ' ') "
  declare -a UNEXPECTED_SKIPS=()
  for t in "${SKIPPED_TESTS[@]}"; do
    case "$EXP_NORM" in
      *" $t "*) : ;;                      # allowlisted → expected
      *) UNEXPECTED_SKIPS+=("$t") ;;
    esac
  done
  if [ "$EXPECTED_SKIPS_ARMED" = "1" ] && [ "${#UNEXPECTED_SKIPS[@]}" -gt 0 ]; then
    echo
    echo "${C_RED}UNEXPECTED SKIP(S):${C_RST} a test that should have run was skipped (false-green class)."
    for t in "${UNEXPECTED_SKIPS[@]}"; do echo "  - $t"; done
    echo "  Host: $(uname -s 2>/dev/null || echo unknown). If these ARE expected here, pin them in"
    echo "  run-all.sh's per-platform manifest or set SB_EXPECTED_SKIPS."
    exit 1
  elif [ "$EXPECTED_SKIPS_ARMED" != "1" ]; then
    echo
    echo "${C_YELLOW}note:${C_RST} expected-skips guard UNARMED for $(uname -s 2>/dev/null || echo unknown) — the $SKIP skip(s) below are warn-only."
    echo "  Arm it via SB_EXPECTED_SKIPS or a pinned per-platform list in run-all.sh."
  fi
fi

if [ "$SKIP" -gt 0 ]; then
  echo
  echo "${C_YELLOW}skipped:${C_RST}"
  for t in "${SKIPPED_TESTS[@]}"; do echo "  - $t"; done
fi
echo "${C_GREEN}ALL GREEN${C_RST}"
exit 0
