#!/bin/bash
# Guard: the raw-drainer agent is a lean, bounded, resumable one-batch drain worker that the
# /second-brain:maintain skill loops in fresh contexts (the truncation-safe drain). It must
# reconcile-first, bound its batch, drain conservatively with provenance, and report a parseable
# DRAINED/REMAINING line the skill loop keys on.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
A="$ROOT/agents/raw-drainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$A" ] || fail "agents/raw-drainer.md missing"
grep -qE '^name: raw-drainer$' "$A" || fail "frontmatter name is not 'raw-drainer'"
pass "raw-drainer agent exists with correct name"

# Shells out to `node …bundle.js` (CLI) and `bash …/scripts/*` (reconcile) — both must be in the
# tool allowlist or pending/process/reconcile prompt-or-deny and the drain stalls.
grep -qE '^tools:.*Bash\(node ' "$A" || fail "tools: missing Bash(node *) for the CLI calls"
grep -qE '^tools:.*Bash\(bash \$\{CLAUDE_PLUGIN_ROOT\}/scripts/\*\)' "$A" \
  || fail "tools: missing Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/*) for reconcile"
pass "raw-drainer grants Bash(node *) + Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/*)"

# Reconcile FIRST (recover a prior truncated batch before fetching the work-list).
grep -q 'kb-drain-reconcile.sh' "$A" || fail "does not run kb-drain-reconcile.sh"
grep -qiE 'reconcile (first|before)|BEFORE fetching' "$A" || fail "does not reconcile BEFORE pending"
pass "reconciles first (prior-truncation recovery)"

# Work-list + per-item processing via the SP-2 CLI.
grep -q 'raw-capture-cli.bundle.js' "$A" || fail "does not invoke raw-capture-cli"
grep -qw 'pending' "$A" || fail "missing the pending work-list"
grep -qE 'process <id> --node' "$A" || fail "missing the process <id> --node invocation"
pass "drains via pending work-list + process <id> --node"

# Bounded batch — the whole point (a fresh context per batch can't truncate the whole drain).
grep -qE 'SB_DRAIN_BATCH' "$A" || fail "no SB_DRAIN_BATCH batch bound (would drain unbounded → truncate)"
grep -qiE 'at most|up to .*items|bounded' "$A" || fail "does not state a per-dispatch item cap"
pass "bounds the batch (SB_DRAIN_BATCH)"

# Conservative — never auto-discard.
grep -qiE 'never .*discard|do not .*discard|left .*unprocessed' "$A" \
  || fail "missing the conservative never-auto-discard rule"
pass "states the conservative (no auto-discard) policy"

# Provenance back-ref the reconcile depends on (exact format).
grep -qE 'captured from .*\(raw ' "$A" || fail "missing the 'captured from … (raw <id>)' provenance"
pass "records source provenance on the node"

# Binary/blob items must not be fabricated from the placeholder.
grep -qiE 'blob|binary' "$A" || fail "does not handle binary/blob items"
pass "handles binary/blob items"

# Closed vocabulary + no-invent discipline.
grep -qiE 'never invent|do not invent' "$A" || fail "missing the never-invent authoring discipline"
pass "states the never-invent discipline"

# The REQUIRED report contract the maintain skill loop parses.
grep -qE 'DRAINED:' "$A" || fail "missing the DRAINED: report token"
grep -qE 'REMAINING:' "$A" || fail "missing the REMAINING: report token"
pass "emits the DRAINED/REMAINING loop-control report line"

# Opt-in audit-trail prune (default OFF): honors SB_RAW_PRUNE_AFTER_DRAIN and calls prune-processed.
grep -q 'SB_RAW_PRUNE_AFTER_DRAIN' "$A" || fail "missing the opt-in SB_RAW_PRUNE_AFTER_DRAIN prune step"
grep -q 'prune-processed' "$A" || fail "opt-in prune step does not invoke prune-processed"
pass "honors the opt-in SB_RAW_PRUNE_AFTER_DRAIN audit-trail prune"

echo; echo "ALL PASS"
