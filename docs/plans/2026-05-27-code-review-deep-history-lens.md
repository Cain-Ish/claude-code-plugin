# code-review-deep history/regression lens Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Add a dedicated git-history lens to `code-review-deep` that catches the regression bug class (reverts of prior fixes, re-introduced bugs, removed deliberate guards) the per-unit reviewers structurally cannot see — and give the scorer the git tools it needs to confirm those findings.

**Architecture:** A prompt/skill change, not application code. One new agent (`code-review-history-reviewer`, inherits model, `effort: high`, read-only git log/blame) runs once over the changed code files as a new Pass 2c, concurrent with Pass 2/2b under the existing wave cap. Its findings are scored as bugs (Pass 3), not advisory. The scorer (`code-review-scorer`) gains `git log`/`git blame` so the gate can verify regression claims. Behavior is LLM-driven, so the test suite (`tests/test-code-review-deep.sh`) guards the structural contract, not the review output.

**Tech Stack:** Markdown + YAML frontmatter (Claude Code skills/agents); Bash structural tests run by `tests/run-all.sh` / `make test`; `scripts/validate-plugin.sh`; `jq`.

**Spec:** `docs/specs/2026-05-27-code-review-deep-history-lens-design.md`

**Branch:** `code-review-history-lens` (spec already committed there; off `main` at 0.18.0).

---

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `agents/code-review-history-reviewer.md` | **NEW** — history/regression lens; inherits model, `effort: high`, read-only git log/blame | 1 |
| `agents/code-review-scorer.md` | Confidence scorer. v2.2: **+ `git log`/`git blame` tools** + history-verification instruction | 2 |
| `skills/code-review-deep/SKILL.md` | Orchestration. **+ Pass 2c**, wave-1 composition note, `regression` category | 3 |
| `tests/test-code-review-deep.sh` | Structural/wiring guard | 1, 2, 3 |
| `.claude-plugin/plugin.json` | Version → 0.19.0 | 4 |
| `skills/upgrade/SKILL.md` | Migration row for 0.19.0 | 4 |
| `README.md` | Catalog line (~line 89) | 4 |

---

## Task 1: Create the history-reviewer agent

**Files:**
- Create: `agents/code-review-history-reviewer.md`
- Test: `tests/test-code-review-deep.sh` (agent name/description loop line 25; new agent-specific block after the unit-reviewer effort check ~line 68)

- [ ] **Step 1: Add the agent assertions to the test**

In `tests/test-code-review-deep.sh`, change the agent name/description loop (line 25) from:

```bash
for agent in code-review-unit-reviewer code-review-scorer; do
```

to:

```bash
for agent in code-review-unit-reviewer code-review-scorer code-review-history-reviewer; do
```

Then, immediately AFTER the unit-reviewer effort block (the line `  || bad "unit-reviewer missing 'effort: high'"`), insert:

```bash

# v2.2: history-reviewer is a dedicated regression lens. It must inherit the model
# (no pin), reason at effort: high, and have read-only git history tools.
hr="$ROOT/agents/code-review-history-reviewer.md"
if [ ! -f "$hr" ]; then
  bad "history-reviewer file missing: agents/code-review-history-reviewer.md"
else
  hr_fm="$(frontmatter "$hr")"
  hr_keys="$(printf '%s\n' "$hr_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
  printf '%s\n' "$hr_keys" | grep -qi '^model:' \
    && bad "code-review-history-reviewer must NOT pin 'model:' (it inherits the best model)" \
    || ok "code-review-history-reviewer inherits model (no model: pin)"
  printf '%s\n' "$hr_keys" | grep -qi '^effort:' \
    && ok "history-reviewer sets effort (deeper reasoning)" \
    || bad "history-reviewer missing 'effort: high'"
  hr_tools="$(printf '%s\n' "$hr_fm" | grep '^tools:')"
  case "$hr_tools" in *"git log"*) ok "history-reviewer tools grant git log" ;; *) bad "history-reviewer tools must grant Bash(git log *)" ;; esac
  case "$hr_tools" in *"git blame"*) ok "history-reviewer tools grant git blame" ;; *) bad "history-reviewer tools must grant Bash(git blame *)" ;; esac
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `history-reviewer file missing: agents/code-review-history-reviewer.md` (and the name/description loop reports the missing file).

- [ ] **Step 3: Create the agent file**

Create `agents/code-review-history-reviewer.md` with exactly:

```markdown
---
name: code-review-history-reviewer
description: |
  Reviews a change against its git history to find the regression bug class that
  diff-only review misses: changes that revert or re-introduce a previously-fixed
  bug, or contradict the historical reason a line exists. Runs once over the changed
  code files using git blame/log. Dispatched by the code-review-deep skill (Pass 2c)
  alongside the per-unit reviewers.

  <example>
  Context: code-review-deep has decomposed a PR and is fanning out reviewers.
  assistant: "Dispatching code-review-history-reviewer to blame-walk the changed code for reverts and re-introduced bugs."
  </example>
