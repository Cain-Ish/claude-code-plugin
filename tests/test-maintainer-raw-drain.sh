#!/bin/bash
# Guard: the knowledge-maintainer agent has a Phase 4c raw-inbox drain wired to the SP-2 CLI,
# conservative (never auto-discard), explicit-only, with provenance.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
A="$ROOT/agents/knowledge-maintainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$A" ] || fail "knowledge-maintainer.md missing"
grep -q 'Phase 4c' "$A" || fail "no Phase 4c (raw-inbox drain) section"
grep -q 'raw-capture-cli.bundle.js' "$A" || fail "Phase 4c does not invoke raw-capture-cli"
grep -qw 'pending' "$A" || fail "Phase 4c missing the pending work-list"
grep -qE 'process <id>|process \$' "$A" || fail "Phase 4c missing the process action"
pass "Phase 4c invokes pending work-list + process"

grep -qiE 'never .*discard|do not .*discard|left .*unprocessed' "$A" \
  || fail "Phase 4c missing the conservative never-auto-discard rule"
pass "Phase 4c states the conservative (no auto-discard) policy"

grep -q '## Sources' "$A" || fail "Phase 4c missing the ## Sources provenance"
pass "Phase 4c records ## Sources provenance"

# explicit-only boundary appears for Phase 4c (the section names itself alongside 4b)
grep -qiE 'Phase 4c.*explicit|explicit.*Phase 4c|4b/4c|4b and 4c|4b, 4c' "$A" \
  || grep -qiE 'explicit-invocation only' "$A" \
  || fail "Phase 4c missing the explicit-only boundary"
pass "Phase 4c is explicit-invocation only"

echo; echo "ALL PASS"
