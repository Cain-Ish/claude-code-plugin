#!/bin/bash
# Guard: /second-brain:maintain exists as a user-invocable skill that dispatches the
# knowledge-maintainer agent for an explicit full run (the path that runs Phase 4b/4c).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/maintain/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$S" ] || fail "skills/maintain/SKILL.md missing"
grep -q '^name: maintain$' "$S" || fail "name is not 'maintain'"
grep -q '^user-invocable: true$' "$S" || fail "not user-invocable"
grep -qE '^allowed-tools:.*\bAgent\b' "$S" || fail "allowed-tools must include Agent (to dispatch the agent)"
pass "maintain skill is user-invocable + declares Agent"

grep -q 'knowledge-maintainer' "$S" || fail "body does not dispatch the knowledge-maintainer agent"
grep -qE '4c|raw[- ]inbox' "$S" || fail "body does not mention the explicit-only Phase 4c (raw drain)"
pass "maintain dispatches the knowledge-maintainer agent (explicit run, names 4c)"

echo; echo "ALL PASS"
