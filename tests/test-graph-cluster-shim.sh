#!/bin/bash
# pins: SB_DREAM_REFLECT — kill-switch test: asserts =off disables the reflect gate independently
# pins: SB_DREAM_SUMMARIZE — kill-switch test: asserts =off disables the summarize gate independently
# scripts/graph-cluster.sh shim -> bundled clustering CLI: clusters a wiki's link graph
# (deterministic label propagation), gated by SB_SUMMARIZE_MIN_CLUSTER, fail-safe to [].
# Spec: archive/docs branch, docs/specs/2026-06-01-dream-consolidation-v2-design.md §B1.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SHIM="$ROOT/scripts/graph-cluster.sh"
BUNDLE="$ROOT/mcp/dist/tools/graph-cluster-cli.bundle.js"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
[ -f "$SHIM" ] || fail "scripts/graph-cluster.sh not found"
[ -f "$BUNDLE" ] || fail "build mcp first: cd mcp && npm run build (missing $BUNDLE)"
export CLAUDE_PLUGIN_ROOT="$ROOT"

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/entities"
# page <slug> <related...>  — writes related: [[r1]], [[r2]] frontmatter
page(){ local slug="$1"; shift; local rel=""; for r in "$@"; do rel="${rel}[[${r}]], "; done
  printf '%s\n' '---' "title: $slug" 'type: entities' "related: ${rel%, }" '---' "# $slug body" \
    > "$KD/wiki/entities/$slug.md"; }
# 4-clique {a,b,c,d} (converges) + a SEPARATE triangle {x,y,z} (converges); no bridge.
page a b c d; page b a c d; page c a b d; page d a b c
page x y z; page y x z; page z x y

# --- default min 4: only the 4-clique qualifies ---
OUT=$(bash "$SHIM" --knowledge-dir "$KD")
[ -n "$OUT" ] && echo "$OUT" | jq -e . >/dev/null 2>&1 || fail "shim did not emit valid JSON: $OUT"
[ "$(echo "$OUT" | jq 'length')" = 1 ] || fail "expected 1 cluster at min 4, got: $OUT"
[ "$(echo "$OUT" | jq -c '.[0].members')" = '["a","b","c","d"]' ] || fail "wrong members: $OUT"
[ -n "$OUT" ] && echo "$OUT" | jq -e '.[0].member_hash | length > 0' >/dev/null || fail "missing member_hash"
pass "min 4 -> one cluster {a,b,c,d}; triangle excluded; member_hash present"

# --- min 3: both qualify, deterministic order (by id) ---
OUT3=$(SB_SUMMARIZE_MIN_CLUSTER=3 bash "$SHIM" --knowledge-dir "$KD")
[ "$(echo "$OUT3" | jq 'length')" = 2 ] || fail "expected 2 clusters at min 3, got: $OUT3"
[ "$(echo "$OUT3" | jq -r '.[1].members | join(",")')" = 'x,y,z' ] || fail "triangle cluster wrong: $OUT3"
pass "SB_SUMMARIZE_MIN_CLUSTER=3 -> 2 clusters (4-clique + triangle)"

# --- determinism: identical output across runs ---
[ "$(bash "$SHIM" --knowledge-dir "$KD")" = "$OUT" ] || fail "non-deterministic output across runs"
pass "deterministic across runs"

# --- SB_SUMMARIZE_MAX_PAGES cap (keeps the largest cluster) ---
OUTC=$(SB_SUMMARIZE_MIN_CLUSTER=3 SB_SUMMARIZE_MAX_PAGES=1 bash "$SHIM" --knowledge-dir "$KD")
[ "$(echo "$OUTC" | jq 'length')" = 1 ] || fail "MAX_PAGES=1 should cap to 1 cluster: $OUTC"
[ "$(echo "$OUTC" | jq -c '.[0].members')" = '["a","b","c","d"]' ] || fail "cap should keep the largest cluster: $OUTC"
pass "SB_SUMMARIZE_MAX_PAGES caps to largest-first"

# --- fail-safe: bundle unreachable -> [] exit 0 ---
OUT4=$(CLAUDE_PLUGIN_ROOT=/nonexistent bash "$SHIM" --knowledge-dir "$KD"); rc=$?
[ "$rc" -eq 0 ] && [ "$OUT4" = '[]' ] || fail "fail-safe expected []/exit0, got rc=$rc out=$OUT4"
pass "fail-safe [] when bundle unavailable"

