#!/bin/bash
# Generated project-MOC pages (type: projects) must be category-protected from FORGET, so a
# regenerable Map-of-Content is never archived out from under the projector. Same protection
# class as type: themes. Protection is via the protflag column (candidates.sh filters $5==""),
# independent of the numeric score.
# Spec: archive/docs branch, docs/specs/2026-06-02-knowledge-base-hierarchical-organization-design.md §4.3 / §8.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCORER="$ROOT/scripts/wiki-forget-score.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"

export KNOWLEDGE_DIR="$TMP/knowledge"; export BRAIN_DIR="$TMP/.second-brain"
mkdir -p "$KNOWLEDGE_DIR/wiki/projects" "$KNOWLEDGE_DIR/wiki/misc" "$BRAIN_DIR"
# OLD (so age-protection does NOT apply) + unlinked project-MOC page — only category protection can save it.
printf '%s\n' '---' 'title: kiri' 'type: projects' 'generated: true' '---' '# kiri map of content body for length' \
  > "$KNOWLEDGE_DIR/wiki/projects/kiri.md"
# control: an unrecognized category (hits the *) arm -> unprotected) so the test discriminates.
printf '%s\n' '---' 'title: Misc' 'type: misc' '---' '# misc body here for some length padding padding' \
  > "$KNOWLEDGE_DIR/wiki/misc/misc-x.md"
touch -d '40 days ago' "$KNOWLEDGE_DIR/wiki/projects/kiri.md" "$KNOWLEDGE_DIR/wiki/misc/misc-x.md" 2>/dev/null \
  || { echo "SKIP: touch -d unsupported"; exit 0; }

OUT=$(bash "$SCORER") || fail "scorer failed"
# row: score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag
proj_prot=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="kiri"{print $5}')
misc_prot=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="misc-x"{print $5}')

echo "$proj_prot" | grep -q 'PROTECT:category' || fail "old/unlinked project-MOC NOT category-protected (protflag='$proj_prot')"
pass "old/unlinked project-MOC is PROTECT:category (never a forget candidate)"

[ -z "$misc_prot" ] || fail "control should be unprotected to discriminate (got '$misc_prot')"
pass "control (unrecognized category) is unprotected — test discriminates"

echo; echo "ALL PASS"
