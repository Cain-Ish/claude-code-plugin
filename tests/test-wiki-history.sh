#!/usr/bin/env bash
# pins: SB_WIKI_GIT — kill-switch test: asserts =off means the snapshot must not run
# wiki-history.sh — the reversibility window that lets unattended consolidation be safe
# WITHOUT a human gate (CONSTITUTION.md: safety from reversible auto-consolidation).
# ORACLE: real files and a real git repo on disk.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
WH="$ROOT/scripts/wiki-history.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git absent"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

setup(){
  SB=$(mktemp -d)
  export HOME="$SB" BRAIN_DIR="$SB/brain" KNOWLEDGE_DIR="$SB/knowledge"
  export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" CLAUDE_PLUGIN_ROOT="$ROOT"
  mkdir -p "$BRAIN_DIR" "$KNOWLEDGE_DIR/wiki/learnings"
  printf -- '---\ntitle: a\ntype: learnings\nrelated: []\n---\n\nORIGINAL\n' > "$KNOWLEDGE_DIR/wiki/learnings/a.md"
}

echo "=== H1: zero footprint inside the user's knowledge dir ==="
setup
bash "$WH" snapshot "first" >/dev/null 2>&1
[ ! -e "$KNOWLEDGE_DIR/wiki/.git" ] && pass "H1: no .git inside the wiki (detached git-dir)" \
  || fail "H1: a .git appeared in the wiki — search would walk it and syncs would conflict"
