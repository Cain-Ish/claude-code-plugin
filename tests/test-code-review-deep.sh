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
# Both agents must exist, be named, and carry a description.
for agent in code-review-unit-reviewer code-review-scorer; do
  f="$ROOT/agents/$agent.md"
  if [ ! -f "$f" ]; then bad "agent file missing: agents/$agent.md"; continue; fi
  fm="$(frontmatter "$f")"
  echo "$fm" | grep -q "^name: *$agent$" && ok "agents/$agent.md name: $agent" \
    || bad "agents/$agent.md missing or wrong 'name:' (want '$agent')"
  echo "$fm" | grep -q "^description:" && ok "agents/$agent.md has description" \
    || bad "agents/$agent.md missing 'description:'"
done

# Scorer must NOT pin a model — v2.1 un-pins it so it inherits the session/best
# model, matching the reviewer it gates (removes the capability inversion).
scorer_fm="$(frontmatter "$ROOT/agents/code-review-scorer.md")"
scorer_keys="$(printf '%s\n' "$scorer_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
if printf '%s\n' "$scorer_keys" | grep -qi '^model:'; then
  bad "code-review-scorer must NOT pin 'model:' (v2.1: inherits to match the reviewer)"
else
  ok "code-review-scorer inherits model (no model: pin)"
fi

# Unit-reviewer must NOT pin a model — it inherits the session/best model so
# code units get the strongest model (v2 directive).
ur_fm="$(frontmatter "$ROOT/agents/code-review-unit-reviewer.md")"
# Check only TOP-LEVEL frontmatter keys (column-0 `key:` lines), not the indented
# `description: |` block body — otherwise a description/example line beginning
# "model:" would false-FAIL this guard.
ur_keys="$(printf '%s\n' "$ur_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
if printf '%s\n' "$ur_keys" | grep -qi '^model:'; then
  bad "code-review-unit-reviewer must NOT pin 'model:' (it inherits the best model)"
else
  ok "code-review-unit-reviewer inherits model (no model: pin)"
fi

# Lean returns: bounds the orchestrator's retained context (leak mitigation).
grep -qi "never paste file contents" "$ROOT/agents/code-review-unit-reviewer.md" \
  && ok "unit-reviewer has lean-return instruction" \
  || bad "unit-reviewer missing lean-return (findings-only) instruction"

# v2.1: unit-reviewer reasons harder (effort: high). Task 0 confirmed dispatched
# agents honor effort:. ur_fm is the frontmatter extracted above.
ur_effort_keys="$(printf '%s\n' "$ur_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
printf '%s\n' "$ur_effort_keys" | grep -qi '^effort:' \
  && ok "unit-reviewer sets effort (deeper reasoning)" \
  || bad "unit-reviewer missing 'effort: high'"

# --- Skill --------------------------------------------------------------
skill="$ROOT/skills/code-review-deep/SKILL.md"
if [ ! -f "$skill" ]; then
  bad "skill file missing: skills/code-review-deep/SKILL.md"
