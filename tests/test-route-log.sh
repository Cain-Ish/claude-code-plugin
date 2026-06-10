#!/bin/bash
# Tests for cost-router/scripts/route-log.sh
# Contract B: routing events log — appends JSONL events.
#
# Isolation: all writes go to a temp dir via COST_ROUTER_EVENTS override.
# The real ~/.second-brain is never touched.
#
# Usage: bash tests/test-route-log.sh

set -u

for cmd in jq mktemp bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/cost-router/scripts/route-log.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: script not found: $SCRIPT"
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-route-log.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

echo "test-route-log.sh"
echo "-----------------"

EVENTS="$TMP/cost-router-events.jsonl"

# --- (a) after one rl_emit, events file has exactly 1 line and it is valid JSON ---
rm -f "$EVENTS"
COST_ROUTER_EVENTS="$EVENTS" bash "$SCRIPT" emit "review-pr" "DO" "sonnet" "10" "false" "approved" "true"

if [ ! -f "$EVENTS" ]; then
  fail "(a) events file not created after rl_emit"
else
  LINE_COUNT=$(wc -l < "$EVENTS" | tr -d ' ')
  if [ "$LINE_COUNT" = "1" ]; then
    pass "(a) events file has exactly 1 line after one emit"
  else
    fail "(a) events file should have 1 line, got: $LINE_COUNT"
  fi

  LINE=$(head -1 "$EVENTS")
  if echo "$LINE" | jq -e . >/dev/null 2>&1; then
    pass "(a) line 1 is valid JSON"
  else
    fail "(a) line 1 is not valid JSON: $LINE"
  fi

  # Check required fields (use has() so boolean false / 0 still counts as present)
  for field in ts task tier models units escalated outcome committed; do
    HAS=$(echo "$LINE" | jq --arg f "$field" 'has($f)' 2>/dev/null)
    if [ "$HAS" = "true" ]; then
      pass "(a) field '$field' present"
    else
      fail "(a) field '$field' missing in: $LINE"
    fi
  done

  # Check specific values
  TASK=$(echo "$LINE" | jq -r '.task')
  [ "$TASK" = "review-pr" ] && pass "(a) .task = 'review-pr'" || fail "(a) .task should be 'review-pr', got: '$TASK'"

  TIER=$(echo "$LINE" | jq -r '.tier')
  [ "$TIER" = "DO" ] && pass "(a) .tier = 'DO'" || fail "(a) .tier should be 'DO', got: '$TIER'"

  UNITS=$(echo "$LINE" | jq -r '.units')
  [ "$UNITS" = "10" ] && pass "(a) .units = 10" || fail "(a) .units should be 10, got: '$UNITS'"

  COMMITTED=$(echo "$LINE" | jq -r '.committed')
  [ "$COMMITTED" = "true" ] && pass "(a) .committed = true" || fail "(a) .committed should be true, got: '$COMMITTED'"
fi

# --- (b) models CSV is split into a JSON array ---
rm -f "$EVENTS"
COST_ROUTER_EVENTS="$EVENTS" bash "$SCRIPT" emit "search" "SCOUT" "sonnet,haiku" "5" "false" "ok" "false"

if [ -f "$EVENTS" ]; then
  LINE=$(head -1 "$EVENTS")
  MODELS_TYPE=$(echo "$LINE" | jq -r '.models | type')
  if [ "$MODELS_TYPE" = "array" ]; then
    pass "(b) .models is a JSON array"
  else
    fail "(b) .models should be array, got type: '$MODELS_TYPE'"
  fi

  MODELS_LEN=$(echo "$LINE" | jq '.models | length')
  if [ "$MODELS_LEN" = "2" ]; then
    pass "(b) .models has 2 elements for 'sonnet,haiku'"
  else
    fail "(b) .models should have 2 elements, got: $MODELS_LEN"
  fi

  M0=$(echo "$LINE" | jq -r '.models[0]')
  M1=$(echo "$LINE" | jq -r '.models[1]')
  if [ "$M0" = "sonnet" ] && [ "$M1" = "haiku" ]; then
    pass "(b) .models = [\"sonnet\",\"haiku\"]"
  else
    fail "(b) .models should be [sonnet,haiku], got: [$M0,$M1]"
  fi
else
  fail "(b) events file not created"
fi

# --- (c) second rl_emit appends a second line (total 2 lines) ---
COST_ROUTER_EVENTS="$EVENTS" bash "$SCRIPT" emit "write-code" "THINK" "opus" "20" "true" "done" "true"

if [ -f "$EVENTS" ]; then
  LINE_COUNT=$(wc -l < "$EVENTS" | tr -d ' ')
  if [ "$LINE_COUNT" = "2" ]; then
    pass "(c) second emit makes 2 lines total"
  else
    fail "(c) after second emit should have 2 lines, got: $LINE_COUNT"
  fi

  # Both lines must be valid JSON
  INVALID=0
  while IFS= read -r line; do
    echo "$line" | jq -e . >/dev/null 2>&1 || INVALID=$((INVALID + 1))
  done < "$EVENTS"
  if [ "$INVALID" -eq 0 ]; then
    pass "(c) both lines are valid JSON"
  else
    fail "(c) $INVALID line(s) are not valid JSON"
  fi
else
  fail "(c) events file missing"
fi

echo "-----------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

# --- (d) R5.1 CR-002: EMPTY models CSV must still log (models: []) ---
# Pre-fix, `printf '' | jq -Rc 'split(",")'` exits 0 with NO output, the ||
# fallback never fires, --argjson gets "" and the whole emit is dropped —
# which silently killed 100% of classifier events.
rm -f "$EVENTS"
COST_ROUTER_EVENTS="$EVENTS" bash "$SCRIPT" emit "empty_models" "DO" "" 0 false classified false
if [ -f "$EVENTS" ] && jq -e 'select(.task=="empty_models") | .models == []' "$EVENTS" >/dev/null 2>&1; then
  pass "(d) empty models CSV logs with models: []"
else
  fail "(d) empty models CSV event was dropped (or models != [])"
fi

echo "-----------------"
echo "FINAL PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
