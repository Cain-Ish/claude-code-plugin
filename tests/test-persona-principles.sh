#!/bin/bash
# Guard: the Four-Principles behavioral protocol exists, is complete, carries an extractable
# compact block, and is referenced by the using-second-brain skill (standing context).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
P="$ROOT/skills/using-second-brain/principles.md"
SK="$ROOT/skills/using-second-brain/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$P" ] || fail "principles.md missing"
for n in "Think Before Coding" "Simplicity First" "Surgical Changes" "Goal-Driven Execution"; do
  grep -qF "$n" "$P" || fail "principle missing: $n"
done
pass "all four principles present"
[ "$(grep -c 'Test:' "$P")" -ge 4 ] || fail "each principle needs a Test: line (>=4)"
pass "each principle has a Test:"
CB=$(awk '/<!-- compact:begin/{f=1;next}/<!-- compact:end/{f=0}f' "$P")
[ -n "$CB" ] || fail "compact block empty/missing"
[ "$(printf '%s\n' "$CB" | grep -c .)" -le 8 ] || fail "compact block too long (keep it terse)"
printf '%s' "$CB" | grep -qiE 'simplic|surgical|assumption|goal|test first' || fail "compact block missing principle keywords"
pass "compact block present + terse"
grep -q 'principles.md' "$SK" || fail "using-second-brain/SKILL.md does not reference principles.md"
pass "using-second-brain references principles.md (standing context)"
# Boundary: principles must NOT leak into the user identity card seeds (behavioral layer only).
for seed in "$ROOT/skills/setup/SKILL.md" "$ROOT/scripts/persona-context.sh"; do
  grep -qiE 'Simplicity First|Surgical Changes|Goal-Driven Execution' "$seed" 2>/dev/null \
    && fail "$(basename "$seed"): Four-Principles content leaked into a persona-card seed (behavioral != identity)"
done
pass "principles stay in the behavioral layer, not the identity persona-card seeds"
echo; echo "ALL PASS"