# --- set -u guard: --knowledge-dir with NO value must not crash (rc 0, fail-safe) ---
OUT5=$(CLAUDE_PLUGIN_ROOT=/nonexistent bash "$SHIM" --knowledge-dir 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "shim crashed (rc=$rc) on bare --knowledge-dir under set -u: $OUT5"
pass "bare --knowledge-dir does not trip set -u"

# --- plain YAML inline list related: [a, b] (addFrontmatter convention) is parsed ---
KD2="$TMP/knowledge2"; mkdir -p "$KD2/wiki/entities"
pageplain(){ local slug="$1"; shift; local list=""; for r in "$@"; do list="${list}${r}, "; done
  printf '%s\n' '---' "title: $slug" 'type: entities' "related: [${list%, }]" '---' "# $slug" \
    > "$KD2/wiki/entities/$slug.md"; }
pageplain p q r; pageplain q p r; pageplain r p q     # triangle via plain related: [..]
OUTP=$(SB_SUMMARIZE_MIN_CLUSTER=3 bash "$SHIM" --knowledge-dir "$KD2")
[ "$(echo "$OUTP" | jq -r '.[0].members | join(",")')" = "p,q,r" ] || fail "plain related:[a,b] not clustered: $OUTP"
pass "plain YAML list related: [a, b] is parsed (clusters p,q,r)"

# --- independent kill switches: --gate reflect honors SB_DREAM_REFLECT; default honors SB_DREAM_SUMMARIZE ---
[ "$(SB_DREAM_REFLECT=off bash "$SHIM" --gate reflect --knowledge-dir "$KD")" = '[]' ] \
  || fail "SB_DREAM_REFLECT=off must gate the --gate reflect consumer to []"
pass "SB_DREAM_REFLECT=off gates the reflect consumer"
[ "$(SB_DREAM_SUMMARIZE=off bash "$SHIM" --gate reflect --knowledge-dir "$KD")" != '[]' ] \
  || fail "SB_DREAM_SUMMARIZE=off must NOT gate --gate reflect (switches are independent)"
pass "reflect consumer is independent of SB_DREAM_SUMMARIZE"
[ "$(SB_DREAM_SUMMARIZE=off bash "$SHIM" --knowledge-dir "$KD")" = '[]' ] \
  || fail "SB_DREAM_SUMMARIZE=off must gate the default (summarize) consumer to []"
pass "SB_DREAM_SUMMARIZE=off gates the summarize consumer"
[ "$(SB_DREAM_REFLECT=off bash "$SHIM" --knowledge-dir "$KD")" != '[]' ] \
  || fail "SB_DREAM_REFLECT=off must NOT gate the default summarize consumer"
pass "summarize consumer is independent of SB_DREAM_REFLECT"

# --- REFLECT feedback-loop guard: generated pages are excluded from cluster INPUT ---
# A reflection page (generated: true, related: [all members]) written by a prior dream
# must NOT join its own cluster on the next run: it would defeat member_hash idempotence
# (the LLM re-reflects every dream) and, sorting lexicographically first, could BECOME
# the cluster id (spawning reflection-reflection-<id> pages). Regression lock: drop the
# generated:true filter in graph-cluster-cli.ts and members gain "reflection-a" (FAIL).
KD3="$TMP/knowledge3"; mkdir -p "$KD3/wiki/entities" "$KD3/wiki/learnings"
page3(){ local slug="$1"; shift; local rel=""; for r in "$@"; do rel="${rel}[[${r}]], "; done
  printf '%s\n' '---' "title: $slug" 'type: entities' "related: ${rel%, }" '---' "# $slug body" \
    > "$KD3/wiki/entities/$slug.md"; }
page3 a b c d; page3 b a c d; page3 c a b d; page3 d a b c
printf '%s\n' '---' 'title: reflection-a' 'type: learnings' 'generated: true' 'reflection: true' \
  'related: [a, b, c, d]' 'member_hash: deadbeef' '---' '# synthesized practice' \
  > "$KD3/wiki/learnings/reflection-a.md"
OUTR=$(bash "$SHIM" --knowledge-dir "$KD3")
[ "$(echo "$OUTR" | jq 'length')" = 1 ] || fail "reflection fixture: expected 1 cluster, got: $OUTR"
[ "$(echo "$OUTR" | jq -c '.[0].members')" = '["a","b","c","d"]' ] \
  || fail "REFLECT feedback loop: generated reflection page joined its own cluster: $OUTR"
[ "$(echo "$OUTR" | jq -r '.[0].id')" = "a" ] \
  || fail "cluster id churned (expected 'a'): $OUTR"
pass "generated (reflection) page excluded from cluster input; id + members stable"

echo; echo "ALL PASS"
