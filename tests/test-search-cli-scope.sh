#!/bin/bash
# Guard: the search CLI forwards project context (SB_ACTIVE_SLUG + BRAIN_DIR) so the per-prompt
# persona injection is project-scoped (SP-1), and persona-context.sh exports SB_ACTIVE_SLUG.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI_SRC="$ROOT/mcp/src/tools/knowledge-search-cli.ts"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
grep -q 'SB_ACTIVE_SLUG' "$CLI_SRC" || fail "CLI does not read SB_ACTIVE_SLUG"
grep -q 'projectSlug' "$CLI_SRC" || fail "CLI does not pass projectSlug"
pass "search CLI forwards project context (source)"
grep -q 'SB_ACTIVE_SLUG' "$ROOT/scripts/persona-context.sh" || fail "persona-context.sh does not export SB_ACTIVE_SLUG"
pass "persona-context.sh exports SB_ACTIVE_SLUG"
# SP-1 W1: the session-start wiki enrichment must be scoped the same as the per-prompt path.
grep -q 'SB_ACTIVE_SLUG=.*node "\$SEARCH_CLI"' "$ROOT/scripts/session-load.sh" \
  || fail "session-load.sh does not forward SB_ACTIVE_SLUG to the search CLI"
pass "session-load.sh scopes the session-start wiki enrichment"
# functional (skips if node / bundle absent): beta page suppressed under SB_ACTIVE_SLUG=alpha
command -v node >/dev/null 2>&1 || { echo "SKIP: node"; echo; echo "ALL PASS"; exit 0; }
[ -f "$CLI" ] || { echo "SKIP: CLI bundle not built — run cd mcp && npm run build"; echo; echo "ALL PASS"; exit 0; }
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
for s in a1 a2 a3; do printf '%s\n' '---' "title: $s" 'type: learnings' 'project: alpha' '---' "# $s" "wireguard tunnel keyword $(printf 'd %.0s' $(seq 1 40))" > "$KD/wiki/learnings/$s.md"; done
printf '%s\n' '---' 'title: b1' 'type: learnings' 'project: beta' '---' '# b1' "wireguard tunnel keyword $(printf 'd %.0s' $(seq 1 40))" > "$KD/wiki/learnings/b1.md"
OUT=$(KNOWLEDGE_DIR="$KD" BRAIN_DIR="$TMP/.second-brain" SB_ACTIVE_SLUG="alpha" node "$CLI" "wireguard tunnel" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'b1' && fail "beta page not suppressed under SB_ACTIVE_SLUG=alpha"
printf '%s' "$OUT" | grep -qE 'a1|a2|a3' || fail "alpha pages missing"
pass "CLI scopes to the active project (beta suppressed, alpha kept)"
rm -rf "$TMP"
echo; echo "ALL PASS"
