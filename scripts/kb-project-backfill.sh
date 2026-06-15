#!/bin/bash
# One-shot, idempotent, reversible project: backfill (KB hierarchical org, Phase 1).
# For each registry {anchor, project}, walk the part_of graph (transitive children that are
# part_of the anchor subtree) and set `project: <key>` frontmatter on each member page that
# lacks it. Deterministic, additive, reversible (remove the project: line). Read-only w.r.t.
# the edge log. No edges/registry ⇒ no-op.
#
# Usage: bash kb-project-backfill.sh --knowledge-dir <dir>
set -u

KDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$KDIR" ] || KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KDIR="${KDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"; EDGES="$KDIR/graph/edges.jsonl"; REG="$KDIR/graph/project-registry.jsonl"
[ -f "$EDGES" ] && [ -f "$REG" ] || { echo "backfill: no edges/registry — nothing to do"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "backfill: jq required" >&2; exit 0; }

# Current part_of edges as "child<TAB>parent" (fold to latest by [from,type,to]; drop invalidated).
PO=$(jq -rn 'reduce inputs as $r ({}; .[([$r.from,$r.type,$r.to]|tojson)]=$r) | [.[]]
  | map(select(.type=="part_of" and .valid_to==null)) | .[] | "\(.from)\t\(.to)"' < "$EDGES" 2>/dev/null)

set_project() { # <slug> <project> — insert `project: <p>` before the first frontmatter close
  local slug="$1" proj="$2" f
  f=$(find "$WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | sort | head -1)
  [ -n "$f" ] || return 0
  grep -qE '^project:' "$f" && return 0   # idempotent: never overwrite an existing facet
  awk -v p="$proj" '
    NR==1 && /^---[[:space:]]*$/ { print; infm=1; next }
    infm && /^---[[:space:]]*$/  { print "project: " p; print; infm=0; next }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  anchor=$(printf '%s' "$line" | jq -r '.anchor // empty' 2>/dev/null | tr -d '\r')
  proj=$(printf '%s' "$line" | jq -r '.project // empty' 2>/dev/null | tr -d '\r')
  [ -n "$anchor" ] && [ -n "$proj" ] || continue

  # Fixpoint: grow the member set by adding any page that is part_of a current member.
  members="$anchor"; changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    newkids=$(printf '%s\n' "$PO" | awk -F'\t' -v m=" $members " 'index(m, " " $2 " ")>0{print $1}')
    for k in $newkids; do
      case " $members " in *" $k "*) ;; *) members="$members $k"; changed=1 ;; esac
    done
  done

  for node in $members; do set_project "$node" "$proj"; done
done < "$REG"
echo "backfill: done"
