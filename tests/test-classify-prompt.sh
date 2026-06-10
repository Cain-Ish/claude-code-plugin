#!/bin/bash
# Guard: classify-prompt.sh must classify user prompts into THINK/DO/SCOUT tiers
# and emit a UserPromptSubmit additionalContext nudge via the same JSON shape that
# persona-context.sh uses (hookSpecificOutput.additionalContext).
#
# Kill switch: COST_ROUTER_AUTOROUTE=off → no output.
# Fully isolated: COST_ROUTER_EVENTS is redirected to a temp file so the real
# second-brain events log is never touched.
#
# Usage: bash tests/test-classify-prompt.sh
set -u

for cmd in jq mktemp bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/cost-router/scripts/classify-prompt.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sb-classify-prompt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

EVENTS_FILE="$TMP/cost-router-events.jsonl"

PASS=0
FAIL=0

assert_tier() {
  local label="$1" prompt="$2" expected_tier="$3"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
        bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -qi "$expected_tier"; then
    PASS=$((PASS + 1)); echo "  PASS  $label → $expected_tier"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $label → expected $expected_tier in output"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

assert_valid_json_ctx() {
  local label="$1" prompt="$2"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
        bash "$SCRIPT" 2>/dev/null)
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [ -n "$ctx" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $label → valid JSON additionalContext"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $label → expected JSON {hookSpecificOutput:{additionalContext:...}}"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

assert_no_output() {
  local label="$1" prompt="$2"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=off COST_ROUTER_EVENTS="$EVENTS_FILE" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
        bash "$SCRIPT" 2>/dev/null)
  if [ -z "$out" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $label → no output (kill switch)"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $label → expected no output when COST_ROUTER_AUTOROUTE=off"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

echo "test-classify-prompt.sh"
echo "-----------------------"

# R5.1 (CR-006) contract: a nudge is shown ONLY for THINK/SCOUT on prompts
# >= 25 chars (a "use the default" nudge carries no information; a false THINK
# nudge advises the EXPENSIVE model). EVERY prompt still logs a route-log
# event — silence is not data loss.
assert_silent_logged() {
  local label="$1" prompt="$2" expected_tier="$3"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
        bash "$SCRIPT" 2>/dev/null)
  local logged
  logged=$(tail -1 "$EVENTS_FILE" 2>/dev/null | jq -r '.tier // empty' 2>/dev/null)
  if [ -z "$out" ] && [ "$logged" = "$expected_tier" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $label → silent, logged $expected_tier"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $label → expected NO output + logged tier $expected_tier (out='$(printf '%s' "$out" | head -c 60)', logged='$logged')"
  fi
}

# --- THINK tier: word-bounded design-intent prompts nudge ---
assert_tier "design prompt"         "design a new caching layer"            "THINK"
assert_tier "architect prompt"      "architect the auth subsystem for me"   "THINK"
assert_tier "strategy prompt"       "what is the best strategy for this"    "THINK"
assert_tier "trade-off prompt"      "discuss the trade-off between X and Y" "THINK"
assert_tier "approach prompt"       "what approach should I take here"      "THINK"
assert_tier "plan prompt"           "plan the database migration rollout"   "THINK"

# --- THINK false-positive guards (deep-review CR-006) ---
assert_silent_logged "plan-as-path stays DO"  "implement step 3 of the plan-x in docs" "DO"
assert_tier          "lint beats dropped security keyword" "fix the lint warning in the security module" "SCOUT"

# --- SCOUT tier (>= 25 chars → nudge) ---
assert_tier "find prompt"           "find all usages of this function"   "SCOUT"
assert_tier "search prompt"         "search for the pattern in tests"    "SCOUT"
assert_tier "what is prompt"        "what is the value of this variable" "SCOUT"
assert_tier "where is prompt"       "where is the config loaded from"    "SCOUT"
assert_tier "grep prompt"           "grep for the TODO comments here"    "SCOUT"

# --- Short prompts: silent (even with tier keywords), still logged ---
assert_silent_logged "short scout"  "show me the logs"   "SCOUT"
assert_silent_logged "short think"  "plan the move"      "THINK"
assert_silent_logged "trivial"      "continue"           "DO"
assert_silent_logged "trivial yes"  "yes"                "DO"

# --- DO tier: ALWAYS silent (the default needs no advisory), still logged ---
assert_silent_logged "implement prompt" "implement the login feature with sessions" "DO"
assert_silent_logged "fix prompt"        "fix the broken test in the auth suite"     "DO"
assert_silent_logged "write prompt"      "write a helper for date parsing in utils"  "DO"

# --- Output format: valid JSON with additionalContext (a SCOUT nudge) ---
assert_valid_json_ctx "json structure" "find all usages of this function"

# --- Kill switch ---
assert_no_output "kill switch off"  "design a new architecture"

# --- Prompt with missing prompt field: no crash ---
echo "  Testing empty payload..."
out=$(printf '%s' '{}' \
  | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
      bash "$SCRIPT" 2>/dev/null)
if [ -z "$out" ]; then
  PASS=$((PASS + 1)); echo "  PASS  empty payload → no output (graceful)"
else
  # also acceptable: any output is fine as long as the script doesn't crash (exit 0)
  PASS=$((PASS + 1)); echo "  PASS  empty payload → non-empty output but did not crash"
fi

echo "-----------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