[ -d "$BRAIN_DIR/wiki-history.git" ] && pass "H1: history lives under BRAIN_DIR" || fail "H1: no history repo created"
# Nothing but the history dir may be added to the knowledge tree.
[ "$(find "$KNOWLEDGE_DIR" -name '.git*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && pass "H1: knowledge tree carries no git artifacts at all" || fail "H1: git artifacts leaked into the knowledge tree"

echo "=== H2: snapshots only on real change; history is walkable ==="
OUT=$(bash "$WH" snapshot "no-change run" 2>&1)
[ -z "$OUT" ] && pass "H2: unchanged wiki produces NO empty commit" || fail "H2: empty commit made ($OUT)"
printf -- '---\ntitle: a\ntype: learnings\nrelated: []\n---\n\nCHANGED\n' > "$KNOWLEDGE_DIR/wiki/learnings/a.md"
bash "$WH" snapshot "second" >/dev/null 2>&1
[ "$(bash "$WH" list 10 | grep -c .)" -ge 2 ] && pass "H2: list shows the snapshot history" || fail "H2: history not listed"

echo "=== H3: restore brings back a page a bad run deleted ==="
GOOD=$(bash "$WH" list 1 | awk '{print $1}')
rm -f "$KNOWLEDGE_DIR/wiki/learnings/a.md"
printf 'junk\n' > "$KNOWLEDGE_DIR/wiki/learnings/added-later.md"
bash "$WH" snapshot "bad run" >/dev/null 2>&1
bash "$WH" restore "$GOOD" >/dev/null 2>&1
[ -f "$KNOWLEDGE_DIR/wiki/learnings/a.md" ] && grep -q 'CHANGED' "$KNOWLEDGE_DIR/wiki/learnings/a.md" \
  && pass "H3: the deleted page came back with its snapshot content" || fail "H3: restore did not recover the page"
# Default restore is ADDITIVE and the script says so — pages added later survive.
[ -f "$KNOWLEDGE_DIR/wiki/learnings/added-later.md" ] \
  && pass "H3: default restore keeps pages added since (additive, as documented)" \
  || fail "H3: default restore deleted a newer page without --exact"

echo "=== H4: --exact removes pages added since, and is itself undoable ==="
bash "$WH" restore "$GOOD" --exact >/dev/null 2>&1
[ ! -f "$KNOWLEDGE_DIR/wiki/learnings/added-later.md" ] \
  && pass "H4: --exact removed the page added after the snapshot" || fail "H4: --exact left a newer page behind"
# The pre-restore snapshot must let the removal be undone.
PRE=$(bash "$WH" list 20 | grep 'pre-restore safety snapshot' | head -1 | awk '{print $1}')
[ -n "$PRE" ] && pass "H4: a pre-restore safety snapshot exists (the undo is undoable)" || fail "H4: no pre-restore snapshot"
bash "$WH" restore "$PRE" >/dev/null 2>&1
[ -f "$KNOWLEDGE_DIR/wiki/learnings/added-later.md" ] \
  && pass "H4: restoring the pre-restore snapshot brought the removed page back" \
  || fail "H4: could not undo the --exact restore"

echo "=== H5: kill switches ==="
rm -rf "$BRAIN_DIR/wiki-history.git"
SB_WIKI_GIT=off bash "$WH" snapshot "should not run" >/dev/null 2>&1
[ ! -d "$BRAIN_DIR/wiki-history.git" ] && pass "H5: SB_WIKI_GIT=off disables it" || fail "H5: env kill switch ignored"
printf '{"wiki_git": false}\n' > "$BRAIN_DIR/config.json"
bash "$WH" snapshot "should not run" >/dev/null 2>&1
[ ! -d "$BRAIN_DIR/wiki-history.git" ] && pass "H5: config wiki_git:false disables it" || fail "H5: config kill switch ignored"

echo "=== H6: a bad ref is refused, not half-applied ==="
printf '{"wiki_git": true}\n' > "$BRAIN_DIR/config.json"
bash "$WH" snapshot "base" >/dev/null 2>&1
BEFORE=$(cat "$KNOWLEDGE_DIR/wiki/learnings/a.md" 2>/dev/null)
bash "$WH" restore "deadbeef" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "H6: unknown ref refused (nonzero)" || fail "H6: unknown ref accepted"
[ "$(cat "$KNOWLEDGE_DIR/wiki/learnings/a.md" 2>/dev/null)" = "$BEFORE" ] \
  && pass "H6: wiki untouched by the refused restore" || fail "H6: wiki mutated by a refused restore"
rm -rf "$SB"

echo "=== H6b: a snapshot FAILURE is loud, never a silent no-op ==="
# The reversibility window dying quietly is the worst failure mode: callers would believe the
# wiki is protected. Corrupt the history repo so `git add` must fail.
setup
bash "$WH" snapshot "base" >/dev/null 2>&1
printf 'not a git dir
' > "$BRAIN_DIR/wiki-history.git/HEAD"
printf 'changed
' >> "$KNOWLEDGE_DIR/wiki/learnings/a.md"
rm -f "$BRAIN_DIR/error-log.jsonl"
bash "$WH" snapshot "should fail loudly" >/dev/null 2>&1
grep -q 'wiki-history' "$BRAIN_DIR/error-log.jsonl"    && pass "H6b: a broken history repo is LOGGED, not silently skipped"   || fail "H6b: snapshot failed silently — callers would think the wiki was protected"
rm -rf "$SB"

echo "=== H7: wired into the write paths (engine + accept) ==="
grep -q 'wiki-history.sh' "$ROOT/scripts/brain-os-run.sh" && pass "H7: engine snapshots after its passes" || fail "H7: engine does not snapshot"
grep -q 'wiki-history.sh' "$ROOT/scripts/dream-accept.sh" && pass "H7: accept snapshots what it applied" || fail "H7: accept does not snapshot"

echo "=== H8: D191 — restore ABORTS if the pre-restore safety snapshot fails ==="
# Previously the pre-restore _snapshot's return code was discarded, so a failed safety
# snapshot (locked index, full disk, bad git state) still let the destructive checkout
# run, and the final line claimed an undo point that was never actually committed. A
# pre-commit hook that always fails forces ONLY `git commit` to fail (git add and the
# later checkout still use a normal, uncorrupted index) — isolating the pre-restore
# snapshot's commit step specifically, unlike a broken index file which would also break
# the checkout that follows and give a false pass for the wrong reason.
setup
bash "$WH" snapshot "base" >/dev/null 2>&1
GOOD=$(bash "$WH" list 1 | awk '{print $1}')
printf -- '---\ntitle: a\ntype: learnings\nrelated: []\n---\n\nCHANGED-FOR-H8\n' > "$KNOWLEDGE_DIR/wiki/learnings/a.md"
bash "$WH" snapshot "before restore attempt" >/dev/null 2>&1
mkdir -p "$BRAIN_DIR/wiki-history.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$BRAIN_DIR/wiki-history.git/hooks/pre-commit"
chmod +x "$BRAIN_DIR/wiki-history.git/hooks/pre-commit"
printf -- '---\ntitle: a\ntype: learnings\nrelated: []\n---\n\nDIRTY-BEFORE-RESTORE\n' > "$KNOWLEDGE_DIR/wiki/learnings/a.md"
bash "$WH" restore "$GOOD" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "H8: restore aborts (nonzero) when the pre-restore snapshot fails" \
  || fail "H8: restore proceeded (rc=0) despite a failed pre-restore snapshot"
grep -q 'DIRTY-BEFORE-RESTORE' "$KNOWLEDGE_DIR/wiki/learnings/a.md" 2>/dev/null \
  && pass "H8: wiki left untouched (uncommitted dirty state, not checked out) when the pre-restore snapshot fails" \
  || fail "H8: wiki was mutated despite the failed safety snapshot"
rm -f "$BRAIN_DIR/wiki-history.git/hooks/pre-commit"
rm -rf "$SB"

echo "=== H9/H10: S10 caller — a restore whose reindex was skipped or failed says the index is stale ==="
# The restore rebuilds wiki/index.md last. `sb_reindex_wiki || sb_log_error` could not see a skip (no
# node, or no reindex bundle: sb_reindex_wiki returns 0 for it, it is not a failure), so such a
# restore printed its success and nothing about the index. It now reads SB_REINDEX_SKIPPED and warns
# on stderr (H9); a failed reindex (node exits 3) keeps its exit_code-1 row and warns too (H10). The
# restore itself succeeded either way: exit 0, the page is back.
for h in 9 10; do
  setup
  bash "$WH" snapshot "h$h base" >/dev/null 2>&1
  HREF=$(bash "$WH" list 1 | awk '{print $1}')
  printf -- '---\ntitle: a\ntype: learnings\nrelated: []\n---\n\nCHANGED-H%s\n' "$h" > "$KNOWLEDGE_DIR/wiki/learnings/a.md"
  bash "$WH" snapshot "h$h changed" >/dev/null 2>&1
  mkdir -p "$SB/root/mcp/dist/tools" "$SB/nodebin"
  if [ "$h" = 9 ]; then
    HERR=$(CLAUDE_PLUGIN_ROOT="$SB/root" bash "$WH" restore "$HREF" 2>&1 >/dev/null); rc=$?
  else
    : > "$SB/root/mcp/dist/tools/knowledge-reindex.bundle.js"
    printf '#!%s\nexit 3\n' "$BASH" > "$SB/nodebin/node"; chmod +x "$SB/nodebin/node"
    HERR=$(PATH="$SB/nodebin:$PATH" CLAUDE_PLUGIN_ROOT="$SB/root" bash "$WH" restore "$HREF" 2>&1 >/dev/null); rc=$?
  fi
  { [ "$rc" -eq 0 ] && grep -q 'ORIGINAL' "$KNOWLEDGE_DIR/wiki/learnings/a.md"; } \
    && pass "H$h: the restore itself succeeds (rc 0, page back)" || fail "H$h: restore rc=$rc or the page was not restored"
  case "$HERR" in
    *"index was not rebuilt"*) pass "H$h: the restore says on stderr that the index was not rebuilt" ;;
    *) fail "H$h: the restore said nothing about the stale index (stderr: ${HERR:-<empty>})" ;;
  esac
  FAILROW=$(jq -c 'select(.script == "wiki-history" and .exit_code == 1 and ((.message // "") | test("reindex after restore")))' \
    "$BRAIN_DIR/error-log.jsonl" 2>/dev/null | tr -d '\r')
  if [ "$h" = 9 ]; then
    [ -z "$FAILROW" ] && pass "H9: a skipped reindex is not logged as a failed one" || fail "H9: a skip was logged as a failure: $FAILROW"
    jq -c 'select(.script == "sb_reindex_wiki" and ((.message // "") | test("reindex skipped")))' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
      | tr -d '\r' | grep -q . && pass "H9: the skip row names the skipped reindex" || fail "H9: no 'reindex skipped' row"
  else
    [ -n "$FAILROW" ] && pass "H10: a failed reindex after the restore is an exit_code-1 row" \
      || fail "H10: no exit_code-1 'reindex after restore' row (log: $(tail -2 "$BRAIN_DIR/error-log.jsonl" 2>/dev/null))"
  fi
  rm -rf "$SB"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
