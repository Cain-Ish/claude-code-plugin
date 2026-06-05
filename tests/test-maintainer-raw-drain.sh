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
grep -qE 'process <id> --node <slug>' "$A" || fail "Phase 4c missing the exact process invocation"
pass "Phase 4c invokes pending work-list + process <id> --node <slug>"

# The agent shells out to `node …bundle.js`, so its tool allowlist must grant Bash(node *)
# (else pending/process prompt-or-deny → items never flip to processed → re-drained duplicates).
grep -qE '^tools:.*Bash\(node ' "$A" || fail "maintainer tools: missing Bash(node *) for the CLI calls"
pass "maintainer grants Bash(node *)"

grep -qiE 'never .*discard|do not .*discard|left .*unprocessed' "$A" \
  || fail "Phase 4c missing the conservative never-auto-discard rule"
pass "Phase 4c states the conservative (no auto-discard) policy"

# Phase-4c-specific provenance line (NOT the pre-existing '### Sources' ENRICH heading).
grep -qE 'captured from .*\(raw ' "$A" || fail "Phase 4c missing the 'captured from … (raw <id>)' provenance"
pass "Phase 4c records source provenance on the node"

# Phase 4c must handle BINARY-blob items (PDF/image): the .md body is only a placeholder; the bytes
# live in the sibling blob. The agent must NOT fabricate content from the placeholder.
grep -qiE 'blob|binary' "$A" || fail "Phase 4c does not handle binary/blob items (would mis-author a PDF/image)"
pass "Phase 4c handles binary/blob items"

# Phase-count must not be stale: there is no 'Phase 6' (the phases are 0,1,2,3,4,4b,4c,5).
if grep -qE '1[–-]4, 5, 6|Phase 6\b' "$A"; then fail "stale phase reference (there is no Phase 6)"; fi
pass "no stale 'Phase 6' reference"

# explicit-only boundary appears for Phase 4c (the section names itself alongside 4b)
grep -qiE 'Phase 4c.*explicit|explicit.*Phase 4c|4b/4c|4b and 4c|4b, 4c' "$A" \
  || grep -qiE 'explicit-invocation only' "$A" \
  || fail "Phase 4c missing the explicit-only boundary"
pass "Phase 4c is explicit-invocation only"

echo; echo "ALL PASS"