color: yellow
effort: high
tools: Read, Bash(git diff *), Bash(git log *), Bash(git blame *)
---

# History / Regression Reviewer

You are a senior reviewer hunting ONE specific bug class: regressions visible only
in git history. Your task input provides: the changed code file list (union of all
non-doc review units), the base ref (e.g. `origin/main`), the change summary, the
project conventions (CLAUDE.md + wiki), and a prior-review note from episodic memory.

## Instructions

1. For each file, run `git diff <base>...HEAD -- <file>` to see what changed.
2. For the changed and adjacent lines, run `git blame` and `git log` to recover WHY
   the code is the way it is and which prior commits touched it.
3. Hunt these history-derived issues ONLY (the per-unit reviewers already cover
   diff-local logic, types, and edge cases — do not duplicate those):
   - The change **reverts or re-introduces a previously-fixed bug** — a prior commit
     fixed exactly this, and the change undoes it.
   - The change **removes or weakens a guard/check** a past commit added deliberately
     (the commit message or surrounding history shows the intent).
   - The change **repeats a mistake** history shows was already corrected elsewhere
     in these files.
4. Scope strictly to lines changed since `<base>`. Pre-existing issues on untouched
   lines are out of scope.
5. For files shown as deleted in the diff, do NOT attempt to Read them.

## Output

For each issue, return:
- **file**: path
- **lines**: range (e.g. "42-45")
- **category**: regression
- **severity**: critical | high | medium | low
- **title**: one sentence
- **explanation**: what's wrong, why it matters, and the prior commit (short-SHA)
  whose fix or intent this change undoes or contradicts
- **is_migrated_code**: true if this code was copied/moved within this change

If you find no history-derived issues, say "No issues found."

## Rules

- Report only issues you can ground in an actual prior commit. Cite the commit
  short-SHA in the explanation. Do not speculate.
- Do NOT re-report diff-local bugs the per-unit reviewers handle — stay in the
  history lane.
- Return only the structured findings — never paste file contents or large excerpts
  back to the orchestrator; cite `file:line` and commit short-SHAs instead. This
  keeps the orchestrator's context bounded.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `code-review-history-reviewer inherits model (no model: pin)`, `history-reviewer sets effort (deeper reasoning)`, `history-reviewer tools grant git log`, `history-reviewer tools grant git blame`. (The dispatch want-list check added in Task 3 is not present yet — but the resolve loop won't see a `code-review-history-reviewer` dispatch until Task 3, so do NOT add the want-list entry here.)

- [ ] **Step 5: Validate plugin structure**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid` (the new agent has the required `name`/`description`).

- [ ] **Step 6: Commit**

```bash
git add agents/code-review-history-reviewer.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): add history/regression reviewer agent"
```

---

## Task 2: Scorer gains git history tools + verification instruction

**Files:**
- Modify: `agents/code-review-scorer.md` (frontmatter `tools:` line 14; Adjustments section)
- Test: `tests/test-code-review-deep.sh` (after the scorer no-pin block, ~line 43)

- [ ] **Step 1: Add the scorer-tools assertion to the test**

In `tests/test-code-review-deep.sh`, immediately AFTER the scorer no-pin block (the line `fi` that closes the `code-review-scorer inherits model` check, ~line 43), insert:

```bash

