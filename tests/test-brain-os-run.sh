#!/usr/bin/env bash
# pins: SB_BRAIN_OS — kill-switch test: asserts =off disables the whole offline lane
# pins: SB_BRAIN_OS_NO_LLM — forces the no-LLM deterministic path so the run is hermetic (no model spawn)
# pins: SB_BRAIN_OS_DEADLINE — D116: hands the engine a near-expired budget so the embed-warm
#   pass's sb_timeout bound is exercised deterministically instead of waiting on a real 7200s window
# pins: SB_CODEMAP_REPO — D118: points the codemap pass at a refused ($HOME) target directly,
#   bypassing the registry root-picker so the registration-refusal defense-in-depth is exercised
# brain-os-run.sh — the OFFLINE ENGINE seam. Asserts the contract that makes it safe to
# put every out-of-band pass behind one entry point:
#   - it is OPTIONAL: brain_os:false / SB_BRAIN_OS=off disables the whole offline lane and
#     nothing else in the plugin changes (the plugin must work without the engine);
#   - each pass keeps its OWN gate, so enabling the engine changes no defaults;
#   - a failing pass does not abort the lane, and never fails silently;
#   - the embedding warm pass writes the wiki vector cache WITHOUT touching live
#     access-count telemetry (hermeticity);
#   - the drainer delegates to it (one seam, not four inline blocks).
# ORACLE: files the passes actually create, and a stub PATH we control.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
ENGINE="$ROOT/scripts/brain-os-run.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export HOME="$SB" BRAIN_DIR="$SB/brain" KNOWLEDGE_DIR="$SB/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" CLAUDE_PLUGIN_ROOT="$ROOT"
mkdir -p "$BRAIN_DIR" "$KNOWLEDGE_DIR/wiki/learnings"
printf -- '---\ntitle: seed page\ndescription: a seed page for the engine test\ntype: learnings\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# seed page\n\nbody text about widgets and calibration\n' \
  > "$KNOWLEDGE_DIR/wiki/learnings/seed-page.md"

echo "=== E1: disabled engine is a true no-op ==="
printf '{"brain_os": false, "auto_improve": true, "auto_maintain": true}\n' > "$BRAIN_DIR/config.json"
rm -f "$BRAIN_DIR/.last-maintain"
bash "$ENGINE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "E1: disabled engine exited $rc (must be a clean no-op)"
[ ! -f "$BRAIN_DIR/.last-maintain" ] && pass "E1: brain_os:false runs no pass (deterministic upkeep did not fire)" \
  || fail "E1: a pass ran despite brain_os:false"

printf '{"brain_os": true, "auto_improve": true}\n' > "$BRAIN_DIR/config.json"
SB_BRAIN_OS=off bash "$ENGINE" >/dev/null 2>&1
[ ! -f "$BRAIN_DIR/.last-maintain" ] && pass "E1: SB_BRAIN_OS=off env kill switch also disables the lane" \
  || fail "E1: env kill switch ignored"

echo "=== E2: enabled engine runs the deterministic pass; per-pass gates still apply ==="
printf '{"brain_os": true, "auto_improve": true, "auto_maintain": false, "auto_codemap": false, "auto_embed": false}\n' > "$BRAIN_DIR/config.json"
bash "$ENGINE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "E2: engine exited $rc"
[ -f "$BRAIN_DIR/.last-maintain" ] && pass "E2: deterministic upkeep ran under the engine" \
  || fail "E2: deterministic upkeep did not run"
[ ! -d "$BRAIN_DIR/dreams" ] || [ -z "$(ls -A "$BRAIN_DIR/dreams" 2>/dev/null)" ] \
  && pass "E2: auto_maintain:false kept the token-spending lane OFF" \
  || fail "E2: consolidation lane ran despite auto_maintain:false"

# auto_improve:false must switch the deterministic pass off even with the engine on.
rm -f "$BRAIN_DIR/.last-maintain"
printf '{"brain_os": true, "auto_improve": false, "auto_maintain": false, "auto_codemap": false, "auto_embed": false}\n' > "$BRAIN_DIR/config.json"
bash "$ENGINE" >/dev/null 2>&1
[ ! -f "$BRAIN_DIR/.last-maintain" ] && pass "E2: per-pass gate (auto_improve:false) still honored under the engine" \
  || fail "E2: engine overrode a per-pass gate"

