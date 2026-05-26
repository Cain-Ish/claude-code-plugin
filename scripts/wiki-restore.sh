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

slug="${1:-}"
[ -n "$slug" ] || { echo "usage: wiki-restore.sh <slug> | --list" >&2; exit 2; }
src=$(find "$ARC" -type f -name "$slug.md" 2>/dev/null | head -1)
[ -n "$src" ] || { echo "restore: '$slug' not found under $ARC" >&2; exit 1; }
cat=$(basename "$(dirname "$src")"); dest="$WIKI/$cat/$slug.md"
mkdir -p "$WIKI/$cat"; mv "$src" "$dest"
if command -v jq >/dev/null 2>&1; then
  printf '{"event":"restored","slug":%s,"category":%s,"date":%s}\n' \
    "$(jq -Rn --arg v "$slug" '$v')" "$(jq -Rn --arg v "$cat" '$v')" \
    "$(jq -Rn --arg v "$(date -u +%FT%TZ)" '$v')" >> "$LOG"
fi
echo "restored $slug -> $dest (run a reindex / next session to re-add to search)"
