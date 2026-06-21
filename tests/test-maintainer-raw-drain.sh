#!/bin/bash
# Guard: the knowledge-maintainer DELEGATES the raw-inbox drain (Phase 4c) to the
# /second-brain:maintain skill's looped raw-drainer worker — it no longer drains in-context
# (the in-context loop truncated after 1–3 large items). This test pins the delegation and
# guards against re-introducing the in-context drain loop, while keeping the conservative /
# provenance / explicit-only invariants documented.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
A="$ROOT/agents/knowledge-maintainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$A" ] || fail "knowledge-maintainer.md missing"
grep -q 'Phase 4c' "$A" || fail "no Phase 4c (raw-inbox drain) section"
pass "Phase 4c section present"

# DELEGATION: Phase 4c must point at the raw-drainer loop and say it does NOT drain in-context.
grep -qE 'raw-drainer' "$A" || fail "Phase 4c does not delegate to the raw-drainer worker"
grep -qiE 'do not drain|do NOT drain|delegated|not run in-context' "$A" \
  || fail "Phase 4c does not state the maintainer skips the in-context drain"
pass "Phase 4c delegates to the raw-drainer loop (no in-context drain)"

# REGRESSION GUARD: the maintainer must NOT carry the in-context drain CLI loop anymore
# (re-adding it would reintroduce the truncation this change fixed).
if grep -q 'raw-capture-cli.bundle.js' "$A"; then
  fail "maintainer still invokes raw-capture-cli.bundle.js — the in-context drain loop must move to raw-drainer"
fi
if grep -qE 'process <id> --node' "$A"; then
  fail "maintainer still contains 'process <id> --node' — the in-context drain loop must move to raw-drainer"
fi
pass "no in-context drain CLI loop remains in the maintainer"

# The agent still shells to `node …bundle.js` for the Phase 4b ai-block render, so Bash(node *) stays.
grep -qE '^tools:.*Bash\(node ' "$A" || fail "maintainer tools: missing Bash(node *) (needed for ai-block render)"
pass "maintainer still grants Bash(node *) for Phase 4b"

# Conservative policy + provenance contract stay documented (the worker honors them; reconcile
# depends on the back-ref format).
grep -qiE 'never .*discard|do not .*discard|left .*unprocessed' "$A" \
  || fail "Phase 4c missing the conservative never-auto-discard rule"
grep -qE 'captured from .*\(raw ' "$A" || fail "Phase 4c missing the 'captured from … (raw <id>)' provenance format"
pass "Phase 4c documents conservative policy + provenance back-ref format"

# explicit-only boundary still stated for the drain.
grep -qiE 'explicit-invocation only|explicit.*Phase 4c|Phase 4c.*explicit' "$A" \
  || fail "Phase 4c missing the explicit-only boundary"
pass "raw drain is explicit-invocation only"

# Phase-count must not be stale: there is no 'Phase 6'. (ASCII boundary, not GNU \b — house rule.)
if grep -qE 'Phase 6([^0-9]|$)' "$A"; then fail "stale phase reference (there is no Phase 6)"; fi
pass "no stale 'Phase 6' reference"

# The frontmatter description must NOT advertise the maintainer running the raw-inbox drain as a
# cycle phase — it's delegated to the raw-drainer worker. Guard the stale "Raw-inbox drain (4c) →"
# arrow-chain (the medium-severity stale-description regression).
if grep -qE 'Raw-inbox drain \(4c\) →' "$A"; then
  fail "frontmatter still lists 'Raw-inbox drain (4c) →' as a maintainer cycle phase (delegated now)"
fi
pass "frontmatter does not advertise the maintainer draining the inbox"

echo; echo "ALL PASS"