echo "=== E3: embedding warm pass caches vectors without polluting access counts ==="
if [ -f "$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js" ] && command -v node >/dev/null 2>&1; then
  printf '{"brain_os": true, "auto_improve": false, "auto_maintain": false, "auto_codemap": false, "auto_embed": true}\n' > "$BRAIN_DIR/config.json"
  rm -f "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json" "$BRAIN_DIR/access-counts.json"
  bash "$ENGINE" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "E3: engine exited $rc during the warm pass"
  # With embeddings unavailable (no vector deps) the cache legitimately stays absent — assert
  # the invariant that always holds: the warm pass must never write live access telemetry.
  [ ! -f "$BRAIN_DIR/access-counts.json" ] \
    && pass "E3: warm pass wrote NO access-count telemetry (hermetic)" \
    || fail "E3: warm pass polluted live access-counts.json"
  if [ -f "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json" ]; then
    jq -e '.entries | length > 0' "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json" >/dev/null 2>&1 \
      && pass "E3: wiki embedding cache populated offline" \
      || fail "E3: cache file written but empty"
  else
    echo "  NOTE: no embedding cache — vector deps unavailable here (bm25-only); hermeticity still asserted"
  fi
  # Disabling the pass must stop it.
  rm -f "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json"
  printf '{"brain_os": true, "auto_improve": false, "auto_maintain": false, "auto_codemap": false, "auto_embed": false}\n' > "$BRAIN_DIR/config.json"
  bash "$ENGINE" >/dev/null 2>&1
  [ ! -f "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json" ] \
    && pass "E3: auto_embed:false skips the warm pass" || fail "E3: warm pass ran despite auto_embed:false"
else
  echo "  SKIP: search bundle or node unavailable — warm pass not exercised"
fi

echo "=== E4: a failing pass is logged, not swallowed, and does not abort the lane ==="
# Point the engine at a maintain script that fails, via a stub plugin root.
STUBROOT="$SB/stubroot"; mkdir -p "$STUBROOT/scripts"
cp "$ROOT/scripts/brain-os-run.sh" "$ROOT/scripts/lib.sh" "$STUBROOT/scripts/"
printf '#!/bin/bash\nexit 7\n' > "$STUBROOT/scripts/maintain-deterministic.sh"
chmod +x "$STUBROOT/scripts/maintain-deterministic.sh"
printf '{"brain_os": true, "auto_improve": true, "auto_maintain": false, "auto_codemap": false, "auto_embed": false}\n' > "$BRAIN_DIR/config.json"
rm -f "$BRAIN_DIR/error-log.jsonl"
CLAUDE_PLUGIN_ROOT="$STUBROOT" bash "$STUBROOT/scripts/brain-os-run.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "E4: a failing pass does not abort the lane (engine still exits 0)" \
  || fail "E4: engine exited $rc — one bad pass wedged the drain cycle"
grep -q "pass 'maintain' exited" "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  && pass "E4: the failure was logged LOUDLY (error-log)" || fail "E4: pass failure swallowed silently"

echo "=== E4b: retention pruning is NOT behind the engine gate ==="
# Retention must survive brain_os:false. Gating regenerable-artifact GC behind an opt-in is
# exactly how bak_ttl_days went silently inert once before.
grep -q 'sb-prune-archives' "$ROOT/scripts/brain-os-run.sh"   && fail "E4b: prune runs inside the engine — brain_os:false would stop retention GC"   || pass "E4b: prune is not an engine pass"
grep -q 'sb-prune-archives' "$ROOT/scripts/extract-drain.sh"   && pass "E4b: prune runs in the drainer, outside the engine gate"   || fail "E4b: prune lost entirely — retention GC no longer runs anywhere"

echo "=== E4c: a deferred tick still runs the LLM-free passes ==="
# The defer exists only because `claude -p` hangs under the OAuth lock; the deterministic
# passes need no lock. Skipping them too starves an always-on operator completely.
grep -q 'SB_BRAIN_OS_NO_LLM' "$ROOT/scripts/extract-drain.sh"   && pass "E4c: the drainer runs the engine LLM-free on a deferred tick"   || fail "E4c: a deferred tick skips the engine entirely (starvation)"
printf '{"brain_os": true, "auto_improve": true, "auto_maintain": true, "auto_codemap": false, "auto_embed": false}
' > "$BRAIN_DIR/config.json"
rm -f "$BRAIN_DIR/.last-maintain"; rm -rf "$BRAIN_DIR/dreams"; mkdir -p "$BRAIN_DIR/dreams"
SB_BRAIN_OS_NO_LLM=1 bash "$ENGINE" >/dev/null 2>&1
[ -f "$BRAIN_DIR/.last-maintain" ] && pass "E4c: NO_LLM still ran the deterministic upkeep"   || fail "E4c: NO_LLM skipped the deterministic passes too"
[ -z "$(ls -A "$BRAIN_DIR/dreams" )" ]   && pass "E4c: NO_LLM skipped the token-spending consolidation lane"   || fail "E4c: NO_LLM still spawned the consolidation lane"

