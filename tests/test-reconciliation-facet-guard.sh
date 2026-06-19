#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings" "$KD/graph"
# a child member page that ALREADY carries its own (leaf) facet
printf -- '---\ntitle: X\ntype: learnings\nproject: acme__web\n---\nbody\n' > "$KD/wiki/learnings/x.md"
# registry registers EACH project as its OWN anchor (never the parent → no propagation)
printf '{"anchor":"acme","project":"acme"}\n{"anchor":"acme__web","project":"acme__web"}\n' > "$KD/graph/project-registry.jsonl"
# a project-level part_of edge child→parent (graph navigation only)
printf '{"op":"assert","from":"acme__web","to":"acme","type":"part_of","recorded_at":"2026-06-18T00:00:00Z"}\n' > "$KD/graph/edges.jsonl"
KNOWLEDGE_DIR="$KD" bash "$HERE/scripts/kb-project-backfill.sh" >/dev/null 2>&1
FACET=$(grep -E '^project:' "$KD/wiki/learnings/x.md" | head -1)
if [ "$FACET" = "project: acme__web" ]; then echo "PASS: child facet preserved (not rewritten to parent)"; else echo "FAIL: child facet became [$FACET]"; rm -rf "$TMP"; exit 1; fi
rm -rf "$TMP"; echo "ALL PASS"
