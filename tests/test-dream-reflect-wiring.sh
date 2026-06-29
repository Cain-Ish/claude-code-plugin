#!/usr/bin/env bash
# Wiring guard: the dream-runner REFLECT phase (P4 reflection op) must stay wired — synthesize a
# GROUNDED cross-cutting practice per actionable cluster, kill-switchable + idempotent, applied on
# accept. Parallels test-dream-forget-wiring.sh. Static greps over the agent + shim (no LLM run).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DR="$ROOT/agents/dream-runner.md"
GC="$ROOT/scripts/graph-cluster.sh"
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
[ -f "$DR" ] || { echo "FAIL: dream-runner.md missing"; exit 1; }
[ -f "$GC" ] || { echo "FAIL: graph-cluster.sh missing"; exit 1; }

grep -qi 'Phase 5b: REFLECT' "$DR"   && ok "dream has REFLECT phase"                 || bad "no REFLECT phase"
grep -q 'SB_DREAM_REFLECT' "$DR"     && ok "REFLECT kill switch documented"          || bad "no SB_DREAM_REFLECT"
grep -q -- '--gate reflect' "$DR"    && ok "calls graph-cluster --gate reflect"      || bad "does not call --gate reflect"
grep -q 'reflection-<id>' "$DR"      && ok "reflection pages slugged reflection-<id>" || bad "no reflection-<id> slug"
grep -qi 'Grounded in' "$DR"         && ok "grounds reflection in member evidence"   || bad "no grounding/evidence citation"
grep -q 'member_hash' "$DR"          && ok "idempotent via member_hash"              || bad "no member_hash idempotence"
grep -qi 'reflect:begin' "$DR"       && ok "synthesis in a marked region"            || bad "no reflect:begin marked region"
# REFLECT must precede REINDEX so its pages are catalogued in the index
awk '/Phase 5b: REFLECT/{r=NR} /Phase 6: REINDEX/{x=NR} END{exit !(r>0 && x>r)}' "$DR" \
  && ok "REFLECT runs before REINDEX" || bad "REFLECT not before REINDEX"
# machine-enforced kill switch lives in the shim (not just agent prose)
grep -q 'SB_DREAM_REFLECT' "$GC"     && ok "graph-cluster.sh machine-enforces SB_DREAM_REFLECT" || bad "shim missing SB_DREAM_REFLECT gate"
grep -q -- '--gate' "$GC"            && ok "graph-cluster.sh accepts --gate"         || bad "shim missing --gate flag"

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
