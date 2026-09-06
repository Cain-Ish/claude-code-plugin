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

# 4. D096 follow-up: the snapshot call's exit code used to be discarded (`2>/dev/null`),
# so a FAILED snapshot (no undo point committed) still let the deleting autofix run —
# exactly the class of bug the reversibility window exists to prevent. Force `git commit`
# to fail via a pre-commit hook (tests/test-wiki-history.sh H8's trick: isolates the
# commit step specifically, unlike a corrupted index which would also break autofix
# for the wrong reason) and confirm the autofix is skipped, not silently run anyway.
if command -v git >/dev/null 2>&1; then
  BRAIN3=$(mktemp -d); K3=$(mktemp -d)
  mkdir -p "$K3/wiki/learnings"
  cat > "$K3/wiki/learnings/bar-thing.md" <<'EOF'
---
title: Bar Thing
type: learnings
---
# Bar Thing
A learning about bar for the failed-snapshot-skips-autofix coverage.
EOF
  printf -- '# index\n' > "$K3/wiki/index.md"   # pre-existing index.md -> the validate+autofix branch
  # First run: establishes the wiki-history repo + an initial successful snapshot (nothing
  # to autofix yet — the empty-page target below is added AFTER this baseline run).
  CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN3" KNOWLEDGE_DIR="$K3" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K3" \
    timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
  [ -d "$BRAIN3/wiki-history.git" ] || fail "D096b: setup — wiki-history repo not created on the baseline run"
  # Poison the snapshot repo so its NEXT commit fails, force the 24h stamp stale so the
  # autofix branch re-enters, and plant an empty page — the observable autofix deletes.
  mkdir -p "$BRAIN3/wiki-history.git/hooks"
  printf '#!/bin/sh\nexit 1\n' > "$BRAIN3/wiki-history.git/hooks/pre-commit"
  chmod +x "$BRAIN3/wiki-history.git/hooks/pre-commit"
  rm -f "$BRAIN3/.last-ensure-validate"
  : > "$K3/wiki/learnings/empty-page.md"
  rm -f "$BRAIN3/error-log.jsonl"
  CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN3" KNOWLEDGE_DIR="$K3" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K3" \
    timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
  grep -q 'pre-autofix wiki-history snapshot failed' "$BRAIN3/error-log.jsonl" 2>/dev/null \
    || fail "D096b: failed snapshot was not logged loudly"
  pass "D096b: a failed pre-autofix snapshot is logged loudly"
  [ -f "$K3/wiki/learnings/empty-page.md" ] \
    || fail "D096b: autofix ran (deleted the empty page) despite the snapshot's only undo point failing"
  pass "D096b: autofix is SKIPPED when its pre-autofix snapshot fails (no undo point, no destructive run)"
  rm -rf "$BRAIN3" "$K3"
else
  echo "SKIP: D096b — git absent"
fi

# 5. D118: one-time migration purges pre-existing projects.jsonl rows whose root_path is
# $HOME or a bare temp root (registered before the sb_registration_refused_reason guard
# existed) — never silently: the removed rows must land in a dated .purged sidecar first.
BRAIN4=$(mktemp -d); K4=$(mktemp -d)
mkdir -p "$K4/wiki"
REALPROJ=$(mktemp -d); ( cd "$REALPROJ" && git init -q )
FAKEHOME=$(mktemp -d)   # stands in for $HOME in this fixture's registry row
printf '%s\n%s\n%s\n' \
  '{"slug":"real-project","name":"real-project","last_session_iso":"2026-01-01T00:00:00Z","root_path":"'"$REALPROJ"'"}' \
  '{"slug":"curst","name":"curst","last_session_iso":"2026-01-02T00:00:00Z","root_path":"'"$FAKEHOME"'"}' \
  '{"slug":"scratch","name":"scratch","last_session_iso":"2026-01-03T00:00:00Z","root_path":"'"$FAKEHOME"'/AppData/Local/Temp"}' \
  > "$BRAIN4/projects.jsonl"
mkdir -p "$FAKEHOME/AppData/Local/Temp"
CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKEHOME" BRAIN_DIR="$BRAIN4" KNOWLEDGE_DIR="$K4" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K4" \
  timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
jq -e 'select(.slug=="real-project")' "$BRAIN4/projects.jsonl" >/dev/null 2>&1 \
  || fail "D118: the real, legitimate project row was wrongly purged"
pass "D118: a legitimate project's registry row survives the purge"
jq -e 'select(.slug=="curst")' "$BRAIN4/projects.jsonl" >/dev/null 2>&1 \
  && fail "D118: the \$HOME registry row was NOT purged" \
  || pass "D118: the \$HOME registry row was purged from the live registry"
jq -e 'select(.slug=="scratch")' "$BRAIN4/projects.jsonl" >/dev/null 2>&1 \
  && fail "D118: the bare temp-root registry row was NOT purged" \
  || pass "D118: the bare temp-root registry row was purged from the live registry"
PURGE_FILE=$(ls "$BRAIN4"/projects.jsonl.purged-* 2>/dev/null | head -1)
[ -n "$PURGE_FILE" ] || fail "D118: no .purged sidecar written — removed rows would be silently lost"
grep -q '"curst"' "$PURGE_FILE" && grep -q '"scratch"' "$PURGE_FILE" \
  && pass "D118: both purged rows are preserved in the dated .purged sidecar (never silently deleted)" \
  || fail "D118: purged sidecar is missing one or both removed rows"
# Marker-gated: a second run must not re-purge (nothing left to purge) or duplicate the sidecar content.
PURGE_LINES_BEFORE=$(grep -c . "$PURGE_FILE")
CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKEHOME" BRAIN_DIR="$BRAIN4" KNOWLEDGE_DIR="$K4" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K4" \
  timeout 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
PURGE_LINES_AFTER=$(grep -c . "$PURGE_FILE")
[ "$PURGE_LINES_BEFORE" -eq "$PURGE_LINES_AFTER" ] \
  && pass "D118: the one-time purge does not re-run or duplicate on a second ensure-dirs pass" \
  || fail "D118: second run duplicated purge content ($PURGE_LINES_BEFORE -> $PURGE_LINES_AFTER lines)"
rm -rf "$BRAIN4" "$K4" "$REALPROJ" "$FAKEHOME"

echo; echo "ALL PASS"