# v2.2: the scorer must be able to verify regression findings, which requires
# reading git history (the v2.1 lesson applied to tools, not just model).
scorer_tools="$(printf '%s\n' "$scorer_fm" | grep '^tools:')"
case "$scorer_tools" in *"git log"*) ok "scorer tools grant git log" ;; *) bad "code-review-scorer tools must grant Bash(git log *)" ;; esac
case "$scorer_tools" in *"git blame"*) ok "scorer tools grant git blame" ;; *) bad "code-review-scorer tools must grant Bash(git blame *)" ;; esac
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `code-review-scorer tools must grant Bash(git log *)` and `... git blame *`.

- [ ] **Step 3: Widen the scorer's tools**

In `agents/code-review-scorer.md`, change the frontmatter `tools:` line (line 14) from:

```
tools: Read, Bash(git diff *)
```

to:

```
tools: Read, Bash(git diff *), Bash(git log *), Bash(git blame *)
```

- [ ] **Step 4: Add the history-verification instruction**

In `agents/code-review-scorer.md`, immediately after the `## Adjustments (apply after the base score)` bullet list (after the `**Matches a known false-positive pattern**` bullet, before `## Output`), insert:

```markdown

## Verifying history findings

For `regression`/history findings, use `git log`/`git blame` to confirm the cited
prior commit exists and that this change actually reverts or contradicts it. If you
cannot ground the claim in real history, do NOT inflate the score — treat it as
unverified (≤50).
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `scorer tools grant git log`, `scorer tools grant git blame`.

- [ ] **Step 6: Commit**

```bash
git add agents/code-review-scorer.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): scorer gains git log/blame to verify regression findings"
```

---

## Task 3: SKILL Pass 2c + wave-1 composition + dispatch wiring

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (Pass 2b wave note line 87–88; new Pass 2c after line 98)
- Test: `tests/test-code-review-deep.sh` (dispatch want-list ~line 147; new Pass 2c present check)

- [ ] **Step 1: Add the dispatch + Pass-2c assertions to the test**

In `tests/test-code-review-deep.sh`, change the dispatch want-list loop from:

```bash
  for want in code-review-unit-reviewer code-review-scorer quality-reviewer; do
```

to:

```bash
  for want in code-review-unit-reviewer code-review-scorer quality-reviewer code-review-history-reviewer; do
```

Then, immediately after the `arch notes excluded from scoring + FP write-back` check block (the one ending `|| bad "orchestrator missing 'arch notes are advisory' exclusion"`), insert:

```bash
  # v2.2: the history/regression pass must exist and be scored (not advisory).
  grep -qi "Pass 2c" "$ORCH" && ok "orchestrator has Pass 2c (history/regression)" \
    || bad "orchestrator missing Pass 2c history/regression pass"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `orchestrator does not dispatch expected agent: code-review-history-reviewer` and `orchestrator missing Pass 2c history/regression pass`.

- [ ] **Step 3: Update the Pass 2b wave-1 composition note**

In `skills/code-review-deep/SKILL.md`, replace the sentence (lines 87–89):

```
all critical+high unit files. It **occupies one slot in wave 1** — so wave 1 holds
at most 4 unit-reviewers + this architectural reviewer (≤5 concurrent total),
keeping the cap intact. It depends only on Pass 1's unit list, not Pass 2's
```

with:

```
all critical+high unit files. It **occupies one slot in wave 1** (as does the Pass
2c history reviewer when it runs) — so wave 1 holds at most 3 unit-reviewers + the
architectural reviewer + the history reviewer (≤5 concurrent total), keeping the cap
intact. When either advisory/history pass is skipped, its slot returns to
unit-reviewers. It depends only on Pass 1's unit list, not Pass 2's
```

- [ ] **Step 4: Add Pass 2c after Pass 2b**

In `skills/code-review-deep/SKILL.md`, insert a new section immediately after the Pass 2b block (after the line `the numbered bug findings.` at line 98, before `## Pass 3`):

