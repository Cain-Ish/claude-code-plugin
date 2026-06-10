#!/bin/bash
# Structural validator for the cost-router plugin.
# Does NOT require the full claude CLI — structural checks use jq/grep only.
# If the claude CLI is available, also runs: claude plugin validate ./cost-router
#
# Checks:
#   1. cost-router/.claude-plugin/plugin.json is valid JSON with name+version
#   2. cr-planner agent has model: opus
#   3. cr-implementer agent has model: sonnet
#   4. cr-scout agent has model: haiku
#   5. cost-router/skills/orchestrate/SKILL.md exists
#   6. (optional) claude plugin validate passes
#
# Usage: bash tests/test-cost-router-validate.sh
set -u

for cmd in jq bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "test prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/cost-router"

PASS=0
FAIL=0

pass(){ PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail(){ FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

echo "test-cost-router-validate.sh"
echo "----------------------------"

# 1. plugin.json is valid JSON with name and version
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
  fail "plugin.json exists at cost-router/.claude-plugin/plugin.json" "file not found: $PLUGIN_JSON"
else
  name=$(jq -r '.name // empty' "$PLUGIN_JSON" 2>/dev/null)
  version=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)
  if [ -n "$name" ] && [ -n "$version" ]; then
    pass "plugin.json valid JSON with name=$name version=$version"
  else
    fail "plugin.json has name+version fields" "name='$name' version='$version'"
  fi
fi

# 2. cr-planner has model: opus
PLANNER="$PLUGIN_DIR/agents/cr-planner.md"
if [ -f "$PLANNER" ] && grep -q 'model:[[:space:]]*opus' "$PLANNER"; then
  pass "cr-planner.md has model: opus"
else
  fail "cr-planner.md has model: opus" "${PLANNER}"
fi

# 3. cr-implementer has model: sonnet
IMPLEMENTER="$PLUGIN_DIR/agents/cr-implementer.md"
if [ -f "$IMPLEMENTER" ] && grep -q 'model:[[:space:]]*sonnet' "$IMPLEMENTER"; then
  pass "cr-implementer.md has model: sonnet"
else
  fail "cr-implementer.md has model: sonnet" "${IMPLEMENTER}"
fi

# 4. cr-scout has model: haiku
SCOUT="$PLUGIN_DIR/agents/cr-scout.md"
if [ -f "$SCOUT" ] && grep -q 'model:[[:space:]]*haiku' "$SCOUT"; then
  pass "cr-scout.md has model: haiku"
else
  fail "cr-scout.md has model: haiku" "${SCOUT}"
fi

# 5. orchestrate skill SKILL.md exists
SKILL_MD="$PLUGIN_DIR/skills/orchestrate/SKILL.md"
if [ -f "$SKILL_MD" ]; then
  pass "skills/orchestrate/SKILL.md exists"
else
  fail "skills/orchestrate/SKILL.md exists" "not found: $SKILL_MD"
fi

# 6. Optional: claude CLI validate
if command -v claude >/dev/null 2>&1; then
  echo "  INFO  claude CLI found — running: claude plugin validate ./cost-router"
  out=$(cd "$REPO_ROOT" && claude plugin validate ./cost-router 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "claude plugin validate ./cost-router"
  else
    fail "claude plugin validate ./cost-router" "$out"
  fi
else
  echo "  SKIP  claude CLI not available — skipping plugin validate (structural checks above still run)"
fi

echo "----------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

# --- R5.1 (CR-011): setup skill must not pre-allow arbitrary rm ---
if grep -q 'Bash(rm' "$REPO_ROOT/cost-router/skills/setup/SKILL.md"; then
  fail "setup skill pre-allows Bash(rm ...) — unused destructive grant"
else
  pass "setup skill carries no rm grant"
fi

echo "-------------------"
echo "FINAL PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
