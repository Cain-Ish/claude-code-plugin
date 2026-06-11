#!/bin/bash
# Guard: code-review-deep SKILL.md wires the runtime-premise lens end to end.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/code-review-deep/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$S" ] || fail "SKILL.md missing"

grep -q 'code-review-premise-reviewer' "$S" || fail "Pass 2d must dispatch the premise reviewer"
grep -qE '## Pass 2d' "$S" || fail "missing '## Pass 2d' heading"
grep -qE '## Pass 3\.5' "$S" || fail "missing '## Pass 3.5' heading"
pass "Pass 2d + Pass 3.5 headings + dispatch present"

grep -qi 'is_bugfix' "$S" || fail "Pass 0 must classify is_bugfix"
pass "is_bugfix classification present"

grep -qiE 'real env|real runtime' "$S" || fail "Pass 3.5 must probe in the real env"
grep -qiE 'failure.regime|failure case|false regime|UNSET' "$S" || fail "Pass 3.5 must check a failure-regime test"
pass "Pass 3.5 real-env probe + failure-regime test check present"

grep -q 'review-fragile-premises' "$S" || fail "Pass 0 must read review-fragile-premises.md"
pass "fragile-premises support note wired"

# the carve-out: the don't-run-the-app note acknowledges Pass 3.5
awk '/Do not build/,/Pass 3\.5|premise/' "$S" | grep -qiE '3\.5|premise' \
  || fail "the 'don't run the app' note must carve out Pass 3.5"
pass "don't-run-the-app carve-out for Pass 3.5 present"

echo; echo "ALL PASS"
