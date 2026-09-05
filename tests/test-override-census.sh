#!/bin/bash
# Override census lock (post-audit improvement 4A, docs/plans/2026-09-05-post-audit-
# improvements.md §4). CONSTITUTION.md says "tests must not disable the thing they
# test" but had no gate: 44% of shell tests pin an SB_* override, and nothing
# distinguished "this override IS the feature under test" (a kill-switch test
# asserting =off) from "this override silently defeats the gate this test claims
# to exercise" (e.g. pinning a ratio/threshold to a value that can never fail).
#
# A source-scan lock, same doctrine as tests/test-script-portability.sh checks 8-12
# (a heuristic tripwire, not a parser): for every tests/test-*.sh, collect the SB_*
# names it ASSIGNS (a non-comment line shaped `SB_NAME=` — bare, `export`, `local`,
# or an inline env-prefix before a command all match). For every scripts/<name>.sh
# path the test's own source LITERALLY MENTIONS, collect the SB_* names that script
# itself READS (a non-comment line containing `$SB_NAME` / `${SB_NAME`). Any name in
# BOTH sets that the test does not declare in its own first 25 lines as
#   # pins: SB_NAME — <why>
# FAILS. This makes the exception visible and git-blameable, exactly like the
# existing `# run-all-timeout: N` declaration convention (tests/run-all.sh).
#
# Deliberately whitelist NOTHING here: every hit must be declared in the test file
# itself, not exempted in this scanner. "Reads as a gate/threshold" is treated as
# "the script under test reads this var at all" — narrower intent-classification
# (is it really a threshold vs. a path override) isn't reliably statically
# derivable, and a false negative here is worse than an occasional over-broad ask
# for a one-line declaration.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO/tests"
SELF="$(basename "$0")"

FAIL=0
DECLARED=0
declare -a FAILED_PAIRS=()

for t in "$TESTS_DIR"/test-*.sh; do
  base=$(basename "$t")
  [ "$base" = "$SELF" ] && continue

  # Names this test ASSIGNS (comment lines excluded — documentation mentioning
  # "SB_FOO=off" in prose must not count as a real override).
  assigned=$(grep -v '^[[:space:]]*#' "$t" 2>/dev/null | grep -oE 'SB_[A-Z0-9_]+=' | sed 's/=$//' | sort -u)
  [ -n "$assigned" ] || continue

  # scripts/<name>.sh paths this test's own source mentions.
  refs=$(grep -oE 'scripts/[A-Za-z0-9_-]+\.sh' "$t" 2>/dev/null | sort -u)
  [ -n "$refs" ] || continue

  # Names already declared as pins in this test's own first 25 lines.
  declared=$(head -25 "$t" | grep -oE '^#[[:space:]]*pins:[[:space:]]*SB_[A-Z0-9_]+' \
               | grep -oE 'SB_[A-Z0-9_]+' | sort -u)

  # Union of SB_* names actually READ across every referenced script.
  all_reads=""
  for rel in $refs; do
    script="$REPO/$rel"
    [ -f "$script" ] || continue
    r=$(grep -v '^[[:space:]]*#' "$script" 2>/dev/null \
          | grep -oE '\$\{?SB_[A-Z0-9_]+' | grep -oE 'SB_[A-Z0-9_]+')
    all_reads="$all_reads
$r"
  done
  all_reads=$(printf '%s\n' "$all_reads" | grep -v '^$' | sort -u)
  [ -n "$all_reads" ] || continue

  for name in $assigned; do
    printf '%s\n' "$all_reads" | grep -qxF "$name" || continue
    if printf '%s\n' "$declared" | grep -qxF "$name"; then
      DECLARED=$((DECLARED + 1))
    else
      echo "FAIL: $base assigns \$$name, which a script it references reads as a gate/threshold — declare '# pins: $name — <why>' in the first 25 lines"
      FAIL=$((FAIL + 1))
      FAILED_PAIRS+=("$base:$name")
    fi
  done
done

echo
echo "override census: $DECLARED declared pin(s) verified, $FAIL undeclared"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "UNDECLARED:"
  for p in "${FAILED_PAIRS[@]}"; do echo "  - $p"; done
  exit 1
fi
echo "ALL PASS"
exit 0
