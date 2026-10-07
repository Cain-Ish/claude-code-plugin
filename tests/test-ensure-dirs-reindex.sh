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
# tbound SECS CMD...: a time bound on every host. macOS ships no `timeout` (the bash-3.2 lane failed on
# `timeout 40` with "command not found"); gtimeout when coreutils is installed, else the background
# + kill watchdog lib.sh's own sb_timeout uses.
TOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TOUT_BIN="gtimeout"
fi
tbound() {
  local secs="$1"; shift
  if [ -n "$TOUT_BIN" ]; then "$TOUT_BIN" "$secs" "$@"; return $?; fi
  "$@" <&0 &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$!
  wait "$pid"; local ec=$?
  kill "$wd" 2>/dev/null || true
  return "$ec"
}
# 0. K21: sb_reindex_wiki had no else branch, so a missing reindex bundle (or no node on PATH)
# returned silently and wiki/index.md stayed stale with no trace anywhere. It must leave one
# error-log row naming the skip. CLAUDE_PLUGIN_ROOT points at an existing EMPTY dir: sb_plugin_root
# takes it as-is, so the bundle is absent while node may be present. Runs before the node/bundle
# skips below: this case needs neither.
K21B=$(mktemp -d); K21P=$(mktemp -d); K21K=$(mktemp -d); mkdir -p "$K21K/wiki"
( export HOME="$K21B" BRAIN_DIR="$K21B" CLAUDE_PLUGIN_ROOT="$K21P"
  . "$ROOT/scripts/lib.sh" && sb_reindex_wiki "$K21K" ) >/dev/null 2>&1
K21ROW=$(jq -c 'select(.script == "sb_reindex_wiki" and ((.message // "") | test("reindex skipped")))' \
  "$K21B/error-log.jsonl" 2>/dev/null | tr -d '\r')
[ -n "$K21ROW" ] || fail "K21: sb_reindex_wiki with no reindex bundle returned silently (no error-log row; log: $(tail -2 "$K21B/error-log.jsonl" 2>/dev/null))"
pass "K21: a missing reindex bundle leaves an error-log row instead of a silent no-op"
rm -rf "$K21B" "$K21P" "$K21K"

# 0b. S10 (R3-B): sb_reindex_wiki discarded node's exit status (`|| true`) and always returned 0,
# so a reindex that died without stderr left no trace, its rows said exit_code 0, and
# wiki-history.sh's `sb_reindex_wiki || sb_log_error` could never fire. A node that exits 3 (once
# silently, once with stderr) must make it return 3 and log an exit_code-1 row. The bundle is an
# empty stand-in file: only its existence is checked before node runs.
S10B=$(mktemp -d); S10P=$(mktemp -d); S10K=$(mktemp -d); S10BIN=$(mktemp -d)
mkdir -p "$S10K/wiki" "$S10P/mcp/dist/tools"; : > "$S10P/mcp/dist/tools/knowledge-reindex.bundle.js"
for s10 in silent loud; do
  if [ "$s10" = loud ]; then
    printf '#!%s\necho "reindex: simulated crash" >&2\nexit 3\n' "$BASH" > "$S10BIN/node"
  else
    printf '#!%s\nexit 3\n' "$BASH" > "$S10BIN/node"
  fi
  chmod +x "$S10BIN/node"; rm -f "$S10B/error-log.jsonl"
  ( export HOME="$S10B" BRAIN_DIR="$S10B" CLAUDE_PLUGIN_ROOT="$S10P" PATH="$S10BIN:$PATH"
    . "$ROOT/scripts/lib.sh" && sb_reindex_wiki "$S10K" ) >/dev/null 2>&1; s10rc=$?
  S10ROW=$(jq -c 'select(.script == "sb_reindex_wiki" and .exit_code == 1 and ((.message // "") | test("reindex-failed \\(node exit 3\\)")))' \
    "$S10B/error-log.jsonl" 2>/dev/null | tr -d '\r')
  [ "$s10rc" = 3 ] && [ -n "$S10ROW" ] \
    && pass "S10: a node reindex that exits 3 ($s10) returns 3 and logs an exit_code-1 row" \
    || fail "S10: node exit 3 ($s10) -> sb_reindex_wiki rc=$s10rc, row=${S10ROW:-none} (log: $(tail -2 "$S10B/error-log.jsonl" 2>/dev/null))"
done
rm -rf "$S10B" "$S10P" "$S10K" "$S10BIN"

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
  tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
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
    tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
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
    tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
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
    tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
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
  tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
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
  tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
PURGE_LINES_AFTER=$(grep -c . "$PURGE_FILE")
[ "$PURGE_LINES_BEFORE" -eq "$PURGE_LINES_AFTER" ] \
  && pass "D118: the one-time purge does not re-run or duplicate on a second ensure-dirs pass" \
  || fail "D118: second run duplicated purge content ($PURGE_LINES_BEFORE -> $PURGE_LINES_AFTER lines)"
rm -rf "$BRAIN4" "$K4" "$REALPROJ" "$FAKEHOME"


