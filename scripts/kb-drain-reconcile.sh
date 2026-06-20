#!/usr/bin/env bash
# Deterministic, idempotent raw-inbox bookkeeping sync (Phase 4c safety net).
#
# Scans wiki nodes for "(raw <id>)" back-refs and marks those raw items processed:
#   status: processed
#   target_node: <node-slug>
#
# Repairs truncated drain runs: nodes exist but items stayed "unprocessed" ->
# re-running reconcile prevents re-drain duplicates. Idempotent (already-processed
# items skipped). Missing raw IDs skipped silently. Never deletes raw items.
#
# Usage: bash kb-drain-reconcile.sh [--knowledge-dir <dir>] [--brain-dir <dir>]
#                                    [--slug <slug>] [--verbose]
set -u

KDIR="" BDIR="" SLUG="" VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift 2 ;;
    --brain-dir)     BDIR="${2:-}"; shift 2 ;;
    --slug)          SLUG="${2:-}"; shift 2 ;;
    --verbose|-v)    VERBOSE=1; shift ;;
    *) shift ;;
  esac
done

[ -n "$KDIR" ] || KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
[ -n "$BDIR" ] || BDIR="${BRAIN_DIR:-$HOME/.second-brain}"
KDIR="${KDIR/#\~/$HOME}"; BDIR="${BDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"

[ -d "$WIKI" ]            || { echo "reconciled 0 item(s) (marked processed from wiki back-refs)"; exit 0; }
[ -d "$BDIR/projects" ]   || { echo "reconciled 0 item(s) (marked processed from wiki back-refs)"; exit 0; }

# Build list of raw dirs to search.
raw_dirs=()
if [ -n "$SLUG" ]; then
  [ -d "$BDIR/projects/$SLUG/raw" ] && raw_dirs+=("$BDIR/projects/$SLUG/raw")
else
  for d in "$BDIR/projects"/*/raw; do [ -d "$d" ] && raw_dirs+=("$d"); done
fi

reconciled=0

while IFS= read -r node_path; do
  [ -f "$node_path" ] || continue
  node_slug=$(basename "$node_path" .md)

  # Extract all (raw <id>) back-refs from this node.
  raw_ids=$(grep -oE '\(raw [^)]+\)' "$node_path" 2>/dev/null \
    | sed 's/^(raw //; s/)$//' | tr -d '\r') || true
  [ -n "$raw_ids" ] || continue

  while IFS= read -r raw_id; do
    [ -n "$raw_id" ] || continue

    # Find the raw item file.
    raw_file=""
    for rdir in ${raw_dirs[@]+"${raw_dirs[@]}"}; do
      [ -f "$rdir/${raw_id}.md" ] && { raw_file="$rdir/${raw_id}.md"; break; }
    done
    if [ -z "$raw_file" ]; then
      [ "$VERBOSE" = 1 ] && echo "  skip: (raw $raw_id) — not found"
      continue
    fi

    # Check current status (tr -d '\r': Windows jq/CRLF safety).
    cur=$(grep -m1 '^status:' "$raw_file" 2>/dev/null | sed 's/^status:[[:space:]]*//' | tr -d '\r ')
    if [ "$cur" = "processed" ]; then
      [ "$VERBOSE" = 1 ] && echo "  skip: (raw $raw_id) — already processed"
      continue
    fi

    # Rewrite: replace status:, upsert target_node: (insert after status if absent).
    tmp="${raw_file}.reconcile.$$"
    awk -v slug="$node_slug" '
      /^status:[[:space:]]/ && !s { print "status: processed"; s=1; next }
      /^target_node:[[:space:]]/ && !n { print "target_node: " slug; n=1; next }
      s && !n && /^[^[:space:]-]/ { print "target_node: " slug; n=1 }
      { print }
    ' "$raw_file" > "$tmp"

    # Safety: never replace with an empty file or one missing status:processed.
    new_status=$(grep -m1 '^status:' "$tmp" 2>/dev/null | sed 's/^status:[[:space:]]*//' | tr -d '\r ')
    if [ ! -s "$tmp" ] || [ "$new_status" != "processed" ]; then
      rm -f "$tmp"
      echo "reconcile: ERROR — failed to rewrite $raw_file" >&2
      continue
    fi

    mv "$tmp" "$raw_file"
    reconciled=$((reconciled + 1))
    [ "$VERBOSE" = 1 ] && echo "  marked: (raw $raw_id) -> node=$node_slug"

  done <<< "$raw_ids"
done < <(find "$WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort)

echo "reconciled $reconciled item(s) (marked processed from wiki back-refs)"
exit 0
