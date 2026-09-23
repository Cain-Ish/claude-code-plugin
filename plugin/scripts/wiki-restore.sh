#!/usr/bin/env bash
# Restore an archived wiki page back into the indexed tree (or --list archives).
# Reverses the dream FORGET phase's archive move. Run a reindex after to re-add it
# to search. Exit: 0 ok; 1 not found; 2 bad usage.
set -u
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KD="${KD/#\~/$HOME}"; WIKI="$KD/wiki"
BD="${BRAIN_DIR:-$HOME/.second-brain}"; ARC="$BD/wiki-archive"; LOG="$BD/wiki-archive-log.jsonl"

if [ "${1:-}" = "--list" ]; then
  if [ -f "$LOG" ]; then
    jq -r 'select(.event=="archived") | "\(.date)\t\(.category)/\(.slug)"' "$LOG" 2>/dev/null
  else
    echo "(no archive log at $LOG)"
  fi
  exit 0
fi

arg="${1:-}"
[ -n "$arg" ] || { echo "usage: wiki-restore.sh <slug> | <category/slug> | --list" >&2; exit 2; }
name="${arg##*/}"
if printf '%s' "$arg" | grep -q '/'; then
  src="$ARC/$arg.md"
  [ -f "$src" ] || { echo "restore: '$arg' not found under $ARC" >&2; exit 1; }
else
  matches=$(find "$ARC" -type f -name "$name.md" 2>/dev/null)
  n=$(printf '%s\n' "$matches" | grep -c .)
  [ "$n" -eq 0 ] && { echo "restore: '$name' not found under $ARC" >&2; exit 1; }
  if [ "$n" -gt 1 ]; then
    echo "restore: '$name' exists in multiple categories — re-run with <category/slug>:" >&2
    printf '%s\n' "$matches" | sed -E "s#^$ARC/##;s#\.md\$##" >&2
    exit 2
  fi
  src="$matches"
fi
cat=$(basename "$(dirname "$src")"); dest="$WIKI/$cat/$name.md"
mkdir -p "$WIKI/$cat" "$BD"                     # $BD so the log append can't fail on a fresh install
# D193: a live page may have appeared at this slug since the archive move (the drainer/
# maintainer keep writing). `mv` would silently clobber it AND, since this is a move not a
# copy, destroy the archived copy too in the same step. dream-accept's _release_holds
# refuses exactly this race ("NEVER clobber it") — the documented undo for FORGET had no
# such guard until now. Refuse loud, naming both paths, and leave both files in place.
if [ -e "$dest" ]; then
  echo "restore: refusing to overwrite live page at $dest — a live page now exists at that slug (archived copy kept at $src, not applied)" >&2
  exit 1
fi
mv "$src" "$dest"
if command -v jq >/dev/null 2>&1; then
  printf '{"event":"restored","slug":%s,"category":%s,"date":%s}\n' \
    "$(jq -Rn --arg v "$name" '$v')" "$(jq -Rn --arg v "$cat" '$v')" \
    "$(jq -Rn --arg v "$(date -u +%FT%TZ)" '$v')" >> "$LOG"
fi
echo "restored $name -> $dest (run a reindex / next session to re-add to search)"
