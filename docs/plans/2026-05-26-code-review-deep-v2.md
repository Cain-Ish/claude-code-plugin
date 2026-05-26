# code-review-deep v2 Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Make `code-review-deep` review code on the best available model and docs on Haiku, add an advisory architectural pass, mitigate the ghost-agent RAM buildup, restore the reference skill's forked orchestration, and fix the port-fidelity bugs found in the audit.

**Architecture:** A prompt/skill change, not application code. The orchestrator is either the `code-review-deep` SKILL.md (inline) or — if the installed Claude Code supports it — a forked `deep-code-reviewer` agent the skill delegates to via `context: fork`. Per-unit reviewing reuses `code-review-unit-reviewer` (model chosen at dispatch); architecture reuses `quality-reviewer`; scoring reuses `code-review-scorer` (Haiku). Behavior is LLM-driven, so the test suite guards the *structural contract* (`tests/test-code-review-deep.sh`), not the review output.

**Tech Stack:** Markdown + YAML frontmatter (Claude Code skills/agents); Bash structural tests run by `tests/run-all.sh` / `make test`; `scripts/validate-plugin.sh` for plugin validity.

**Spec:** `docs/specs/2026-05-26-code-review-deep-v2-design.md`

**Branch:** `code-review-deep-v2` (spec already committed there).

---

## Verification Outcomes (filled in by Task 0 — gates Tasks 1 & 5)

- `MODEL_OVERRIDE` (per-call `model` on Agent/Task dispatch overrides frontmatter & inherits when omitted): **TBD by Task 0**
- `FORK` (skill `context: fork` + `agent:` entrypoint supported): **TBD by Task 0**

> If `MODEL_OVERRIDE = no`: use the two-agent-file fallback noted in Task 1, Step 3b.
> If `FORK = no`: skip Task 5 entirely; the inline skill from Tasks 1–4 is the shipped form.

---

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `agents/code-review-unit-reviewer.md` | Per-unit bug reviewer. v2: no model pin (inherits best model); lean returns | 1 |
| `agents/code-review-scorer.md` | Confidence scorer (Haiku). **Unchanged** | — |
| `agents/quality-reviewer.md` | Architectural critic (Sonnet). **Reused as-is**, invoked by Pass 2b | 3 |
| `skills/code-review-deep/SKILL.md` | Orchestration prose (inline) OR thin `context: fork` entrypoint | 2,3,4,5 |
| `agents/deep-code-reviewer.md` | **NEW, fork path only**: forked orchestrator holding the passes | 5 |
| `tests/test-code-review-deep.sh` | Structural/wiring guard | 1,2,3,4,5 |
| `.claude-plugin/plugin.json` | Version → 0.15.0 | 6 |
| `skills/upgrade/SKILL.md` | Migration row for 0.15.0 | 6 |
| `README.md` | Catalog line (line ~89) | 6 |

---

## Task 0: Verify the two capability assumptions

**Files:** none (decision spike). Record the result in this plan's "Verification Outcomes" section.

- [ ] **Step 1: Confirm per-call model override**

Dispatch the `claude-code-guide` agent with this question:

> In the current Claude Code release, when a skill's orchestrator calls the Task/Agent tool with a `model` parameter, does that override the sub-agent's frontmatter `model:`? And if `model` is omitted on the call, does the sub-agent inherit the parent/session model? Cite the docs.

- [ ] **Step 2: Confirm `context: fork` skill delegation**

Dispatch the `claude-code-guide` agent with:

> Can a Claude Code skill (SKILL.md) use `context: fork` plus an `agent:` frontmatter key to run its body inside a forked sub-agent context? Is that supported for plugin-provided skills, and what frontmatter is required? Cite the docs.

- [ ] **Step 3: Record verdicts**

Edit this file's "Verification Outcomes" section, setting `MODEL_OVERRIDE` and `FORK` to `yes`/`no` with a one-line citation each.

- [ ] **Step 4: Commit the decision record**

```bash
git add docs/plans/2026-05-26-code-review-deep-v2.md
git commit -m "chore(code-review-deep): record v2 capability verification (model-override, context:fork)"
```

---

## Task 1: Unit-reviewer inherits the best model + lean returns

**Files:**
- Modify: `agents/code-review-unit-reviewer.md` (frontmatter `model:` line; Rules section)
- Test: `tests/test-code-review-deep.sh:24-34` (the agent loop)

- [ ] **Step 1: Update the test — replace the both-agents-Haiku loop**

