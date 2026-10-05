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

# The hook wraps long env-prefixed calls with a trailing backslash, so a one-line grep misses the
# call once it is split. Join every backslash-continued line first (portable awk: no gawk-isms).
JOINED=$(awk '{ if (sub(/\\[[:space:]]*$/, "")) { buf = buf $0 " "; next } print buf $0; buf = "" } END { if (buf != "") print buf }' "$PERSONA")
EPI_CALL=$(printf '%s\n' "$JOINED" | grep -E 'node "\$EPISODIC_CLI"')
[ -n "$EPI_CALL" ] || fail "persona-context.sh has no node \"\$EPISODIC_CLI\" call (even after joining continuations)"
printf '%s\n' "$EPI_CALL" | grep -qE 'SB_ACTIVE_SLUG=.*node "\$EPISODIC_CLI"' \
  || fail "persona-context.sh does not forward SB_ACTIVE_SLUG to the episodic CLI"
printf '%s\n' "$EPI_CALL" | grep -qE 'SB_SESSION_ID="\$SESSION_ID".*node "\$EPISODIC_CLI"' \
  || fail "persona-context.sh does not forward SB_SESSION_ID to the episodic CLI (same-session rows would echo back)"
pass "persona-context.sh scopes the per-prompt episodic hint (SB_ACTIVE_SLUG + SB_SESSION_ID)"

# R1#4: the wiki fallback (no combined bundle) injects into the prompt like the combined CLI, so it
# must ask knowledge-search-cli for the per-prompt gate (stubs refused, cross-project rule).
SEARCH_CALL=$(printf '%s\n' "$JOINED" | grep -E 'node "\$SEARCH_CLI"')
[ -n "$SEARCH_CALL" ] || fail "persona-context.sh has no node \"\$SEARCH_CLI\" fallback call"
printf '%s\n' "$SEARCH_CALL" | grep -qE '(^|[[:space:](])SB_INJECT_GATE=1 .*node "\$SEARCH_CLI"' \
  || fail "the knowledge-search-cli fallback in persona-context.sh does not set SB_INJECT_GATE=1 (it would inject stubs per prompt)"
pass "persona-context.sh's wiki fallback takes the per-prompt injection gate (SB_INJECT_GATE=1)"

echo; echo "ALL PASS"
