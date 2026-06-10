#!/bin/bash
# cost-router SessionStart hook — prints a one-line routing-status banner
# showing active model tiers and remaining Opus budget for the day.
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

# Budget line (shown only when opus-budget.sh is available)
if [ -f "$BUDGET_SH" ]; then
  SPENT=$(bash "$BUDGET_SH" spent 2>/dev/null || echo "?")
  CAP="${COST_ROUTER_OPUS_CAP_USD:-5.0}"
  # Compute remaining using awk (portable float arithmetic)
  if [ "$SPENT" != "?" ]; then
    # Clamp at 0 (R5.1, CR-009): "$-0.50 remaining" is nonsense — over cap is a state.
    REMAINING=$(awk -v spent="$SPENT" -v cap="$CAP" 'BEGIN { r = cap - spent; if (r < 0) r = -1; printf "%.2f", r }')
    if [ "$REMAINING" = "-1.00" ]; then
      BUDGET_LINE="Opus budget: \$${SPENT} used / \$${CAP} cap (over cap)"
    else
      BUDGET_LINE="Opus budget: \$${SPENT} used / \$${CAP} cap (\$${REMAINING} remaining today)"
    fi
  else
    BUDGET_LINE="Opus budget: unavailable"
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