In `tests/test-code-review-deep.sh`, replace the block currently at lines 23–34 (the `# --- Agents ---` loop that asserts every agent is `model: haiku`) with:

```bash
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

# Scorer stays Haiku (mechanical verify-against-rubric).
scorer_fm="$(frontmatter "$ROOT/agents/code-review-scorer.md")"
echo "$scorer_fm" | grep -qi "^model: *haiku$" && ok "code-review-scorer is Haiku" \
  || bad "code-review-scorer must be 'model: haiku'"

# Unit-reviewer must NOT pin a model — it inherits the session/best model so
# code units get the strongest model (v2 directive).
ur_fm="$(frontmatter "$ROOT/agents/code-review-unit-reviewer.md")"
if echo "$ur_fm" | grep -qi "^model:"; then
  bad "code-review-unit-reviewer must NOT pin 'model:' (it inherits the best model)"
else
  ok "code-review-unit-reviewer inherits model (no model: pin)"
fi

# Lean returns: bounds the orchestrator's retained context (leak mitigation).
grep -qi "never paste file contents" "$ROOT/agents/code-review-unit-reviewer.md" \
  && ok "unit-reviewer has lean-return instruction" \
  || bad "unit-reviewer missing lean-return (findings-only) instruction"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `code-review-unit-reviewer must NOT pin 'model:'` and `unit-reviewer missing lean-return instruction` (the agent still has `model: haiku` and no lean-return rule).

- [ ] **Step 3: Remove the model pin from the unit-reviewer**

In `agents/code-review-unit-reviewer.md`, delete the frontmatter line:

```
model: haiku
```

(Leave `name`, `description`, `color: cyan`, `tools` intact.)

> **Step 3b — fallback if `MODEL_OVERRIDE = no` (from Task 0):** do NOT rely on a dispatch-time override. Instead keep this file model-less (code units) and create `agents/code-review-unit-reviewer-docs.md` — an exact copy with `model: haiku` and `name: code-review-unit-reviewer-docs` — and in Task 2 route docs units to that agent type. Add it to the dispatch want-list in Task 3's test step. Skip this 3b if `MODEL_OVERRIDE = yes`.

- [ ] **Step 4: Add the lean-return rule**

In `agents/code-review-unit-reviewer.md`, under the `## Rules` section, append this bullet:

```markdown
- Return only the structured findings below — never paste file contents or large
  excerpts back to the orchestrator; cite `file:line` instead. This keeps the
  orchestrator's context bounded across many parallel units.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS lines `code-review-scorer is Haiku`, `code-review-unit-reviewer inherits model (no model: pin)`, `unit-reviewer has lean-return instruction`. (Skill-section assertions may still FAIL — that's expected; they are fixed in Tasks 2–4.)

- [ ] **Step 6: Commit**

```bash
git add agents/code-review-unit-reviewer.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): unit-reviewer inherits best model + lean returns"
```

---

## Task 2: Pass 1 docs flag + Pass 2 model routing + wave cap

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (Pass 1 §39–51; Pass 2 §53–59)
- Test: `tests/test-code-review-deep.sh` (add an ORCH-aware body-check block)

- [ ] **Step 1: Add the ORCH detection + Pass 1/2 assertions to the test**

In `tests/test-code-review-deep.sh`, immediately AFTER the `sfm="$(frontmatter "$skill")"` line (inside the `else` branch of the skill check), insert:

```bash
  # Orchestration body lives in the skill (inline) or in the forked orchestrator
  # agent (if context: fork). Body-level assertions run against ORCH.
  if echo "$sfm" | grep -q "^context: *fork"; then
    ORCH="$ROOT/agents/deep-code-reviewer.md"
  else
    ORCH="$skill"
  fi

  # v2: docs-vs-code routing. Pass 1 must tag docs units; Pass 2 must route
  # docs to Haiku and leave code units on the inherited (best) model.
  grep -q "docs_only" "$ORCH" && ok "orchestrator tags docs_only units" \
    || bad "orchestrator missing docs_only routing"
  grep -qi "model: *haiku" "$ORCH" \
    && ok "orchestrator downgrades docs units to Haiku" \
    || bad "orchestrator missing Haiku override for docs units"

  # Wave cap (leak mitigation): bounded parallelism, not all-at-once.
  grep -qi "at most 5" "$ORCH" && ok "orchestrator caps parallel dispatch at 5" \
    || bad "orchestrator missing wave cap (at most 5 concurrent)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `orchestrator missing docs_only routing` and `orchestrator missing wave cap`.

