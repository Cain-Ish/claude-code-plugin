#!/bin/bash
# Guard: the per-prompt "[Past sessions]" episodic hint is project-scoped (SP-1 parity),
# so cross-project session memory does not leak into every prompt's context.
# The episodic CLI must read SB_ACTIVE_SLUG and pass it as activeProject, and
# persona-context.sh must forward SB_ACTIVE_SLUG to that CLI (as it already does
# for the knowledge-search CLI). Behavior is covered by the vitest unit test
# mcp/src/tools/episodic-search-scope.test.ts; this guards the wiring.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI_SRC="$ROOT/mcp/src/tools/episodic-search-cli.ts"
PERSONA="$ROOT/scripts/persona-context.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$CLI_SRC" ] || fail "episodic-search-cli.ts not found"
grep -q 'SB_ACTIVE_SLUG' "$CLI_SRC" || fail "episodic CLI does not read SB_ACTIVE_SLUG"
grep -q 'activeProject' "$CLI_SRC" || fail "episodic CLI does not pass activeProject"
pass "episodic CLI forwards active-project scope (source)"

grep -qE 'SB_ACTIVE_SLUG=.*node "\$EPISODIC_CLI"' "$PERSONA" \
  || fail "persona-context.sh does not forward SB_ACTIVE_SLUG to the episodic CLI"
pass "persona-context.sh scopes the per-prompt episodic hint"

echo; echo "ALL PASS"