echo "=== E4d (D118): codemap refuses \$HOME/a temp root as its target, even via SB_CODEMAP_REPO ==="
# Defense-in-depth for the registry-picker AND an operator-set override: this is the
# actual expensive-walk choke point brain-os-run.sh would otherwise hand a whole-home
# directory to code-map-cli (the live incident: a 9.6MB graph.json full of AppData
# browser-extension bundles named as "architectural spine").
printf '{"brain_os": true, "auto_improve": false, "auto_maintain": false, "auto_codemap": true, "auto_embed": false}\n' > "$BRAIN_DIR/config.json"
rm -f "$BRAIN_DIR/error-log.jsonl" "$BRAIN_DIR/audit-log.jsonl"
SB_CODEMAP_REPO="$HOME" bash "$ENGINE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "E4d: engine exited $rc for a refused codemap target"
grep -q 'gate=registration refused home' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null \
  && pass "E4d: \$HOME as SB_CODEMAP_REPO is refused (audit-log breadcrumb)" \
  || fail "E4d: no refusal breadcrumb for \$HOME as the codemap target"
grep -q 'gate=registration refused' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  && fail "E4d: refusal breadcrumb leaked into error-log (should be audit-log trace)"

echo "=== E4e (D116): embed-warm/codemap passes are bounded by the remaining lock budget ==="
# Before D116 these were bare, unbounded `node` spawns — a stuck/slow one could run past
# extract-drain.sh's SB_DRAIN_LOCK_STALE (7200s) steal-threshold. Stub the embed-warm CLI
# with a node script that never exits, hand brain-os-run.sh a near-expired
# SB_BRAIN_OS_DEADLINE (as extract-drain.sh's mkdir-lock branch would export), and assert
# the pass is actually killed within a bounded time — not left running.
if command -v node >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  BUDGETROOT="$SB/budgetroot"; mkdir -p "$BUDGETROOT/mcp/dist/tools"
  cat > "$BUDGETROOT/mcp/dist/tools/knowledge-search-cli.bundle.js" <<'STUBJS'
setInterval(function(){}, 1000);   // never exits on its own
STUBJS
  printf '{"brain_os": true, "auto_improve": false, "auto_maintain": false, "auto_codemap": false, "auto_embed": true}\n' > "$BRAIN_DIR/config.json"
  rm -f "$KNOWLEDGE_DIR/wiki/.embeddings-cache.json"
  START=$(date +%s)
  SB_BRAIN_OS_DEADLINE=$(( START + 5 )) CLAUDE_PLUGIN_ROOT="$BUDGETROOT" timeout 40 bash "$ENGINE" >/dev/null 2>&1; rc=$?
  END=$(date +%s)
  ELAPSED=$(( END - START ))
  [ "$rc" -eq 0 ] || fail "E4e: engine exited $rc when a bounded pass was killed (lane must still exit 0)"
  [ "$ELAPSED" -lt 30 ] \
    && pass "E4e: embed-warm pass was bounded (killed within ${ELAPSED}s, not left running to the outer 40s timeout)" \
    || fail "E4e: embed-warm pass ran unbounded (${ELAPSED}s — outer timeout had to kill it)"
  grep -q 'embedding warm pass failed or exceeded' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
    && pass "E4e: the bounded-timeout kill was logged loudly" \
    || fail "E4e: no log entry for the timed-out embed-warm pass"
else
  echo "  SKIP: E4e — node or timeout(1) unavailable"
fi

echo "=== E5: the drainer delegates to the engine (one seam) ==="
grep -q 'brain-os-run.sh' "$ROOT/scripts/extract-drain.sh" \
  && pass "E5: extract-drain.sh calls the engine" || fail "E5: drainer does not call the engine"
for legacy in maintain-deterministic.sh maintain-llm-drain.sh code-map-cli.bundle.js; do
  grep -q "$legacy" "$ROOT/scripts/extract-drain.sh" \
    && fail "E5: '$legacy' still invoked inline in the drainer (two call paths)" \
    || pass "E5: '$legacy' no longer inline in the drainer"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
