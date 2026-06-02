#!/bin/bash
# kb-project-suggest.sh: for a slug, print the plurality `project:` among its edge-neighbors
# that already carry a project facet. Deterministic (count desc, then lexical tie-break).
# Empty output when no neighbor has a project. This is the reproducible mechanism the
# knowledge-maintainer uses to assign project: to an unlabeled page (Phase 2, staged).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; S="$ROOT/scripts/kb-project-suggest.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
[ -f "$S" ] || fail "scripts/kb-project-suggest.sh not found"

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/decisions" "$KD/graph"
mk(){ printf '%s\n' '---' "title: $1" 'type: decisions' ${2:+"project: $2"} '---' "# $1" > "$KD/wiki/decisions/$1.md"; }
mk target ""        # the unlabeled page we want a suggestion for
mk nbr-a kiri
mk nbr-b kiri
mk nbr-c bridge
mk lonely ""
# edges: target relates to a,b,c (kiri x2, bridge x1) ⇒ plurality = kiri
e(){ printf '%s\n' "{\"op\":\"assert\",\"from\":\"$1\",\"to\":\"$2\",\"type\":\"relates\",\"valid_from\":\"2026-05-01\",\"valid_to\":null,\"recorded_at\":\"2026-05-01T00:00:00Z\",\"source\":\"x\"}"; }
{ e target nbr-a; e target nbr-b; e target nbr-c; } > "$KD/graph/edges.jsonl"

out=$(KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD" --slug target 2>/dev/null)
[ "$out" = "kiri" ] || fail "expected plurality 'kiri', got '$out'"
pass "plurality project of edge-neighbors is suggested (kiri 2 > bridge 1)"

# a page whose neighbors have NO project facet ⇒ empty suggestion (no-op)
out2=$(KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD" --slug lonely 2>/dev/null)
[ -z "$out2" ] || fail "expected empty suggestion for unconnected page, got '$out2'"
pass "no suggestion when no neighbor carries a project facet"

# determinism: same inputs ⇒ same output
out3=$(KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD" --slug target 2>/dev/null)
[ "$out" = "$out3" ] || fail "non-deterministic ($out vs $out3)"
pass "deterministic"

echo; echo "ALL PASS"
