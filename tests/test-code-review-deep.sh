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

# Extract the YAML frontmatter block: lines after the first '---' and before the
# next '---'. Stops at the first closing delimiter so a body-level '---' thematic
# break can't leak into the result (a sed start/end range would re-capture it).
frontmatter() { awk '/^---$/{n++; next} n==1' "$1"; }

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

# --- Skill --------------------------------------------------------------
skill="$ROOT/skills/code-review-deep/SKILL.md"
if [ ! -f "$skill" ]; then
  bad "skill file missing: skills/code-review-deep/SKILL.md"
else
  sfm="$(frontmatter "$skill")"
  for field in name description allowed-tools; do
    echo "$sfm" | grep -q "^$field:" && ok "SKILL.md has $field" \
      || bad "SKILL.md missing '$field' in frontmatter"
  done
  echo "$sfm" | grep -q "^name: *code-review-deep$" && ok "SKILL.md name: code-review-deep" \
    || bad "SKILL.md name is not 'code-review-deep'"

  # allowed-tools must grant the orchestrator what the design needs.
  at="$(echo "$sfm" | grep '^allowed-tools:')"
  for need in "Agent" "Bash(gh pr" "Bash(git diff" "knowledge_search" "episodic_search"; do
    case "$at" in
      *"$need"*) ok "allowed-tools grants $need" ;;
      *) bad "allowed-tools missing $need" ;;
    esac
  done

  # Reference integrity: every DISPATCHED subagent must resolve to an agent file.
  # Scope to subagent_type sites only — a bare "second-brain:<skill>" elsewhere
  # (e.g. the attribution footer) is a skill self-reference, not an agent.
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "$ROOT/agents/$ref.md" ]; then
      ok "subagent_type second-brain:$ref resolves to agents/$ref.md"
    else
      bad "subagent_type second-brain:$ref has no agents/$ref.md"
    fi
  done < <(grep -oE 'subagent_type: *"second-brain:[a-z-]+"' "$skill" \
             | grep -oE 'second-brain:[a-z-]+' | sed 's/^second-brain://' | sort -u)
fi

echo "------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
