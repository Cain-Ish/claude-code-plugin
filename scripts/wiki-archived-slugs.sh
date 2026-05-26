#!/usr/bin/env bash
# Net-archived source of truth: which wiki slugs are currently archived (forgotten).
# Reads $BRAIN_DIR/wiki-archive-log.jsonl (append-only; events archived|restored).
# Net set = per slug, the LAST event in append order is "archived".
# Modes: (default) print "slug<TAB>category"; --has <slug> (exit 0/1);
#        --path <slug> (print archive file path, or exit 1 if not net-archived/file gone).
# Fail-open: missing/empty/corrupt log or no jq -> empty set, never errors a caller.
set -u
BD="${BRAIN_DIR:-$HOME/.second-brain}"; LOG="$BD/wiki-archive-log.jsonl"; ARC="$BD/wiki-archive"
command -v jq >/dev/null 2>&1 || exit 0
net() {
  [ -f "$LOG" ] || return 0
  # Per-line tolerant parse (inputs|fromjson? // empty): a single corrupt line — e.g.
  # a partial write mid-crash — degrades only that line, never the whole set. Last
  # event per slug (append order) wins.
  jq -rRn 'reduce (inputs | fromjson? // empty) as $e ({}; .[$e.slug] = $e)
           | to_entries | map(.value)
           | map(select(.event=="archived"))
           | .[] | [.slug, (.category // "")] | @tsv' "$LOG" 2>/dev/null || true
}
case "${1:-}" in
  --has)
    s="${2:-}"; [ -n "$s" ] || exit 1
    net | cut -f1 | grep -qxF "$s" ;;
  --path)
    s="${2:-}"; [ -n "$s" ] || exit 1
    acat=$(net | awk -F'\t' -v s="$s" '$1==s{print $2; exit}')
    [ -n "$acat" ] || exit 1
    p="$ARC/$acat/$s.md"; [ -f "$p" ] || exit 1
    printf '%s\n' "$p" ;;
  *)
    net ;;
esac
