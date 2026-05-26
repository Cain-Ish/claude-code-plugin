#!/usr/bin/env bash
# Guard the dream FORGET (Phase 2f) wiring + accept-time archiving in the dream skill.
# Behavior is LLM-driven; this asserts the contract the scripts depend on.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/skills/dream/SKILL.md"
P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

grep -q "2f. FORGET" "$D"            && ok "dream has FORGET phase"        || bad "no FORGET phase"
grep -q "SB_WIKI_FORGET=off" "$D"    && ok "kill switch documented"       || bad "no kill switch"
grep -q "wiki-forget-candidates.sh" "$D" && ok "calls candidates script" || bad "no candidates call"
grep -q "forget-manifest.tsv" "$D"   && ok "uses forget-manifest"         || bad "no manifest"
grep -qiE "rc.* 2|exits? 2|fail-safe" "$D" && ok "fail-safe on exit 2"    || bad "no fail-safe"
grep -q "wiki-archive" "$D"          && ok "archives on accept"           || bad "no accept-time archive"
grep -q "knowledge_reindex" "$D"     && ok "reindex after archive"        || bad "no reindex"

# Scripts the FORGET phase + restore depend on must exist + be syntactically valid.
for s in wiki-recall-check wiki-forget-score wiki-forget-candidates; do
  f="$ROOT/scripts/$s.sh"
  [ -f "$f" ] && bash -n "$f" 2>/dev/null && ok "scripts/$s.sh exists + parses" || bad "scripts/$s.sh missing/broken"
done

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
