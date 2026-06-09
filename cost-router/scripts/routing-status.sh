#!/bin/bash
# cost-router SessionStart hook — prints a one-line routing-status banner
# showing active model tiers and remaining Opus budget for the day.
#
# Suppressible: COST_ROUTER_BANNER=off
# Output kept well under the 10K hook ceiling (< 200 bytes typical).
#
# Bash 3.2 / BSD-safe (no date -d, no GNU-only extensions).

set -u

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
    REMAINING=$(awk -v spent="$SPENT" -v cap="$CAP" 'BEGIN { r = cap - spent; printf "%.2f", r }')
    BUDGET_LINE="Opus budget: \$${SPENT} used / \$${CAP} cap (\$${REMAINING} remaining today)"
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
