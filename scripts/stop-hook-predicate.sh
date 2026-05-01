#!/bin/bash
# Stop-hook predicate: returns exit 0 if PROJECT.md should be written, 1 if no-op.
set -u
BASELINE="${1:-}"
CURRENT="${2:-}"
[ -f "$BASELINE" ] || { echo "no baseline: $BASELINE" >&2; exit 1; }
[ -f "$CURRENT" ]  || { echo "no current: $CURRENT" >&2; exit 1; }

section() {
  local file="$1" name="$2"
  awk -v sect="^## $name\$" '
    $0 ~ sect { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$file"
}

# 1: Goal text differs
goal_b=$(section "$BASELINE" "Goal" | tr -d '[:space:]')
goal_c=$(section "$CURRENT"  "Goal" | tr -d '[:space:]')
if [ "$goal_b" != "$goal_c" ]; then echo "predicate: goal-changed" >&2; exit 0; fi

# 2: State word-count delta >20%
state_b=$(section "$BASELINE" "State" | wc -w | tr -d ' ')
state_c=$(section "$CURRENT"  "State" | wc -w | tr -d ' ')
state_b=${state_b:-0}; state_c=${state_c:-0}
if [ "$state_b" -gt 0 ]; then
  delta=$(( (state_c - state_b) * 100 / state_b )); delta=${delta#-}
  if [ "$delta" -gt 20 ]; then echo "predicate: state-delta-${delta}pct" >&2; exit 0; fi
elif [ "$state_c" -gt 0 ]; then
  echo "predicate: state-from-empty" >&2; exit 0
fi

# 3: Open blockers line count differs
ob_b=$(section "$BASELINE" "Open blockers" | grep -c '^- ' || true)
ob_c=$(section "$CURRENT"  "Open blockers" | grep -c '^- ' || true)
if [ "$ob_b" != "$ob_c" ]; then echo "predicate: blocker-count-changed ($ob_b->$ob_c)" >&2; exit 0; fi

# 4: [decision] marker added
b_dec=$(grep -c '\[decision\]' "$BASELINE" || true)
c_dec=$(grep -c '\[decision\]' "$CURRENT" || true)
if [ "$c_dec" -gt "$b_dec" ]; then echo "predicate: decision-added" >&2; exit 0; fi

exit 1
