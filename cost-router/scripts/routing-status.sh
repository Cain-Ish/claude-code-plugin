#!/bin/bash
# cost-router SessionStart hook — prints a one-line routing-status banner
# showing active model tiers and today's PREMIUM-model spend (informational —
# no cap since 0.24.45; premium = any model above the DO/SCOUT tiers, Opus
# today, Fable/future top tiers tomorrow).
#
# Suppressible: COST_ROUTER_BANNER=off
# Output kept well under the 10K hook ceiling (< 200 bytes typical).
#
# Bash 3.2 / BSD-safe (no date -d, no GNU-only extensions).

set -u
# Nested-spawn circuit breaker (R1.1/R5.1): inside a plugin-spawned headless session, context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

# Kill switch
[ "${COST_ROUTER_BANNER:-on}" = "off" ] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUDGET_SH="$PLUGIN_ROOT/scripts/opus-budget.sh"

# Tier summary (always shown)
TIER_LINE="cost-router active: THINK=Opus | DO=Sonnet | SCOUT=Haiku"

# Spend line — shown ONLY when premium spend has actually been recorded today.
# cost-router itself never debits the ledger (the sole writer is second-brain's
# persona-think), so standalone the line would be a permanent, misleading
# "$0.00". Gating on spent>0 keeps the banner honest in both modes: an
# integrated session surfaces the day's premium cost once an Opus dispatch is
# recorded; a cost-router-only install shows just the tier line. Informational —
# no cap, no "remaining": the ledger reports, it never blocks.
BUDGET_LINE=""
if [ -f "$BUDGET_SH" ]; then
  SPENT=$(bash "$BUDGET_SH" spent 2>/dev/null || echo 0)
  if awk -v s="$SPENT" 'BEGIN { exit !(s + 0 > 0) }'; then
    SPENT_FMT=$(awk -v s="$SPENT" 'BEGIN { printf "%.2f", s + 0 }')
    BUDGET_LINE="premium-model spend today: \$${SPENT_FMT} (informational)"
  fi
fi

# Emit as a single systemMessage line (< 200 bytes)
if [ -n "$BUDGET_LINE" ]; then
  printf '%s — %s\n' "$TIER_LINE" "$BUDGET_LINE"
else
  printf '%s\n' "$TIER_LINE"
fi

exit 0
