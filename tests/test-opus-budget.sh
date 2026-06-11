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
OVER_OUT=$(COST_ROUTER_LEDGER="$LEDGER" bash "$SCRIPT" over 2>&1)
OVER_EXIT=$?
if [ "$OVER_EXIT" -ne 0 ] && echo "$OVER_OUT" | grep -qi 'removed'; then
  pass "(a) 'over' subcommand is GONE (cap removed) — usage error names the removal"
else
  fail "(a) 'over' should be a usage error naming the removal (exit=$OVER_EXIT out=$OVER_OUT)"
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

# --- (c) NO CAP (0.24.45): a recorded ledger has no cap_usd key, and the old
# COST_ROUTER_OPUS_CAP_USD env is inert — the ledger is informational only.
if jq -e 'has("cap_usd") | not' "$LEDGER" >/dev/null 2>&1; then
  pass "(c) recorded ledger carries no cap_usd (informational ledger)"
else
  fail "(c) recorded ledger still writes cap_usd: $(cat "$LEDGER")"
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

# --- (e) 0.24.45 de-cap: banner reports premium spend informationally — no cap
# arithmetic, no "over cap", no negative remaining. Models above the DO/SCOUT
# tiers change over time (Opus today, Fable tomorrow), so the ledger informs
# rather than enforces.
STATUS="$REPO_ROOT/cost-router/scripts/routing-status.sh"
rm -f "$LEDGER"
printf '{"date":"%s","opus_cost_usd":9.50,"opus_calls":3}\n' "$(date -u +%F)" > "$LEDGER"
OUT=$(COST_ROUTER_LEDGER="$LEDGER" bash "$STATUS" )
case "$OUT" in
  *'$-'*) fail "(e) banner rendered a negative remaining: $OUT" ;;
  *cap*) fail "(e) banner still speaks of a cap: $OUT" ;;
  *'premium-model spend'*'9.50'*) pass "(e) banner reports premium spend informationally" ;;
  *) fail "(e) expected 'premium-model spend ... 9.50' in banner, got: $OUT" ;;
esac

echo "-------------------"
echo "FINAL PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
