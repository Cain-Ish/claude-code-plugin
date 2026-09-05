#!/bin/bash
# Guard: ensure-dirs.sh's SessionStart wiki bootstrap actually reindexes (builds wiki/index.md).
# Regression D1 (0.24.17): ensure-dirs.sh carried a DUPLICATE of the reindex-ESM-import bug — a
# static `import { x } from process.env.SB_BUNDLE` that SyntaxErrors and was swallowed by
# `2>/dev/null || true`, so the auto-reindex/validate was silently dead. The fix was already
# applied to lib.sh (sb_reindex_wiki, dynamic import) but this copy was missed. Now ensure-dirs.sh
# calls the canonical helpers.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node absent"; exit 0; }
[ -f "$ROOT/mcp/dist/tools/knowledge-reindex.bundle.js" ] || { echo "SKIP: reindex bundle absent"; exit 0; }

# 1. structural: the broken static-import-from-a-runtime-expression form must be gone
if grep -qE 'import \{[^}]*\} from process\.env' "$ROOT/scripts/ensure-dirs.sh"; then
  fail "ensure-dirs.sh still has the broken static-import-from-env (D1 regression)"
fi
pass "no broken static-import-from-env in ensure-dirs.sh"

# 2. functional: a fresh KNOWLEDGE_DIR with wiki pages but no index.md → ensure-dirs builds index.md
BRAIN=$(mktemp -d); K=$(mktemp -d)
mkdir -p "$K/wiki/learnings"
cat > "$K/wiki/learnings/foo-thing.md" <<'EOF'
---
title: Foo Thing
type: learnings
---
# Foo Thing
A learning about foo bar baz for reindex coverage.
EOF
[ -f "$K/wiki/index.md" ] && fail "fixture should start with NO index.md"
CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN" KNOWLEDGE_DIR="$K" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K" \
  timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
[ -s "$K/wiki/index.md" ] || fail "ensure-dirs.sh did NOT build wiki/index.md (reindex wire dead)"
grep -qi 'foo-thing\|Foo Thing' "$K/wiki/index.md" || fail "index.md built but does not catalogue the fixture page"
pass "ensure-dirs.sh reindex builds wiki/index.md"
rm -rf "$BRAIN" "$K"

# 3. D096: the 24h SessionStart autofix pass (knowledge_validate autofix:true, which
# fs.unlink's empty pages and rewrites frontmatter) must take a wiki-history snapshot
# FIRST — the exact reversibility window config.json's own wiki_git comment promises for
# every unattended write. Force the "existing index.md" branch (skips the fresh-reindex
# path) so this run hits the validate+autofix branch with no .last-ensure-validate stamp.
if command -v git >/dev/null 2>&1; then
  BRAIN2=$(mktemp -d); K2=$(mktemp -d)
  mkdir -p "$K2/wiki/learnings"
  cat > "$K2/wiki/learnings/bar-thing.md" <<'EOF'
---
title: Bar Thing
type: learnings
---
# Bar Thing
A learning about bar for the snapshot-before-autofix coverage.
EOF
  printf -- '# index\n' > "$K2/wiki/index.md"   # pre-existing index.md -> the validate+autofix branch
  CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN2" KNOWLEDGE_DIR="$K2" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K2" \
    timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
  [ -d "$BRAIN2/wiki-history.git" ] || fail "D096: no wiki-history snapshot repo created before the SessionStart autofix"
  N=$(git --git-dir="$BRAIN2/wiki-history.git" --work-tree="$K2/wiki" log --oneline 2>/dev/null | grep -c .)
  [ "${N:-0}" -ge 1 ] || fail "D096: wiki-history repo exists but has no snapshot commit"
  pass "D096: SessionStart autofix takes a wiki-history snapshot first ($N commit(s))"
  rm -rf "$BRAIN2" "$K2"
else
  echo "SKIP: D096 — git absent"
fi

echo; echo "ALL PASS"