- [ ] **Step 3: Edit Pass 1 — add the `docs_only` flag**

In `skills/code-review-deep/SKILL.md`, replace the Pass 1 JSON-emit sentence and example (lines ~45–49) so the unit JSON carries `docs_only`. Replace:

```
unit priority: critical (auth/security/data/access) | high (core logic,
user-facing) | medium (utilities/internal) | low (config/docs). Emit JSON:

    [{"name":"...","files":["..."],"priority":"critical","skip":false}, ...]
```

with:

```
unit priority: critical (auth/security/data/access) | high (core logic,
user-facing) | medium (utilities/internal) | low (config). Set `docs_only: true`
when every file in the unit is documentation (`*.md`, `*.mdx`, `*.txt`, `*.rst`,
`docs/**`, or a comment-only diff); config files (`*.json`, `*.yaml`, `*.toml`,
dotfiles) are code-side, NOT docs. There is no early-exit — docs units are
reviewed, just on Haiku. Emit JSON:

    [{"name":"...","files":["..."],"priority":"critical","skip":false,"docs_only":false}, ...]
```

- [ ] **Step 4: Edit Pass 2 — model routing + wave cap**

In `skills/code-review-deep/SKILL.md`, replace the Pass 2 heading and body (lines ~53–59) with:

```markdown
## Pass 2 — Per-unit review (parallel agents, model by code-vs-docs)

Dispatch one `Agent(subagent_type: "second-brain:code-review-unit-reviewer")` per
non-skipped unit, choosing the model by unit kind:

- **code units** (`docs_only: false`): dispatch with NO model override — the agent
  inherits the session model, i.e. the best model available (the v2 directive).
- **doc units** (`docs_only: true`): dispatch with `model: "haiku"` — docs don't
  need deep reasoning.

Dispatch in **waves of at most 5 concurrent agents** (not all 15 at once): run
critical/high code units first, then medium/low code units, then doc units. The
wave cap bounds peak agent count and RAM. Pass each agent: unit name + file list,
`origin/<base>` as the base ref, the change summary, the combined project
conventions (CLAUDE.md + wiki pages), and the episodic prior-review note. Each
agent returns structured findings only (no file bodies). Collect them.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `orchestrator tags docs_only units`, `orchestrator downgrades docs units to Haiku`, `orchestrator caps parallel dispatch at 5`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): code-vs-docs model routing + wave cap in Pass 2"
```

---

## Task 3: Pass 2b — holistic architectural advisory pass

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (new Pass 2b after Pass 2; Pass 4 output)
- Test: `tests/test-code-review-deep.sh` (dispatch want-list + FP-exclusion assertion)
- Reuse: `agents/quality-reviewer.md` (no edit — invoked with the changed-file set)

- [ ] **Step 1: Add the arch-pass assertions to the test**

In `tests/test-code-review-deep.sh`: (a) point the dispatch resolve-loop and want-list at `$ORCH` instead of `$skill`, and (b) add `quality-reviewer` to the want-list + an FP-exclusion check.

Replace the resolve-loop's file reference — change the two lines:

```bash
  dispatched="$(grep -oE 'subagent_type: *"second-brain:[A-Za-z0-9-]+"' "$skill" \
```

to use `"$ORCH"`:

```bash
  dispatched="$(grep -oE 'subagent_type: *"second-brain:[A-Za-z0-9-]+"' "$ORCH" \
```

Then change the want-list loop from:

```bash
  for want in code-review-unit-reviewer code-review-scorer; do
```

to:

```bash
  for want in code-review-unit-reviewer code-review-scorer quality-reviewer; do
```

And append, after that loop:

```bash
  # Architectural notes must be advisory only — never scored or FP-recorded.
  grep -qi "never scored or recorded as false positives" "$ORCH" \
    && ok "arch notes excluded from scoring + FP write-back" \
    || bad "orchestrator missing 'arch notes are advisory' exclusion"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `skill does not dispatch expected agent: quality-reviewer` and `orchestrator missing 'arch notes are advisory' exclusion`.

- [ ] **Step 3: Add Pass 2b to the skill**

In `skills/code-review-deep/SKILL.md`, insert a new section immediately after Pass 2 and before Pass 3:

```markdown
## Pass 2b — Architectural pass (advisory, parallel)

If at least one `critical` or `high` unit exists, dispatch exactly ONE
`Agent(subagent_type: "second-brain:quality-reviewer")` over the deduped union of
all critical+high unit files — run it concurrently with Pass 2 (it shares the wave
budget; it depends only on Pass 1's unit list, not Pass 2's findings). Pass it the
base ref, the change summary, and the file set, instructing it to focus its
architectural checklist on the changed surface. If there are no critical/high
units, skip this pass.

Its `CRITICAL`/`WARNING`/`INFO` output is collected verbatim for a separate
"Architectural notes (advisory)" section in Pass 4. These notes are advisory only:
they are **never scored or recorded as false positives**, and are kept distinct
from the numbered bug findings.
```

- [ ] **Step 4: Add the arch section to Pass 4 output**

In `skills/code-review-deep/SKILL.md` Pass 4, after the comment-format block (after the "Or, if none:" line, before the Link format bullet), insert:

```markdown
   - **Architectural notes (advisory).** If Pass 2b ran, append after the numbered
     findings a section titled `Architectural notes (advisory — not blocking)`
     containing the quality-reviewer output. For `--comment`, post it under that
     same labelled subhead, visually separated from the numbered bug list so a
     reader never mistakes an architectural opinion for a confirmed bug.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `skill dispatches quality-reviewer`, `subagent_type second-brain:quality-reviewer resolves to agents/quality-reviewer.md`, `arch notes excluded from scoring + FP write-back`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): add advisory architectural pass (quality-reviewer)"
```

---

## Task 4: Port-audit fixes (emoji, wording, Haiku delegation, description, leak note)

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (description §3; Pass 0 §25; Pass 4 template §85,§93,§95; Notes §140-144)
- Test: `tests/test-code-review-deep.sh` (no-emoji, description, delegation, wording assertions)

- [ ] **Step 1: Add the audit-fix assertions to the test**

In `tests/test-code-review-deep.sh`, after the FP-exclusion check from Task 3, append:

```bash
  # No emojis in the orchestrator (the deep reference bans them; v1 had a 🤖).
  if grep -q "🤖" "$ORCH"; then
    bad "orchestrator contains an emoji (🤖) — deep review posts no emojis"
  else
    ok "orchestrator has no emoji"
  fi

  # Description must reflect best-model code review, not 'Haiku per-unit'.
  if echo "$sfm" | grep -qi "Haiku per-unit"; then
    bad "skill description still says 'Haiku per-unit' (stale)"
  else
    ok "skill description not stale"
  fi
  echo "$sfm" | grep -qi "best model" && ok "skill description mentions best model" \
    || bad "skill description should mention best-model code review"

  # Pass 0/1 must explicitly delegate mechanical work to Haiku agents.
  grep -qi "haiku agent" "$ORCH" && ok "orchestrator delegates mechanical work to Haiku agents" \
    || bad "orchestrator missing explicit Haiku-agent delegation"

  # Skipped-count wording consistent in both output branches.
  grep -q "skipped as trivial). No issues found" "$ORCH" \
    && ok "no-issues line uses 'skipped as trivial'" \
    || bad "no-issues output line missing 'skipped as trivial'"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `orchestrator contains an emoji`, `skill description still says 'Haiku per-unit'`, `skill description should mention best-model`, `orchestrator missing explicit Haiku-agent delegation`, `no-issues output line missing 'skipped as trivial'`.

- [ ] **Step 3: Refresh the skill description**

In `skills/code-review-deep/SKILL.md` line 3, replace the `description:` value with:

```
description: In-depth multi-pass code review of a GitHub change (local checkout). Decomposes the diff into logical review units, reviews each on the best available model (docs on Haiku), runs an advisory architectural pass on the highest-risk units, scores findings with an FP-aware scorer, consults the second-brain for conventions and prior reviews, and records false positives. Local output by default; --comment posts to the PR.
```

- [ ] **Step 4: Realize the Haiku delegation in Pass 0**

In `skills/code-review-deep/SKILL.md`, replace the Pass 0 lead-in line (currently `Use an agent (Haiku model) for the mechanical parts where noted.`) with:

```markdown
Dispatch a Haiku agent for each mechanical sub-step below — eligibility (step 2),
CLAUDE.md discovery (step 3), and the change summary (step 4) — so the expensive
orchestrator model is not spent on, and its context not bloated by, mechanical
work. The decomposition (Pass 1) and the Pass 4 re-check are likewise Haiku agents.
```

- [ ] **Step 5: Drop the emoji + fix the skipped-count wording**

In `skills/code-review-deep/SKILL.md`:

- Line ~93: replace `🤖 Generated with [Claude Code](https://claude.ai/code) using second-brain:code-review-deep` with `Generated with [Claude Code](https://claude.ai/code) using second-brain:code-review-deep`
- Line ~95: replace `Or, if none: \`Analyzed X review units (Y files, Z skipped). No issues found.\`` with `Or, if none: \`Analyzed X review units (Y files, Z skipped as trivial). No issues found.\``

- [ ] **Step 6: Add the leak diagnostic pointer to Notes**

In `skills/code-review-deep/SKILL.md`, under `## Notes`, append:

```markdown
- If repeated runs leave "ghost" agents/RAM growth, see the diagnostic protocol in
  `docs/specs/2026-05-26-code-review-deep-v2-design.md` (Leak mitigation): check for
  recursive `claude --bare` extractors (API-key mode), orphaned MCP servers, or
  parent-context bloat, then apply the matching gated fix.
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: all PASS; final line `PASS: <n>, FAIL: 0`.

- [ ] **Step 8: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "fix(code-review-deep): port-audit fixes (emoji, wording, Haiku delegation, description)"
```

---

## Task 5: Fork orchestration — CONDITIONAL on `FORK = yes`

> **If Task 0 set `FORK = no`, skip this entire task.** The inline skill from Tasks 1–4 is the shipped form, and the test's `else` branch already asserts "inline orchestration" passes.

**Files:**
- Create: `agents/deep-code-reviewer.md` (forked orchestrator holding the passes)
- Modify: `skills/code-review-deep/SKILL.md` → thin `context: fork` entrypoint
- Test: `tests/test-code-review-deep.sh` (fork-conditional block)

- [ ] **Step 1: Add the fork-conditional assertion to the test**

In `tests/test-code-review-deep.sh`, after the ORCH detection block, append:

```bash
  # If the skill forks, the orchestrator agent must exist with effort: high.
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
```

- [ ] **Step 2: Run the test to verify the current (inline) state still passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `inline orchestration (no context:fork) — deep-code-reviewer not required` (we have not forked yet). No FAIL.

- [ ] **Step 3: Create the orchestrator agent (move the passes into it)**

Create `agents/deep-code-reviewer.md`. Frontmatter, then the body = Passes 0–4 currently in `SKILL.md` (cut them from the skill in Step 4). The agent needs `Write` (FP write-back) and the two MCP tools (second-brain reads):

```markdown
---
name: deep-code-reviewer
description: >-
  Forked orchestrator for code-review-deep. Runs the multi-pass review
  (decompose -> per-unit best-model review -> advisory arch pass -> Haiku
  scoring -> output + FP write-back) in an isolated context so review fan-out
  does not bloat the caller's session.
model: sonnet
effort: high
tools: Read, Write, Agent, Bash(gh pr view *), Bash(gh pr comment *), Bash(gh pr list *), Bash(gh pr diff *), Bash(gh repo view *), Bash(git diff *), Bash(git log *), Bash(git blame *), Bash(git rev-parse *), Bash(git merge-base *), Bash(git branch *), Bash(git status *), Bash(git remote *), Bash(grep *), Bash(find *), mcp__knowledge-base__knowledge_search, mcp__knowledge-base__episodic_search
---

# Deep Code Review (forked orchestrator)

<paste here the entire body of skills/code-review-deep/SKILL.md from the
"## Arguments" heading through "## Notes", exactly as it stands after Task 4.>
```

> Copy the body verbatim from the post-Task-4 `SKILL.md` (Arguments through Notes). Do not paraphrase — the passes are the contract.

- [ ] **Step 4: Thin the skill to a fork entrypoint**

Replace the entire contents of `skills/code-review-deep/SKILL.md` with:

```markdown
---
name: code-review-deep
description: In-depth multi-pass code review of a GitHub change (local checkout). Decomposes the diff into logical review units, reviews each on the best available model (docs on Haiku), runs an advisory architectural pass on the highest-risk units, scores findings with an FP-aware scorer, consults the second-brain for conventions and prior reviews, and records false positives. Local output by default; --comment posts to the PR.
disable-model-invocation: false
argument-hint: "[<PR#>] [--comment] [--base <branch>]"
context: fork
agent: second-brain:deep-code-reviewer
allowed-tools: Read Write Bash(gh pr view *) Bash(gh pr comment *) Bash(gh pr list *) Bash(gh pr diff *) Bash(gh repo view *) Bash(git diff *) Bash(git log *) Bash(git blame *) Bash(git rev-parse *) Bash(git merge-base *) Bash(git branch *) Bash(git status *) Bash(git remote *) Agent mcp__knowledge-base__knowledge_search mcp__knowledge-base__episodic_search
---

# Deep Code Review

Runs the multi-pass deep review inside a forked context via the
`second-brain:deep-code-reviewer` orchestrator agent, so the review's parallel
fan-out does not accumulate in the caller's session. Pass any `<PR#>`, `--comment`,
and `--base <branch>` arguments straight through to that agent.
```

> `allowed-tools` is retained because `scripts/validate-plugin.sh` requires `name`,
> `description`, and `allowed-tools` on every SKILL.md.

- [ ] **Step 5: Validate plugin structure + run the test**

Run: `bash scripts/validate-plugin.sh && bash tests/test-code-review-deep.sh`
Expected: `OK: all plugin files valid`, then the test PASSes including `context:fork present and deep-code-reviewer agent exists`, `deep-code-reviewer effort: high`, `deep-code-reviewer model: sonnet`. The body-checks (docs_only, wave cap, dispatches, emoji, wording) now read `$ORCH = agents/deep-code-reviewer.md` and pass there.

- [ ] **Step 6: Commit**

```bash
git add agents/deep-code-reviewer.md skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): forked deep-code-reviewer orchestrator (context:fork)"
```

---

## Task 6: Release plumbing — version, migration row, README, full gate

**Files:**
- Modify: `.claude-plugin/plugin.json` (version)
- Modify: `skills/upgrade/SKILL.md` (migration table)
- Modify: `README.md` (catalog line ~89)

- [ ] **Step 1: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.14.0"` to `"version": "0.15.0"`.

- [ ] **Step 2: Add the migration row**

In `skills/upgrade/SKILL.md`, add a row to the migration table matching the existing column format (`| **<version>** | <what changed> | <idempotent check> |`):

```
| **0.15.0** | code-review-deep v2: code reviewed on best model, docs on Haiku, advisory architectural pass, forked orchestrator | none — skill/agent prompt-only change, no user state to migrate |
```

- [ ] **Step 3: Verify the migration-row gate passes**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.15.0`.

- [ ] **Step 4: Update the README catalog line**

In `README.md` line ~89, replace the `code-review-deep` row's description with:

```
| `/second-brain:code-review-deep [<PR#>]` | Multi-pass deep code review: review-unit decomposition + per-unit reviewers on the best available model (docs on Haiku), an advisory architectural pass on critical/high units, FP-aware scoring, wiki/episodic context, false-positive memory. `--comment` posts to the PR |
```

- [ ] **Step 5: Run the full suite**

Run: `make test`
Expected: `ALL GREEN` (pass > 0, fail: 0). If the MCP vitest step is slow/unavailable, scope to shell tests with `SB_RUN_ALL_VITEST=0 make test`, then run vitest separately.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md README.md
git commit -m "chore(release): code-review-deep v2 — bump 0.15.0 + migration row + README"
```

- [ ] **Step 7: Deep-review release gate (per the standing release rule)**

Run `/second-brain:code-review-deep` on this branch (no `--comment`) and read the output. This dogfoods the v2 skill on its own change. Resolve any real findings before considering the work shippable. (This is a verification step, not a commit gate — report the output.)

---

## Self-Review (completed by plan author)

- **Spec coverage:** model strategy → Tasks 1–2; no early-exit → Task 2 Step 3; Pass 2b → Task 3; leak (wave cap + lean returns) → Tasks 1–2; leak diagnostic/gated fix → Task 4 Step 6 (pointer) + spec; fork-if-supported → Tasks 0 & 5; port-fidelity fixes 1–6 → Tasks 4 (emoji, wording, delegation, description) + 5 (effort:high, fork) + 1 (model); verify-first risks → Task 0; test extension → every task; release plumbing → Task 6. No uncovered spec section.
- **Placeholder scan:** no TBD/TODO except the Task-0-filled Verification Outcomes (by design). Every code/edit step shows the literal content.
- **Type/name consistency:** agent type strings (`second-brain:code-review-unit-reviewer`, `…:code-review-scorer`, `…:quality-reviewer`, `…:deep-code-reviewer`), the `docs_only` field, the `at most 5` wave-cap phrase, the `never scored or recorded as false positives` sentinel, and the `never paste file contents` lean-return phrase are used identically in the skill/agent edits and in the test assertions that check for them.
