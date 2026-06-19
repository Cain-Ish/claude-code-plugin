#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)

# ---------------------------------------------------------------------------
# Test 1 (original): child page that ALREADY carries its own (leaf) facet
# The never-overwrite guard must preserve it even when the parent anchor walks
# into that subtree.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings" "$KD/graph"
printf -- '---\ntitle: X\ntype: learnings\nproject: acme__web\n---\nbody\n' > "$KD/wiki/learnings/x.md"
printf '{"anchor":"acme","project":"acme"}\n{"anchor":"acme__web","project":"acme__web"}\n' > "$KD/graph/project-registry.jsonl"
printf '{"op":"assert","from":"acme__web","to":"acme","type":"part_of","recorded_at":"2026-06-18T00:00:00Z"}\n' > "$KD/graph/edges.jsonl"
KNOWLEDGE_DIR="$KD" bash "$HERE/scripts/kb-project-backfill.sh" >/dev/null 2>&1
FACET=$(grep -E '^project:' "$KD/wiki/learnings/x.md" | head -1)
if [ "$FACET" = "project: acme__web" ]; then echo "PASS (T1): child facet preserved (not rewritten to parent)"; else echo "FAIL (T1): child facet became [$FACET]"; rm -rf "$TMP"; exit 1; fi
rm -rf "$TMP"

# ---------------------------------------------------------------------------
# Test 2 (new — order-independence / leaf-first):
# An UNATTRIBUTED page that is part_of acme__web.  The registry lists the
# PARENT anchor (acme) BEFORE the child anchor (acme__web) to exercise the
# worst-case ordering.  Before the fix the parent-first walk would stamp the
# page "project: acme"; after the fix the leaf-first sort means acme__web is
# processed first, stamping "project: acme__web", and the guard then blocks
# the later acme row from overwriting it.
# ---------------------------------------------------------------------------
TMP2=$(mktemp -d); KD2="$TMP2/knowledge"; mkdir -p "$KD2/wiki/learnings" "$KD2/graph"
# Unattributed page (no project: facet yet) that lives under acme__web
printf -- '---\ntitle: Y\ntype: learnings\n---\nbody\n' > "$KD2/wiki/learnings/y.md"
# Registry: PARENT listed FIRST (the adversarial ordering that exposed the bug)
printf '{"anchor":"acme","project":"acme"}\n{"anchor":"acme__web","project":"acme__web"}\n' > "$KD2/graph/project-registry.jsonl"
# Edges: y is part_of acme__web; acme__web is part_of acme
printf '{"op":"assert","from":"y","to":"acme__web","type":"part_of","recorded_at":"2026-06-18T00:00:00Z"}\n' >> "$KD2/graph/edges.jsonl"
printf '{"op":"assert","from":"acme__web","to":"acme","type":"part_of","recorded_at":"2026-06-18T00:00:00Z"}\n' >> "$KD2/graph/edges.jsonl"
KNOWLEDGE_DIR="$KD2" bash "$HERE/scripts/kb-project-backfill.sh" >/dev/null 2>&1
FACET2=$(grep -E '^project:' "$KD2/wiki/learnings/y.md" | head -1)
if [ "$FACET2" = "project: acme__web" ]; then echo "PASS (T2): unattributed child page got leaf facet (acme__web), not parent (acme)"; else echo "FAIL (T2): expected [project: acme__web] but got [$FACET2]"; rm -rf "$TMP2"; exit 1; fi
rm -rf "$TMP2"

echo "ALL PASS"
