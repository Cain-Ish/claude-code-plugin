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

# Spend line (shown only when opus-budget.sh is available). Informational —
# no cap arithmetic, no "remaining": the ledger reports, it never blocks.
# Premium = any model above the DO/SCOUT tiers (Opus today, Fable/future next).
if [ -f "$BUDGET_SH" ]; then
  SPENT=$(bash "$BUDGET_SH" spent  || echo "?")
  if [ "$SPENT" != "?" ]; then
    SPENT_FMT=$(awk -v s="$SPENT" 'BEGIN { printf "%.2f", s + 0 }')
    BUDGET_LINE="premium-model spend today: \$${SPENT_FMT} (informational)"
  else
    BUDGET_LINE="premium-model spend today: unavailable"
  fi
else
  BUDGET_LINE=""
fi

# Emit as a single systemMessage line (< 200 bytes)
if [ -n "$BUDGET_LINE" ]; then
  printf '%s — %s\n' "$TIER_LINE" "$BUDGET_LINE"
else
  printf '%s\n' "$TIER_LINE"
fi

exit 0
