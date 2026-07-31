#!/bin/bash
# wiki-history.sh — the REVERSIBILITY WINDOW for autonomous consolidation.
#
# CONSTITUTION.md permits unattended writes only because they are reversible: safety comes
# from "reversible auto-consolidation … not a manual gate". Pre-accept tarballs cover a single
# accept; this gives the wiki a real, walkable history so ANY unattended change can be
# inspected and undone later.
#
#   wiki-history.sh snapshot "<reason>"   commit the current wiki state if it changed
#   wiki-history.sh list [n]              recent snapshots (newest first)
#   wiki-history.sh show <ref>            what changed in one snapshot
#   wiki-history.sh restore <ref> [--exact]  bring back that snapshot's pages (--exact also
#                                         removes pages added since); pre-snapshotted, so undoable
#
# DETACHED GIT DIR — the load-bearing design choice. The repo lives at
# $BRAIN_DIR/wiki-history.git and the wiki is its work-tree, so NO .git directory is ever
# created inside the user's knowledge dir. That matters three ways: walkWiki's `skipHidden` is
# OPT-IN and knowledgeSearch treats every wiki subdirectory as a scope dir, so an in-tree .git
# would be traversed (thousands of object dirs) on EVERY search; the knowledge dir is commonly
# an Obsidian vault and/or cloud-synced, where a surprise .git causes real conflicts; and
# removing the history is `rm -rf` of one directory that is not the user's data.
#
# Kill switch: config.json `wiki_git: false`, or SB_WIKI_GIT=off. Fail-soft: a history failure
# must never block or fail a consolidation — but it is always LOGGED, never silent.
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"

[ "${SB_WIKI_GIT:-on}" = "off" ] && exit 0
[ "$(sb_config_bool .wiki_git on)" = "on" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

_to_msys() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }
KD="$(sb_knowledge_dir)"; KD=$(_to_msys "$KD")
WIKI="$KD/wiki"
GD=$(_to_msys "$BRAIN_DIR")/wiki-history.git
[ -d "$WIKI" ] || exit 0

_git() { git --git-dir="$GD" --work-tree="$WIKI" "$@"; }

_init_if_needed() {
  [ -d "$GD" ] && return 0
  local err
  if ! err=$(git init --bare "$GD" 2>&1); then
    sb_log_error "wiki-history" "could not init the wiki history repo at $GD: ${err:0:200}" 1
    return 1
  fi
  # A bare repo refuses work-tree operations; point it at the wiki instead.
  git --git-dir="$GD" config core.bare false
  git --git-dir="$GD" config core.worktree "$WIKI"
  # Identity is required for commit and MUST be repo-local: the user's global identity may be
  # unset out-of-band (the drainer runs from a scheduler with a minimal environment).
  git --git-dir="$GD" config user.email "second-brain@localhost"
  git --git-dir="$GD" config user.name "second-brain"
  # Regenerable, churning, or large artifacts stay OUT of the history: the embeddings cache is
  # megabytes and rewritten by every search; backups/tmp are noise.
  mkdir -p "$GD/info"
  printf '%s\n' '.embeddings-cache.json' '*.tmp.*' '*.bak' '*.tgz' > "$GD/info/exclude"
  return 0
}

_snapshot() {
  local reason="${1:-consolidation}" out
  _init_if_needed || return 1
  _git add -A >/dev/null 2>&1
  # Nothing staged => nothing changed => no empty commit (keeps the log meaningful).
  if _git diff --cached --quiet 2>/dev/null; then return 0; fi
  local n
  n=$(_git diff --cached --name-only 2>/dev/null | grep -c . || echo 0)
  if ! out=$(_git commit -q -m "$reason ($n file(s))" 2>&1); then
    sb_log_error "wiki-history" "snapshot commit failed: ${out:0:200}" 1
    return 1
  fi
  echo "wiki-history: snapshot '$reason' ($n file(s))"
}

case "${1:-}" in
  snapshot) shift; _snapshot "${1:-consolidation}" ;;
  list)
    [ -d "$GD" ] || { echo "no wiki history yet"; exit 0; }
    _git log --oneline -n "${2:-20}" --date=short --format='%h  %ad  %s' 2>/dev/null
    ;;
  show)
    [ -n "${2:-}" ] || { echo "usage: wiki-history.sh show <ref>" >&2; exit 1; }
    _git show --stat "$2" 2>/dev/null
    ;;
  restore)
    REF="${2:-}"
    [ -n "$REF" ] || { echo "usage: wiki-history.sh restore <ref>" >&2; exit 1; }
    [ -d "$GD" ] || { echo "error: no wiki history to restore from" >&2; exit 1; }
    _git rev-parse --verify "$REF^{commit}" >/dev/null 2>&1 || {
      echo "error: '$REF' is not a snapshot in the wiki history (see: wiki-history.sh list)" >&2; exit 1; }
    # Snapshot the CURRENT state first — a restore must itself be undoable, or the undo
    # mechanism becomes a way to lose work.
    _snapshot "pre-restore safety snapshot" >/dev/null 2>&1
    if ! _git checkout "$REF" -- . 2>/dev/null; then
      echo "error: restore failed; wiki left untouched" >&2
      sb_log_error "wiki-history" "restore to $REF failed" 1
      exit 1
    fi
    # DEFAULT IS ADDITIVE, and says so: `git checkout <ref> -- .` brings back what that snapshot
    # had, but pages CREATED since still exist. Claiming "restored to <ref>" while newer pages
    # survive would be a prose promise the machine does not keep. --exact also removes them
    # (safe: the pre-restore snapshot above can bring them straight back).
    _EXTRA=0
    if [ "${3:-}" = "--exact" ]; then
      while IFS= read -r _np; do
        [ -n "$_np" ] || continue
        rm -f "$WIKI/$_np" 2>/dev/null && _EXTRA=$((_EXTRA + 1))
      done < <(_git diff --name-only --diff-filter=A "$REF" HEAD 2>/dev/null)
    fi
    _snapshot "restored to $REF" >/dev/null 2>&1
    if [ "${3:-}" = "--exact" ]; then
      echo "Restored the wiki to $REF exactly ($_EXTRA page(s) added since were removed)."
    else
      echo "Restored $REF's pages. Pages ADDED since were kept — re-run with --exact to remove them."
    fi
    echo "The pre-restore state is itself a snapshot (wiki-history.sh list)."
    # The index must be rebuilt: restored pages differ from what search/MOCs were built against.
    sb_reindex_wiki "$KD" >/dev/null 2>&1 || sb_log_error "wiki-history" "reindex after restore failed" 1
    ;;
  *)
    echo "usage: wiki-history.sh {snapshot [reason]|list [n]|show <ref>|restore <ref>}" >&2
    exit 1 ;;
esac
exit 0
