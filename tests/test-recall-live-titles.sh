#!/bin/bash
# pins: SB_EVAL_TITLE_SAMPLE — caps the live-title sample to a small deterministic count so the probe runs fast against the real wiki corpus
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

# Same-effective-query titles dedupe to ONE probe (date tokens are dropped by the
# engine, so a daily series can never self-recall at k=2 — don't flood the report):
DUP=$(mktemp -d); trap 'rm -rf "$DUP"' EXIT
mkdir -p "$DUP/wiki/state"
for d in 01 02 03; do
  printf -- '---\ntitle: "Daily digest — 2026-06-%s"\ntype: state\n---\n\n# Daily digest — 2026-06-%s\n\ncontent %s\n' "$d" "$d" "$d" \
    > "$DUP/wiki/state/digest-2026-06-$d.md"
done
OUT=$(bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$DUP" --k 2 2>&1)
echo "$OUT" | grep -q 'queries=1' || fail "duplicate-title series not deduped to one query: $OUT"

echo "PASS: live-title probe self-recalls the fixture corpus"
echo "ALL PASS"
