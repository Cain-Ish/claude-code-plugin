#!/bin/bash
# Compile the wiki link graph.
#
# Walks every ~/knowledge/wiki/**/*.md and extracts:
#   1. Typed edges from `graph:` blocks (frontmatter or body):
#        graph:
#          - {relation: depends_on, target: persona-md, evidence: "..."}
#   2. Untyped edges from inline [[wiki-links]] (relation="links_to")
#
# Writes:
#   ~/knowledge/.graph/edges.jsonl
#   ~/knowledge/.graph/nodes.jsonl
#   ~/knowledge/.graph/build-meta.json
#
# Cheap: walks files once. Safe to re-run; output directory is rebuilt each
# invocation.

set -u

# Resolve knowledge dir using the plugin's standard chain.
KNOWLEDGE_DIR="${1:-}"
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-}" ;;
esac
case "$KNOWLEDGE_DIR" in
  ""|*'${user_config.'*) KNOWLEDGE_DIR="$HOME/knowledge" ;;
esac
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

[ -d "$KNOWLEDGE_DIR/wiki" ] || { echo "no wiki at $KNOWLEDGE_DIR/wiki" >&2; exit 0; }

GRAPH_DIR="$KNOWLEDGE_DIR/.graph"
mkdir -p "$GRAPH_DIR"

EDGES="$GRAPH_DIR/edges.jsonl"
NODES="$GRAPH_DIR/nodes.jsonl"
META="$GRAPH_DIR/build-meta.json"

# Hard requirement: jq. All JSON encoding goes through jq so unusual filenames
# or evidence strings can't break the JSONL output downstream.
command -v jq >/dev/null 2>&1 || { echo "compile-graph: jq required, aborting" >&2; exit 1; }

# Truncate (rebuild from scratch each run).
: > "$EDGES"
: > "$NODES"

while IFS= read -r -d '' FILE; do
  REL="${FILE#"$KNOWLEDGE_DIR"/wiki/}"
  CATEGORY="${REL%%/*}"
  SLUG="${REL#*/}"
  SLUG="${SLUG%.md}"
  case "$REL" in
    */*) ;;
    *) SLUG="$CATEGORY"; CATEGORY="root" ;;
  esac

  TITLE=$(grep -m1 '^# ' "$FILE" 2>/dev/null | sed 's/^# //')
  TITLE=${TITLE:-$SLUG}

  jq -nc --arg s "$SLUG" --arg t "$TITLE" --arg c "$CATEGORY" \
    '{slug:$s, title:$t, category:$c}' >> "$NODES"

  # Inline [[wiki-links]] — untyped edges.
  grep -oE '\[\[[a-z0-9][a-z0-9-]*\]\]' "$FILE" 2>/dev/null | sort -u | while IFS= read -r LINK; do
    TARGET="${LINK#[[}"
    TARGET="${TARGET%]]}"
    [ -z "$TARGET" ] && continue
    jq -nc --arg from "$SLUG" --arg to "$TARGET" \
      '{from:$from, to:$to, relation:"links_to"}' >> "$EDGES"
  done

  # Typed edges from `graph:` blocks. POSIX awk extracts raw fields as TSV
  # (relation\ttarget\tevidence), then jq does the JSON encoding so embedded
  # quotes/backslashes/control chars in evidence can't break the output.
  awk '
    function extract(re_str, line,    s) {
      # Pass regex as a string; awk evaluates regex constants against $0 when
      # passed as function args, returning a boolean instead of the regex.
      if (match(line, re_str)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^[^:]*:[[:space:]]*/, "", s)
        gsub(/^"|"$/, "", s)
        return s
      }
      return ""
    }
    /^graph:[[:space:]]*$/ { in_graph = 1; next }
    in_graph && /^[[:space:]]*-[[:space:]]*\{/ {
      rel = extract("relation:[[:space:]]*[a-z_]+", $0)
      tgt = extract("target:[[:space:]]*[A-Za-z0-9_-]+", $0)
      ev  = extract("evidence:[[:space:]]*\"[^\"]*\"", $0)
      if (rel != "" && tgt != "") {
        printf "%s\t%s\t%s\n", rel, tgt, ev
      }
      next
    }
    in_graph && /^[^[:space:]-]/ { in_graph = 0 }
  ' "$FILE" | while IFS=$'\t' read -r REL TGT EV; do
    [ -z "$REL" ] || [ -z "$TGT" ] && continue
    jq -nc --arg from "$SLUG" --arg to "$TGT" --arg r "$REL" --arg ev "$EV" \
      '{from:$from, to:$to, relation:$r, evidence:$ev}' >> "$EDGES"
  done
done < <(find "$KNOWLEDGE_DIR/wiki" -name '*.md' -print0 2>/dev/null)

EDGE_COUNT=$(wc -l < "$EDGES" 2>/dev/null | tr -d ' ')
NODE_COUNT=$(wc -l < "$NODES" 2>/dev/null | tr -d ' ')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -nc --arg t "$NOW" --argjson e "${EDGE_COUNT:-0}" --argjson n "${NODE_COUNT:-0}" \
  '{built_at:$t, edges_count:$e, nodes_count:$n}' > "$META"

echo "graph compiled: $NODE_COUNT nodes, $EDGE_COUNT edges -> $GRAPH_DIR" >&2
exit 0