else
  sfm="$(frontmatter "$skill")"

  # Orchestration body lives in the skill (inline) or in the forked orchestrator
  # agent (if context: fork is ever supported). Body-level assertions run on ORCH.
  if echo "$sfm" | grep -q "^context: *fork"; then
    ORCH="$ROOT/agents/deep-code-reviewer.md"
  else
    ORCH="$skill"
  fi

  # Fork orchestration is unavailable today (anthropics/claude-code#17283): the
  # skill runs inline. This guard stays correct either way — if #17283 lands and
  # someone forks, it enforces the orchestrator agent exists with effort: high.
  if echo "$sfm" | grep -q "^context: *fork"; then
    if [ -f "$ROOT/agents/deep-code-reviewer.md" ]; then
      ok "context:fork present and deep-code-reviewer agent exists"
      dfm="$(frontmatter "$ROOT/agents/deep-code-reviewer.md")"
      echo "$dfm" | grep -qi "^effort: *high" \
        && ok "deep-code-reviewer effort: high" \
        || bad "deep-code-reviewer must set 'effort: high'"
      echo "$dfm" | grep -qi "^model: *sonnet" \
        && ok "deep-code-reviewer model: sonnet" \
        || bad "deep-code-reviewer must set 'model: sonnet'"
    else
      bad "skill declares context:fork but agents/deep-code-reviewer.md is missing"
    fi
  else
    ok "inline orchestration (no context:fork) — deep-code-reviewer not required"
  fi

  # v2: docs-vs-code routing. Pass 1 tags docs units; Pass 2 routes docs to Haiku
  # and leaves code units on the inherited (best) model.
  grep -q "docs_only" "$ORCH" && ok "orchestrator tags docs_only units" \
    || bad "orchestrator missing docs_only routing"
  grep -qiE 'model: *"?haiku' "$ORCH" \
    && ok "orchestrator downgrades docs units to Haiku" \
    || bad "orchestrator missing Haiku override for docs units"

  # docs_only must NOT classify the plugin's own prompt/product trees as docs
  # (a SKILL.md / agent .md is code-as-prompt — must get the best model, not Haiku).
  grep -qE 'skills/\*\*|agents/\*\*|tests/\*\*' "$ORCH" \
    && ok "docs_only excludes prompt/product trees (skills/agents/tests)" \
    || bad "docs_only rule must exclude skills/**, agents/**, tests/** from docs"

  # Wave cap (leak mitigation): bounded parallelism, not all-at-once.
  grep -qi "at most 5" "$ORCH" && ok "orchestrator caps parallel dispatch at 5" \
    || bad "orchestrator missing wave cap (at most 5 concurrent)"

  for field in name description allowed-tools; do
    echo "$sfm" | grep -q "^$field:" && ok "SKILL.md has $field" \
      || bad "SKILL.md missing '$field' in frontmatter"
  done
  echo "$sfm" | grep -q "^name: *code-review-deep$" && ok "SKILL.md name: code-review-deep" \
    || bad "SKILL.md name is not 'code-review-deep'"

  # allowed-tools must grant the orchestrator what the design needs.
  at="$(echo "$sfm" | grep '^allowed-tools:')"
  for need in "Agent" "Bash(gh pr" "Bash(gh repo" "Bash(git diff" "Bash(git remote" "knowledge_search" "episodic_search"; do
    case "$at" in
      *"$need"*) ok "allowed-tools grants $need" ;;
      *) bad "allowed-tools missing $need" ;;
    esac
  done

  # Reference integrity: every DISPATCHED subagent must resolve to an agent file.
  # Scope to subagent_type sites only — a bare "second-brain:<skill>" elsewhere
  # (e.g. the attribution footer) is a skill self-reference, not an agent.
  # Charset allows digits/uppercase so a misnamed dispatch can't slip the regex
  # and silently escape the resolve check.
  dispatched="$(grep -oE 'subagent_type: *"second-brain:[A-Za-z0-9-]+"' "$ORCH" \
                  | grep -oE 'second-brain:[A-Za-z0-9-]+' | sed 's/^second-brain://' | sort -u)"
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "$ROOT/agents/$ref.md" ]; then
      ok "subagent_type second-brain:$ref resolves to agents/$ref.md"
    else
      bad "subagent_type second-brain:$ref has no agents/$ref.md"
    fi
  done <<< "$dispatched"

  # Positive wiring assertion: the skill MUST dispatch both workers. Without
  # this, a skill regressed to dispatch nothing passes the resolve loop above
  # vacuously (the loop body never runs), defeating the whole point of a
  # "wiring" test.
  for want in code-review-unit-reviewer code-review-scorer quality-reviewer; do
    printf '%s\n' "$dispatched" | grep -qx "$want" \
      && ok "orchestrator dispatches $want" \
      || bad "orchestrator does not dispatch expected agent: $want"
  done

  # Architectural notes must be advisory only — never scored or FP-recorded.
  grep -qi "never scored or recorded as false positives" "$ORCH" \
    && ok "arch notes excluded from scoring + FP write-back" \
    || bad "orchestrator missing 'arch notes are advisory' exclusion"

  # v2.1: the 16–69 band is surfaced, not dropped — the orchestrator must render a
  # distinct lower-confidence section.
  grep -qi "Lower-confidence findings" "$ORCH" \
    && ok "orchestrator surfaces the lower-confidence (16–69) band" \
    || bad "orchestrator missing the 'Lower-confidence findings' section"

  # v2.1: the FP auto-record ratchet is removed — the store grows ONLY from user
  # dismissals. The write-back heading carries that contract sentinel.
  grep -qi "user dismissals only" "$ORCH" \
    && ok "FP write-back is user-dismissals-only (no auto-record ratchet)" \
    || bad "orchestrator must record FPs from user dismissals only (v2.1)"

  # No emojis in the orchestrator (the deep reference bans them; v1 had a robot).
  if grep -q "🤖" "$ORCH"; then
    bad "orchestrator contains an emoji (robot) — deep review posts no emojis"
  else
    ok "orchestrator has no emoji"
  fi

  # Description must reflect best-model review, not the stale 'parallel Haiku agent'.
  if echo "$sfm" | grep -qi "parallel Haiku agent"; then
    bad "skill description still says 'parallel Haiku agent' (stale)"
  else
    ok "skill description not stale"
  fi
  echo "$sfm" | grep -qi "best available model" && ok "skill description mentions best model" \
    || bad "skill description should mention best-model code review"

  # Pass 0/1 must explicitly delegate mechanical work to the Haiku model.
  grep -qi "haiku model" "$ORCH" && ok "orchestrator delegates mechanical work to the Haiku model" \
    || bad "orchestrator missing explicit Haiku-model delegation"

  # Skipped-count wording consistent in both output branches.
  grep -q "skipped as trivial). No issues found" "$ORCH" \
    && ok "no-issues line uses 'skipped as trivial'" \
    || bad "no-issues output line missing 'skipped as trivial'"
fi

echo "------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
