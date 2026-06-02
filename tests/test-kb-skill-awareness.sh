#!/bin/bash
# Guard that the knowledge-editing skills KNOW the 0.23.0 hierarchical structure and how to
# maintain it — so a future edit can't silently drop the old→new migration capability.
# The maintainer OWNS project: assignment (live path); the dream SURFACES suggestions only.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MAINT="$ROOT/agents/knowledge-maintainer.md"
DRUN="$ROOT/agents/dream-runner.md"
DSKILL="$ROOT/skills/dream/SKILL.md"
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
for f in "$MAINT" "$DRUN" "$DSKILL"; do [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }; done

# maintainer: the live owner of project: assignment — must know the facet, both helper scripts,
# the registry, the closed-vocabulary rule, and that reindex projects the MOCs.
grep -q 'project:' "$MAINT"                     && ok "maintainer knows the project: facet"        || bad "maintainer: no project: facet"
grep -q 'kb-project-backfill.sh' "$MAINT"       && ok "maintainer uses backfill (part_of trees)"  || bad "maintainer: no backfill"
grep -q 'kb-project-suggest.sh' "$MAINT"        && ok "maintainer uses suggest (unlabeled pages)" || bad "maintainer: no suggest"
grep -q 'project-registry.jsonl' "$MAINT"       && ok "maintainer reads the project registry"     || bad "maintainer: no registry"
grep -qiE 'closed vocabulary|never invent' "$MAINT" && ok "maintainer respects closed vocabulary" || bad "maintainer: no closed-vocab rule"
grep -qiE 'wiki/projects/|<key>.md|project.*MOC|MOC' "$MAINT" && ok "maintainer knows MOCs are projected" || bad "maintainer: no MOC awareness"

# dream (both surfaces): SURFACE-ONLY — knows project MOCs exist, does NOT assign on the live path.
for d in "$DRUN" "$DSKILL"; do
  lbl=$(basename "$(dirname "$d")")/$(basename "$d")
  grep -qiE 'project MOC|wiki/projects/|projects/.*themes/|project: facet' "$d" && ok "$lbl knows project MOCs" || bad "$lbl: no project MOC awareness"
  # assert the REAL invariant: the dream must NOT assign project: on the live path (the
  # maintainer owns it) — not merely that the words "surface"+"maintainer" co-occur.
  # Tolerate markdown bold: "do **not** assign" / "does NOT assign".
  if grep -qiE 'not\**[[:space:]]*assign' "$d" && grep -qi 'live path' "$d" && grep -qi 'maintainer' "$d"; then
    ok "$lbl is surface-only (explicit 'does not assign on the live path')"
  else
    bad "$lbl: missing explicit 'does not assign on the live path' prohibition"
  fi
done

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
