#!/bin/bash
# Deterministic plurality-suggest (KB hierarchical org, Phase 2). For a slug, print the
# most common `project:` facet among its current edge-neighbors that carry one. Count
# descending, lexical tie-break. Empty when no neighbor has a project. Read-only.
# The knowledge-maintainer uses this to assign project: to an unlabeled page (staged).
#
# Usage: bash kb-project-suggest.sh --knowledge-dir <dir> --slug <slug>
set -u
KDIR=""; SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$KDIR" ] || KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KDIR="${KDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"; EDGES="$KDIR/graph/edges.jsonl"
[ -n "$SLUG" ] && [ -f "$EDGES" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Neighbors: the other endpoint of any current (valid_to==null) edge touching SLUG.
# tr -d '\r': Windows jq emits CRLF; strip CR so slugs match filenames.
NBRS=$(jq -rn --arg s "$SLUG" 'reduce inputs as $r ({}; .[([$r.from,$r.type,$r.to]|tojson)]=$r) | [.[]]
  | map(select(.valid_to==null and (.from==$s or .to==$s)))
  | .[] | (if .from==$s then .to else .from end)' < "$EDGES" 2>/dev/null | tr -d '\r' | sort -u)
[ -n "$NBRS" ] || exit 0

proj_of() { # <slug> → its project: facet (empty if none)
  local f; f=$(find "$WIKI" -name "$1.md" -type f ! -name 'index.md' 2>/dev/null | sort | head -1)
  [ -n "$f" ] || return 0
  awk -F': *' '/^project:/ { gsub(/["[:space:]]/,"",$2); print $2; exit }' "$f"
}

while IFS= read -r n; do [ -n "$n" ] && proj_of "$n"; done <<< "$NBRS" \
  | grep -v '^$' | sort | uniq -c \
  | sort -k1,1nr -k2,2 \
  | awk 'NR==1{print $2}'
