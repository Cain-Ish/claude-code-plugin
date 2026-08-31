#!/usr/bin/env bash
# Release gate: knowledge_search recall@2 + token budget over the fixture corpus.
# Deterministic (BM25-only inside wiki-recall-check). Catches search-ENGINE
# regressions and any ranking/forgetting change that would degrade retrieval.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/tests/fixtures/eval-wiki"
Q="$ROOT/tests/fixtures/eval-queries.jsonl"
echo "test-knowledge-eval.sh"
# Strict recall on the CURATED fixture (R2.2): every golden query must hit — a
# single miss here is a ranking regression (the hub-boost bug showed up as
# exactly one displaced page while the old 0.8 gate stayed green).
# Token gate derived from measurement, not inherited: 22 queries measured 863 tokens
# (2026-08-31, P8 growth 12->22). 2000 = ~2.3x headroom for wording drift; a breach
# means per-query output grew structurally, which is exactly what the gate should catch.
SB_EVAL_MIN_RECALL="${SB_EVAL_MIN_RECALL:-1.0}" \
SB_EVAL_MAX_TOKENS="${SB_EVAL_MAX_TOKENS:-2000}" \
bash "$ROOT/scripts/wiki-recall-check.sh" --corpus "$CORPUS" --queries "$Q" --k 2 --gate
rc=$?
[ "$rc" -eq 0 ] && echo "PASS: recall+token gate" || echo "FAIL: gate rc=$rc"
[ "$rc" -eq 0 ] || exit 1

# Fallback branch of the per-query "top" override (review finding): a malformed
# top value must fall back to K, not hang or zero-out results. The query is a
# known-good golden pair — with top='abc' it must still hit at the K=2 fallback.
TQ=$(mktemp)
printf '%s\n' '{"q":"how does the recency boost work in search","expect":["bm25-recency-boost"],"top":"abc"}' > "$TQ"
SB_EVAL_MIN_RECALL=1.0 bash "$ROOT/scripts/wiki-recall-check.sh" --corpus "$CORPUS" --queries "$TQ" --k 2 --gate >/dev/null 2>&1
trc=$?
rm -f "$TQ"
if [ "$trc" -eq 0 ]; then
  echo "PASS: malformed per-query top falls back to K"
else
  echo "FAIL: malformed top did not fall back to K (rc=$trc)"; exit 1
fi

# top:0 is digits-only but would `head -n 0` the results (query can never hit) —
# must fall back to K like any malformed value (Copilot PR-99 finding).
TQ=$(mktemp)
printf '%s\n' '{"q":"how does the recency boost work in search","expect":["bm25-recency-boost"],"top":0}' > "$TQ"
SB_EVAL_MIN_RECALL=1.0 bash "$ROOT/scripts/wiki-recall-check.sh" --corpus "$CORPUS" --queries "$TQ" --k 2 --gate >/dev/null 2>&1
trc=$?
rm -f "$TQ"
if [ "$trc" -eq 0 ]; then
  echo "PASS: top:0 falls back to K (never zero-outs a query)"
else
  echo "FAIL: top:0 zeroed out the query instead of falling back (rc=$trc)"; exit 1
fi
exit 0