```markdown

## Pass 2c — History / regression pass (scored, parallel)

If at least one non-skipped **code** unit exists (`docs_only: false`), dispatch
exactly ONE `Agent(subagent_type: "second-brain:code-review-history-reviewer")` over
the deduped union of all non-skipped code-unit files. It **occupies one slot in wave
1** alongside the architectural reviewer (see the Pass 2b wave-1 note). It depends
only on Pass 1's unit list, not Pass 2's findings, so it runs concurrently. Pass it
`origin/<base>` (the SAME base-ref form Pass 2 uses), the change summary, the combined
project conventions (CLAUDE.md + wiki), and the episodic prior-review note. Unlike the
architectural pass, its findings ARE bugs (category `regression`): they flow into
Pass 3 dedup + scoring exactly like the per-unit findings. If every unit is docs-only,
skip this pass.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `orchestrator dispatches code-review-history-reviewer`, `subagent_type second-brain:code-review-history-reviewer resolves to agents/code-review-history-reviewer.md`, `orchestrator has Pass 2c (history/regression)`, and the final line `PASS: <n>, FAIL: 0`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): wire history/regression lens as scored Pass 2c"
```

---

## Task 4: Release plumbing — version, migration row, README, full gate

**Files:**
- Modify: `.claude-plugin/plugin.json` (version)
- Modify: `skills/upgrade/SKILL.md` (migration table)
- Modify: `README.md` (catalog line ~89)

- [ ] **Step 1: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.18.0"` to `"version": "0.19.0"`.

- [ ] **Step 2: Add the migration row**

In `skills/upgrade/SKILL.md`, add a row immediately after the `| **0.18.0** | …` row:

```
| **0.19.0** | code-review-deep history/regression lens. New `code-review-history-reviewer` agent (inherits the best model, `effort: high`, read-only `git log`/`git blame`) runs once over all changed code files as a scored Pass 2c, concurrent with Pass 2/2b under the existing ≤5 wave cap. It catches the regression bug class diff-only review misses: reverts of prior fixes, re-introduced bugs, removed deliberate guards. The `code-review-scorer` gains `git log`/`git blame` (and a history-verification instruction) so the gate can confirm regression findings — the v2.1 gate-lockstep lesson applied to tools. Prompt/agent/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
```

- [ ] **Step 3: Verify the migration-row gate passes**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.19.0`.

- [ ] **Step 4: Update the README catalog line**

In `README.md` (~line 89), replace the `code-review-deep` row's description with:

```
| `/second-brain:code-review-deep [<PR#>]` | Multi-pass deep code review: review-unit decomposition + per-unit reviewers on the best available model (docs on Haiku), a git-history regression lens, an advisory architectural pass on critical/high units, FP-aware scoring with a surfaced lower-confidence band, wiki/episodic context. `--comment` posts to the PR |
```

- [ ] **Step 5: Validate plugin + run the full suite**

Run: `bash scripts/validate-plugin.sh && SB_RUN_ALL_VITEST=0 make test`
Expected: `OK: all plugin files valid`, then `ALL GREEN` (pass > 0, fail: 0). Run vitest separately if it was scoped out.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md README.md
git commit -m "chore(release): code-review-deep history lens — bump 0.19.0 + migration row + README"
```

- [ ] **Step 7: Deep-review release gate (standing release rule)**

After the plugin cache refreshes to 0.19.0, run `/second-brain:code-review-deep` on this branch (no `--comment`) and read the output — this dogfoods the history lens. Confirm the Pass 2c history reviewer dispatches and that regression findings (if any) are scored, not advisory. (Verification step — report the output; not a commit gate. Note the plugin-cache-vs-repo gap: until the cache refreshes, the installed pipeline is the older version.)

---

## Self-Review (completed by plan author)

- **Spec coverage:** new history-reviewer agent → Task 1; scorer git log/blame + verification → Task 2; Pass 2c (scored, all code files, wave-1 slot, docs-only skip) → Task 3; wave-1 composition update → Task 3 Step 3; `regression` category → agent output (Task 1) + Pass 2c note (Task 3); testing requirements → assertions in Tasks 1–3; release plumbing (version, migration row, README, deep-review gate) → Task 4. No uncovered spec section.
- **Placeholder scan:** no TBD/TODO. Every create/edit step shows literal content.
- **Type/name consistency:** the agent name `code-review-history-reviewer` is used identically in the agent file `name:`, the SKILL `subagent_type`, the test want-list, the test agent loop, and the test history block. The contract sentinel `Pass 2c` matches between the SKILL section heading (Task 3 Step 4) and the test grep (Task 3 Step 1). Tool-grant checks (`git log`, `git blame`) use the same substrings present in the agent/scorer `tools:` lines. The category value `regression` matches between the agent Output schema and the Pass 2c note.
