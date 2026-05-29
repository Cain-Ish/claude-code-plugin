#!/bin/bash
# Append extractor-proposed relationship edges to ~/knowledge/graph/edges.jsonl.
# Pure-bash deterministic write path (no node dependency) so the graph accrues
# even when the LLM extractor / MCP layer is unavailable. The LLM only proposes
# the `relations` array; this script validates endpoints + type and either
# appends an op:assert line or quarantines the edge. JSONL line format is the
# contract shared with mcp/src/tools/graph-store.ts.
#
# Usage: echo '<delta-json>' | bash merge-edges.sh --knowledge-dir <dir>
set -u
source "$(dirname "$0")/lib.sh"

KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    *) echo "merge-edges: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI="$KNOWLEDGE_DIR/wiki"
GRAPH_DIR="$KNOWLEDGE_DIR/graph"
LOG="$GRAPH_DIR/edges.jsonl"
QLOG="$GRAPH_DIR/edges-quarantine.jsonl"
VALID_TYPES="requires affects relates part_of supersedes"

RAW=$(cat)
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0   # not JSON → no-op
COUNT=$(echo "$RAW" | jq '(.relations // []) | length' 2>/dev/null || echo 0)
[ "${COUNT:-0}" -eq 0 ] && exit 0

# A slug resolves if a matching page exists anywhere under wiki/ (excluding index.md).
resolves() {
  local slug="$1"
  [ -n "$slug" ] || return 1
  find "$WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .
}

mkdir -p "$GRAPH_DIR"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$RAW" | jq -c '.relations[]?' 2>/dev/null | while IFS= read -r rel; do
  from=$(echo "$rel" | jq -r '.from // empty')
  to=$(echo "$rel"   | jq -r '.to // empty')
  type=$(echo "$rel" | jq -r '.type // "relates"')
  vf=$(echo "$rel"   | jq -r '.valid_from // empty')
  conf=$(echo "$rel" | jq -r '.confidence // "medium"')

  # sanitize slugs (kebab/url-safe) — reuse lib.sh helper; reject on failure
  sfrom=$(sb_sanitize_slug "$from") || continue
  sto=$(sb_sanitize_slug "$to") || continue

  # validate edge type
  case " $VALID_TYPES " in *" $type "*) : ;; *) continue ;; esac

  # build the record (valid_from optional)
  if [ -n "$vf" ]; then
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg vf "$vf" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_from:$vf,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  else
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  fi

  # endpoint guard: both must resolve to real pages, else quarantine
  if resolves "$sfrom" && resolves "$sto"; then
    printf '%s\n' "$rec" >> "$LOG"
  else
    printf '%s\n' "$rec" >> "$QLOG"
  fi
done

exit 0
