#!/bin/bash
# Tests for cost-router/scripts/opus-budget.sh
# Contract A: shared Opus-budget ledger across cost-router + second-brain plugins.
#
# Isolation: all writes go to a temp dir; the real ~/.second-brain is never touched.
# The ledger path is controlled by COST_ROUTER_LEDGER env var.
#
# Usage: bash tests/test-opus-budget.sh

set -u

for cmd in jq mktemp bash awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/cost-router/scripts/opus-budget.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: script not found: $SCRIPT"
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-opus-budget.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

echo "test-opus-budget.sh"
echo "-------------------"

# Helper: run the script with a fresh isolated ledger per test
LEDGER="$TMP/opus-budget.json"

# --- (a) fresh ledger: spent is 0; 'over' exits nonzero ---
rm -f "$LEDGER"
SPENT=$(COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" spent 2>&1)
if [ "$SPENT" = "0" ] || [ "$SPENT" = "0.0" ] || [ "$SPENT" = "0.00" ]; then
  pass "(a) fresh ledger: spent reports 0"
else
  fail "(a) fresh ledger: spent should be 0, got: '$SPENT'"
fi

rm -f "$LEDGER"
COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" over 2>/dev/null
OVER_EXIT=$?
if [ "$OVER_EXIT" -ne 0 ]; then
  pass "(a) fresh ledger: 'over' exits nonzero (not over budget)"
else
  fail "(a) fresh ledger: 'over' should exit nonzero, exited $OVER_EXIT"
fi

# --- (b) after record 2.0 then record 1.5, spent is 3.5 ---
rm -f "$LEDGER"
COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" record 2.0
COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" record 1.5
SPENT=$(COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" spent 2>&1)
# Use awk to compare floats
MATCH=$(awk -v s="$SPENT" 'BEGIN { printf "%d", (s+0 >= 3.49 && s+0 <= 3.51) }')
if [ "$MATCH" = "1" ]; then
  pass "(b) after record 2.0 + 1.5, spent is 3.5 (got: $SPENT)"
else
  fail "(b) after record 2.0 + 1.5, spent should be 3.5, got: '$SPENT'"
fi

# --- (c) with cap=3.0 and spent=3.5, 'over' exits 0 ---
# Reuse ledger from (b) which has 3.5 spent
COST_ROUTER_LEDGER="$LEDGER" COST_ROUTER_OPUS_CAP_USD=3.0 bash "$SCRIPT" over 2>/dev/null
OVER_EXIT=$?
if [ "$OVER_EXIT" -eq 0 ]; then
  pass "(c) cap=3.0 spent=3.5: 'over' exits 0 (is over budget)"
else
  fail "(c) cap=3.0 spent=3.5: 'over' should exit 0, exited $OVER_EXIT"
fi

# --- (d) R5.1 CR-009: `spent` is a PURE READ — stale ledger returns 0 but the
# file is NOT rewritten (a SessionStart status banner must never mutate state;
# the reset stays lazy inside ob_record).
OLD_DATE="2000-01-01"
TODAY=$(date -u +%F)
rm -f "$LEDGER"
printf '{"date":"%s","opus_cost_usd":99.99,"opus_calls":42,"cap_usd":5.0}\n' "$OLD_DATE" > "$LEDGER"
BEFORE_HASH=$(cksum "$LEDGER")
SPENT=$(COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" spent 2>&1)
MATCH=$(awk -v s="$SPENT" 'BEGIN { printf "%d", (s+0 >= -0.01 && s+0 <= 0.01) }')
if [ "$MATCH" = "1" ]; then
  pass "(d) stale ledger (date=$OLD_DATE): spent reads as 0 (got: $SPENT)"
else
  fail "(d) stale ledger should read as 0, got: '$SPENT'"
fi

AFTER_HASH=$(cksum "$LEDGER")
if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "(d) spent did NOT rewrite the stale ledger (pure read)"
else
  fail "(d) spent mutated the ledger on the read path (write-on-read regression)"
fi

# Lazy reset still works: a record on the stale ledger starts fresh at today.
COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" record 1.25 >/dev/null 2>&1
STORED_DATE=$(jq -r '.date' "$LEDGER" 2>/dev/null || echo "MISSING")
STORED_COST=$(jq -r '.opus_cost_usd' "$LEDGER" 2>/dev/null || echo "MISSING")
if [ "$STORED_DATE" = "$TODAY" ] && awk -v c="$STORED_COST" 'BEGIN { exit !(c+0 > 1.2 && c+0 < 1.3) }'; then
  pass "(d) ob_record on stale ledger resets lazily (date=today, cost=1.25)"
else
  fail "(d) lazy reset broken: date='$STORED_DATE' cost='$STORED_COST'"
fi

echo "-------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

# --- (e) R5.1 CR-009: routing-status banner clamps over-cap (never "$-0.50") ---
STATUS="$REPO_ROOT/cost-router/scripts/routing-status.sh"
rm -f "$LEDGER"
printf '{"date":"%s","opus_cost_usd":9.50,"opus_calls":3,"cap_usd":5.0}\n' "$(date -u +%F)" > "$LEDGER"
OUT=$(COST_ROUTER_LEDGER="$LEDGER" COST_ROUTER_OPUS_CAP_USD=5.0 bash "$STATUS" )
case "$OUT" in
  *'$-'*) fail "(e) banner rendered a negative remaining: $OUT" ;;
  *'over cap'*) pass "(e) over-cap ledger renders 'over cap'" ;;
  *) fail "(e) expected 'over cap' in banner, got: $OUT" ;;
esac

echo "-------------------"
echo "FINAL PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
