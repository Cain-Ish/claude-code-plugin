#!/bin/bash
# One-shot, idempotent, reversible migration: seed ~/knowledge/graph/edges.jsonl
# from existing related: frontmatter + body [[wiki-links]] as untyped `relates`
# edges. Never guesses requires/affects — re-typing is later, LLM-judged work
# (the dream RELATE phase). Reversible: delete ~/knowledge/graph/ and pages still
# carry their related:. Read-only w.r.t. wiki pages.
#
# Usage: bash graph-migrate.sh --knowledge-dir <dir>
set -u
source "$(dirname "$0")/lib.sh"

KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    *) echo "graph-migrate: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI="$KNOWLEDGE_DIR/wiki"
GRAPH_DIR="$KNOWLEDGE_DIR/graph"
LOG="$GRAPH_DIR/edges.jsonl"
[ -d "$WIKI" ] || { echo "graph-migrate: no wiki at $WIKI" >&2; exit 0; }
mkdir -p "$GRAPH_DIR"; touch "$LOG"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Existing relates identities "from<TAB>to" — for idempotency. Keyed on ANY
# relates edge (not just source=migration:v1) so a relates edge already captured
# by the extractor or knowledge_relate is not duplicated by a later migrate run.
EXISTING_FILE=$(mktemp)
PAIRS_FILE=$(mktemp)
trap 'rm -f "$EXISTING_FILE" "$PAIRS_FILE"' EXIT
jq -r 'select(.type=="relates") | "\(.from)\t\(.to)"' \
  "$LOG" 2>/dev/null | sort -u > "$EXISTING_FILE"

# Collect candidate (from, to, created) triples from every page. Targets come
# from BOTH wiki-link formats the live wiki uses:
#   (a) any [[wiki-link]] anywhere in the file (frontmatter brackets + body refs)
#   (b) bare-YAML frontmatter lists `related: [slug-a, slug-b]` (no brackets) —
#       these are the MAJORITY of pages (~103/135 on the dev wiki) and were
#       missed by a [[..]]-only grep. parseDoc (knowledge-search.ts) reads both;
#       migration must too or it imports nothing from those pages.
# File/stream based (no shell-var accumulation) to survive the pipeline subshells.
find "$WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while IFS= read -r file; do
  from=$(basename "$file" .md)
  created=$(awk -F': *' '/^created:/ { gsub(/["[:space:]]/,"",$2); print $2; exit }' "$file")
  {
    # (a) bracketed wiki-links, anywhere
    grep -oE '\[\[[^]]+\]\]' "$file" 2>/dev/null | sed 's/\[\[//; s/\]\]//'
    # (b) bare-YAML `related: [a, b]` in the FIRST frontmatter block only, and
    #     only when it is NOT the bracketed form (those are covered by (a)).
    awk '
      NR==1 && /^---[[:space:]]*$/ { fm=1; next }
      fm && /^---[[:space:]]*$/    { exit }
      fm && /^related:[[:space:]]*\[/ && !/\[\[/ {
        line=$0
        sub(/^related:[[:space:]]*\[/, "", line)
        sub(/\].*$/, "", line)
        n=split(line, arr, ",")
        for (i=1; i<=n; i++) {
          s=arr[i]
          gsub(/[]["'"'"'[:space:]]/, "", s)   # strip brackets, quotes, whitespace
          if (s != "") print s
        }
      }
    ' "$file"
  } | while IFS= read -r to; do
    [ -n "$to" ] && [ "$to" != "$from" ] && printf '%s\t%s\t%s\n' "$from" "$to" "$created"
  done
done | sort -u > "$PAIRS_FILE"

# Emit edges for pairs not already present.
while IFS=$'\t' read -r from to created; do
  [ -z "$from" ] && continue
  [ -z "$to" ] && continue
  if grep -qxF "$(printf '%s\t%s' "$from" "$to")" "$EXISTING_FILE"; then
    continue
  fi
  vf="${created:0:10}"; [ -z "$vf" ] && vf="${NOW:0:10}"
  jq -nc --arg f "$from" --arg t "$to" --arg vf "$vf" --arg now "$NOW" \
    '{op:"assert",from:$f,to:$t,type:"relates",valid_from:$vf,valid_to:null,recorded_at:$now,source:"migration:v1"}' \
    >> "$LOG"
  # Track within-run so a duplicate pair later in the file isn't re-emitted
  # (PAIRS_FILE is already sort -u'd, so this is belt-and-suspenders).
  printf '%s\t%s\n' "$from" "$to" >> "$EXISTING_FILE"
done < "$PAIRS_FILE"

exit 0