# 5. G4: SessionStart prunes orphaned atomic-write debris (*.tmp.* / *.rot.*) older than a day from
# the BRAIN_DIR root only: live state held 15 access-counts.json.tmp.* and a 568 KB
# audit-log.jsonl.tmp.5543 from killed writers. Newer debris, real state files, subdirs, a debris-named
# DIRECTORY and a debris-named SYMLINK (never followed) stay. The logged count is what was actually
# deleted (4 here), not what find listed.
BRAIN5=$(mktemp -d); K5=$(mktemp -d); OUT5=$(mktemp -d); mkdir -p "$K5/wiki/learnings" "$BRAIN5/sub" "$BRAIN5/old.tmp.dir"
for f in access-counts.json.tmp.101 access-counts.json.tmp.102 audit-log.jsonl.tmp.5543 audit-log.jsonl.rot.7 sub/deep.tmp.1; do
  : > "$BRAIN5/$f"; touch -t 202001010000 "$BRAIN5/$f"
done
touch -t 202001010000 "$BRAIN5/old.tmp.dir"
: > "$BRAIN5/access-counts.json"; touch -t 202001010000 "$BRAIN5/access-counts.json"
: > "$BRAIN5/access-counts.json.tmp.fresh"
echo keep > "$OUT5/target"; touch -t 202001010000 "$OUT5/target"
G4_LINK=0
if ln -s "$OUT5/target" "$BRAIN5/link.tmp.9" 2>/dev/null && [ -L "$BRAIN5/link.tmp.9" ]; then G4_LINK=1; else rm -f "$BRAIN5/link.tmp.9"; fi
CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN5" KNOWLEDGE_DIR="$K5" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K5" \
  tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
for f in access-counts.json.tmp.101 access-counts.json.tmp.102 audit-log.jsonl.tmp.5543 audit-log.jsonl.rot.7; do
  [ -e "$BRAIN5/$f" ] && fail "G4: stale debris $f was not pruned"
done
pass "G4: >1-day-old *.tmp.* / *.rot.* files in the BRAIN_DIR root are pruned"
[ -e "$BRAIN5/access-counts.json.tmp.fresh" ] || fail "G4: a fresh *.tmp.* (a live writer's file) was deleted"
[ -e "$BRAIN5/access-counts.json" ] || fail "G4: the real (non-debris) state file was deleted"
[ -e "$BRAIN5/sub/deep.tmp.1" ] || fail "G4: pruning recursed below the BRAIN_DIR root (maxdepth 1 violated)"
[ -d "$BRAIN5/old.tmp.dir" ] || fail "G4: a debris-named directory was pruned (only regular files may go)"
if [ "$G4_LINK" = 1 ]; then
  [ -L "$BRAIN5/link.tmp.9" ] || fail "G4: a debris-named symlink was removed (symlinks are never pruned)"
  [ "$(cat "$OUT5/target")" = keep ] || fail "G4: the prune followed a symlink and touched its target"
else
  echo "  note: debris-named symlink case not run (ln -s makes no real link on this host)"
fi
pass "G4: fresh debris, real state files, subdirectory contents, a debris-named dir and symlink are untouched"
G4_ROW=$(jq -c 'select((.rule // .gate // "") == "tmp-debris-gc")' "$BRAIN5/audit-log.jsonl" 2>/dev/null | tr -d '\r')
[ -n "$G4_ROW" ] || fail "G4: the pruned count was not logged"
printf '%s' "$G4_ROW" | grep -q 'pruned 4 stale' || fail "G4: logged count is not the 4 files actually deleted: $G4_ROW"
pass "G4: the logged count is the number of files actually deleted (4)"

# 5b. G4, find fails on the delete pass: a find that LISTS the debris but cannot delete it (exit 1)
# must not be audited as a prune, and its failure must reach the error log.
BRAIN5B=$(mktemp -d); SHIM5=$(mktemp -d); REAL_FIND=$(command -v find)
for f in a.json.tmp.1 b.jsonl.rot.2; do : > "$BRAIN5B/$f"; touch -t 202001010000 "$BRAIN5B/$f"; done
cat > "$SHIM5/find" <<EOF
#!/bin/bash
case " \$* " in
  *" -delete "*)
    args=(); for a in "\$@"; do [ "\$a" = "-delete" ] || args+=("\$a"); done
    "$REAL_FIND" "\${args[@]}"
    echo "find: cannot delete: Permission denied" >&2
    exit 1 ;;
esac
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM5/find"
CLAUDE_PLUGIN_ROOT="$ROOT" BRAIN_DIR="$BRAIN5B" KNOWLEDGE_DIR="$K5" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$K5" PATH="$SHIM5:$PATH" \
  tbound 40 bash "$ROOT/scripts/ensure-dirs.sh" >/dev/null 2>&1
[ -e "$BRAIN5B/a.json.tmp.1" ] && [ -e "$BRAIN5B/b.jsonl.rot.2" ] || fail "G4 5b: the shimmed find was supposed to delete nothing"
jq -c 'select((.rule // .gate // "") == "tmp-debris-gc")' "$BRAIN5B/audit-log.jsonl" 2>/dev/null | tr -d '\r' | grep -q 'pruned [1-9]' \
  && fail "G4 5b: a failed delete pass was audited as a prune (find's listing counted, not the deletions)"
jq -c 'select(.script == "ensure-dirs.sh" and .exit_code != 0 and ((.message // "") | test("tmp-debris")))' "$BRAIN5B/error-log.jsonl" 2>/dev/null \
  | tr -d '\r' | grep -q . || fail "G4 5b: find's non-zero exit on the delete pass left no error-log row ($(tail -2 "$BRAIN5B/error-log.jsonl" 2>/dev/null))"
pass "G4: a failing delete pass is logged through sb_log_error and not counted as pruned"
rm -rf "$BRAIN5" "$K5" "$OUT5" "$BRAIN5B" "$SHIM5"
echo; echo "ALL PASS"
