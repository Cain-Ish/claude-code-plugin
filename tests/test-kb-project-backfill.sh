#!/bin/bash
# Backfill sets project: on pages connected by part_of to a known anchor, deterministically.
# One-shot, idempotent, additive, reversible (remove the project: line). Read-only re: edges.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; S="$ROOT/scripts/kb-project-backfill.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
[ -f "$S" ] || fail "scripts/kb-project-backfill.sh not found"

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/decisions" "$KD/graph"
for s in kiri-redesign kiri-core-design kiri-privilege-split unrelated; do
  printf '%s\n' '---' "title: $s" 'type: decisions' '---' "# $s" > "$KD/wiki/decisions/$s.md"; done
# part_of: core --> redesign (anchor), priv --> core ; unrelated has no edge
printf '%s\n' \
  '{"op":"assert","from":"kiri-core-design","to":"kiri-redesign","type":"part_of","valid_from":"2026-05-01","valid_to":null,"recorded_at":"2026-05-01T00:00:00Z","source":"x"}' \
  '{"op":"assert","from":"kiri-privilege-split","to":"kiri-core-design","type":"part_of","valid_from":"2026-05-01","valid_to":null,"recorded_at":"2026-05-01T00:00:00Z","source":"x"}' \
  > "$KD/graph/edges.jsonl"
# registry maps the anchor slug -> project key
printf '%s\n' '{"anchor":"kiri-redesign","project":"kiri"}' > "$KD/graph/project-registry.jsonl"

KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD" >/dev/null 2>&1 || fail "backfill exited non-zero"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-core-design.md" || fail "core (1 hop) not backfilled"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-privilege-split.md" || fail "priv (2 hops) not backfilled"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-redesign.md" || fail "anchor not backfilled"
grep -q 'project:' "$KD/wiki/decisions/unrelated.md" && fail "unrelated wrongly tagged"
pass "part_of-ancestry backfill is correct and bounded"

# idempotency: a second run must not duplicate the project: line
KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD" >/dev/null 2>&1
n=$(grep -c '^project:' "$KD/wiki/decisions/kiri-core-design.md")
[ "$n" -eq 1 ] || fail "second run duplicated project: line (count=$n)"
pass "idempotent — second run is a no-op"

echo; echo "ALL PASS"
