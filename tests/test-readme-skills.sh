#!/bin/bash
# Guard: the SP-2/SP-5 command skills (/second-brain:capture, /second-brain:maintain) are documented
# in the README skill table. They shipped but were initially missing — README drift caught by the
# 0.24.16 whole-product audit. Keep this list in sync if new user-command skills are added.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; README="$ROOT/README.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
for s in capture maintain; do
  [ -f "$ROOT/skills/$s/SKILL.md" ] || fail "skills/$s/SKILL.md missing (test stale?)"
  grep -q "second-brain:$s" "$README" || fail "README does not document /second-brain:$s"
done
pass "README documents /second-brain:capture and /second-brain:maintain"
echo; echo "ALL PASS"

# R6: the 5 de-vendored skills must not be sold as live /second-brain:* commands.
for s in brainstorming writing-plans test-driven-development verification-before-completion systematic-debugging; do
  grep -q "/second-brain:$s" "$ROOT/README.md" \
    && { echo "FAIL: README lists deleted skill /second-brain:$s (de-vendored in 0.24.42)"; exit 1; }
done
echo "PASS: no de-vendored skills in README"
