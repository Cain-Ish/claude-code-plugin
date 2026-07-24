#!/bin/bash
# cost-router SessionStart hook — prints a one-line routing-status banner
# showing the active model tiers.
#
# Suppressible: COST_ROUTER_BANNER=off
# Output kept well under the 10K hook ceiling (< 200 bytes typical).
#
# Bash 3.2 / BSD-safe (no date -d, no GNU-only extensions).

set -u
# Nested-spawn circuit breaker: inside a plugin-spawned headless session, context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

# Kill switch
[ "${COST_ROUTER_BANNER:-on}" = "off" ] && exit 0

# Emit as a single systemMessage line (< 200 bytes)
printf 'cost-router active: THINK=Opus | DO=Sonnet | SCOUT=Haiku\n'

exit 0
