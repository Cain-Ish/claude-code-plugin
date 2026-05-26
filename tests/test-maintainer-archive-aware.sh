#!/usr/bin/env bash
# Structural guard: the knowledge-maintainer agent must know the cold-tier archive /
# forgetting model — honor it, restore-before-recreate, surface candidates, never archive.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/agents/knowledge-maintainer.md"
P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
grep -qi "wiki-archive" "$M"            && ok "mentions the cold-tier archive"      || bad "no archive mention"
grep -q  "wiki-archived-slugs.sh" "$M"  && ok "checks net-archived before create"   || bad "no archived-slugs check"
grep -q  "wiki-restore.sh" "$M"         && ok "restores instead of recreating"      || bad "no restore guidance"
grep -qi "wiki-forget-score.sh" "$M"    && ok "surfaces forget candidates"          || bad "no forget-candidate surfacing"
grep -qiE "never archive|not.* archive|dream.*sole|sole gated" "$M" && ok "states it never archives (dream-only)" || bad "no 'never archive' boundary"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
