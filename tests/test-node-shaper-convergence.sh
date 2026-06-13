#!/usr/bin/env bash
# Node-shape convergence: the dream and the maintainer must shape nodes through
# the SAME knowledge_validate autofix. sb_validate_wiki(dir) lets the dream run
# that shaper on its STAGING dir (the MCP tool is pinned to the live KNOWLEDGE_DIR).
# This proves the helper normalizes malformed frontmatter AND patches incomplete
# frontmatter on an arbitrary dir — the mechanism dream-accept.sh uses pre-merge.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -f "$REPO_ROOT/mcp/dist/tools/knowledge-validate.bundle.js" ] || { echo "SKIP: validate bundle not built"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wiki/entities"
# malformed: bracketless multi-item related:
printf '%s\n' '---' 'title: A' 'type: entities' 'related: [[x]], [[y]]' '---' '# A' 'body' > "$T/wiki/entities/a.md"
# incomplete: missing created/updated/tags/related/description
printf '%s\n' '---' 'title: B' 'type: entities' '---' '# B' 'body' > "$T/wiki/entities/b.md"
# clean+complete: must be left untouched
printf '%s\n' '---' 'title: C' 'description: ""' 'type: entities' 'created: 2026-01-01' 'updated: 2026-01-01' 'tags: []' 'related: []' '---' '# C' 'body' > "$T/wiki/entities/c.md"
C_BEFORE=$(cat "$T/wiki/entities/c.md")

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "source '$REPO_ROOT/scripts/lib.sh'; sb_validate_wiki '$T' >/dev/null 2>&1"

grep -q '^related: \[x, y\]$' "$T/wiki/entities/a.md" || fail "malformed related: not normalized to β (got: $(grep '^related:' "$T/wiki/entities/a.md"))"
grep -qv '\[\[' "$T/wiki/entities/a.md" && pass "(a) malformed frontmatter normalized to β on the staging dir"

for k in description created updated tags related; do
  grep -q "^$k:" "$T/wiki/entities/b.md" || fail "incomplete page not patched — missing $k"
done
pass "(b) incomplete frontmatter patched with all required fields"
grep -q '^updated: ' "$T/wiki/entities/b.md" || fail "updated not added"

[ "$(cat "$T/wiki/entities/c.md")" = "$C_BEFORE" ] || fail "(c) clean+complete page was modified (should be untouched)"
pass "(c) clean+complete page left byte-identical (idempotent)"

# idempotency: a second pass changes nothing
A2=$(cat "$T/wiki/entities/a.md"); B2=$(cat "$T/wiki/entities/b.md")
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "source '$REPO_ROOT/scripts/lib.sh'; sb_validate_wiki '$T' >/dev/null 2>&1"
[ "$(cat "$T/wiki/entities/a.md")" = "$A2" ] && [ "$(cat "$T/wiki/entities/b.md")" = "$B2" ] \
  || fail "second pass changed a previously-shaped page (not idempotent)"
pass "(d) shaper is idempotent across runs"

echo "ALL PASS"
