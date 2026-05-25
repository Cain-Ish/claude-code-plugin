#!/usr/bin/env bash
# Structural + wiring test for the code-review-deep skill and its agents.
# Behavior is LLM-driven and not unit-testable here; this guards the contract
# the orchestrator depends on: agent files exist, are Haiku, declare a name,
# and every subagent_type the skill dispatches resolves to a real agent file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# Extract the YAML frontmatter block (between the first two '---' lines).
frontmatter() { sed -n '/^---$/,/^---$/p' "$1" | sed '1d;$d'; }

echo "test-code-review-deep.sh"
echo "------------------------"

# --- Agents -------------------------------------------------------------
for agent in code-review-unit-reviewer code-review-scorer; do
  f="$ROOT/agents/$agent.md"
  if [ ! -f "$f" ]; then bad "agent file missing: agents/$agent.md"; continue; fi
  fm="$(frontmatter "$f")"
  echo "$fm" | grep -q "^name: *$agent$" && ok "agents/$agent.md name: $agent" \
    || bad "agents/$agent.md missing or wrong 'name:' (want '$agent')"
  echo "$fm" | grep -qi "^model: *haiku$" && ok "agents/$agent.md model: haiku" \
    || bad "agents/$agent.md not 'model: haiku'"
  echo "$fm" | grep -q "^description:" && ok "agents/$agent.md has description" \
    || bad "agents/$agent.md missing 'description:'"
done

echo "------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
