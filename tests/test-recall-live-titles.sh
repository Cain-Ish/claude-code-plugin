#!/bin/bash
# tests/test-recall-live-titles.sh — R2.2 live-title probe: every wiki page's own
# title, used as a query, must return that page's slug in the top-K. This is the
# invariant the hub-boost bug broke on the real wiki (exact-title page evicted).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

OUT=$(bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$ROOT/tests/fixtures/eval-wiki" --k 2 2>&1) \
  || fail "probe errored: $OUT"
echo "$OUT" | grep -q 'recall@2=1.000' || fail "fixture corpus must self-recall at 1.0, got: $OUT"
echo "$OUT" | grep -qE 'queries=[1-9]' || fail "probe generated no queries: $OUT"

# Gate mode wires through:
bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$ROOT/tests/fixtures/eval-wiki" --k 2 --gate >/dev/null 2>&1 \
  || fail "gate mode failed on a healthy corpus"

# Sample cap honored:
OUT=$(SB_EVAL_TITLE_SAMPLE=3 bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$ROOT/tests/fixtures/eval-wiki" --k 2 2>&1)
echo "$OUT" | grep -q 'queries=3' || fail "SB_EVAL_TITLE_SAMPLE=3 not honored: $OUT"

echo "PASS: live-title probe self-recalls the fixture corpus"
echo "ALL PASS"
