#!/bin/bash
# scripts/graph-cluster.sh shim -> bundled clustering CLI: clusters a wiki's link graph
# (deterministic label propagation), gated by SB_SUMMARIZE_MIN_CLUSTER, fail-safe to [].
# Spec: docs/specs/2026-06-01-dream-consolidation-v2-design.md §B1.
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
echo "$OUT" | jq -e . >/dev/null 2>&1 || fail "shim did not emit valid JSON: $OUT"
[ "$(echo "$OUT" | jq 'length')" = 1 ] || fail "expected 1 cluster at min 4, got: $OUT"
[ "$(echo "$OUT" | jq -c '.[0].members')" = '["a","b","c","d"]' ] || fail "wrong members: $OUT"
echo "$OUT" | jq -e '.[0].member_hash | length > 0' >/dev/null || fail "missing member_hash"
pass "min 4 -> one cluster {a,b,c,d}; triangle excluded; member_hash present"

# --- min 3: both qualify, deterministic order (by id) ---
OUT3=$(SB_SUMMARIZE_MIN_CLUSTER=3 bash "$SHIM" --knowledge-dir "$KD")
[ "$(echo "$OUT3" | jq 'length')" = 2 ] || fail "expected 2 clusters at min 3, got: $OUT3"
[ "$(echo "$OUT3" | jq -r '.[1].members | join(",")')" = 'x,y,z' ] || fail "triangle cluster wrong: $OUT3"
pass "SB_SUMMARIZE_MIN_CLUSTER=3 -> 2 clusters (4-clique + triangle)"

# --- determinism: identical output across runs ---
[ "$(bash "$SHIM" --knowledge-dir "$KD")" = "$OUT" ] || fail "non-deterministic output across runs"
pass "deterministic across runs"

# --- fail-safe: bundle unreachable -> [] exit 0 ---
OUT4=$(CLAUDE_PLUGIN_ROOT=/nonexistent bash "$SHIM" --knowledge-dir "$KD"); rc=$?
[ "$rc" -eq 0 ] && [ "$OUT4" = '[]' ] || fail "fail-safe expected []/exit0, got rc=$rc out=$OUT4"
pass "fail-safe [] when bundle unavailable"

echo; echo "ALL PASS"
