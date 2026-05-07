---
name: doubt
description: Adversarial validation of the second-brain plugin. Questions architectural layers from a position of maximum skepticism, drilling from general to granular. Rotates focus across runs using git-change priority, history rotation, and perspective variety so different questions are asked each time.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Agent Bash(git diff *) Bash(git log *) Bash(git show *) Bash(find *) Bash(grep *) Bash(ls *) Bash(wc *) Bash(cat *) Bash(head *) Bash(tail *) Bash(jq *) Bash(date *) Bash(test *) Bash(sort *) Bash(uniq *)
argument-hint: "[--layer <name> | --changed | --full | <path-or-topic>]"
---

# Adversarial Doubt Session

Systematically question whether the second-brain plugin actually works. Start from doubt ("this probably doesn't work"), read the actual code, and prove or disprove each claim with line references.

## Layer Taxonomy

Each layer maps to specific files. Pick layers to doubt based on the selection algorithm below.

| ID | Layer | Key Files |
|----|-------|-----------|
| `hooks` | Hook system | `hooks/hooks.json`, `scripts/ensure-dirs.sh`, `scripts/session-load.sh` |
| `stop-extract` | Stop-hook extraction | `scripts/stop-extract.sh`, `scripts/lib.sh` |
| `learning` | Learning pipeline | `skills/improve/SKILL.md` |
| `mcp` | MCP server | `mcp/src/server.ts` |
| `quality` | Quality gate | `scripts/quality-gate.sh`, `agents/quality-reviewer.md` |
| `compact` | Compaction handling | `scripts/pre-compact.sh`, `scripts/lib.sh` |
| `platform` | Cross-platform | All scripts (date, mktemp, find, sed, flock) |
| `bootstrap` | Setup/upgrade flow | `skills/setup/SKILL.md`, `skills/upgrade/SKILL.md`, `scripts/ensure-dirs.sh` |
| `wiki` | Wiki maintenance | `agents/knowledge-maintainer.md`, `skills/lint/SKILL.md` |

## Perspective Taxonomy

Each perspective asks fundamentally different questions about the same layer.

| ID | Perspective | Core Question |
|----|------------|---------------|
| `correctness` | Does it work? | Trace the happy path end-to-end. Does the output match what the code claims? |
| `failure` | What breaks? | Missing files, empty inputs, timeouts, permission errors, corrupt data |
| `race` | Concurrency issues | Multiple hooks writing same file, stale reads, lock contention |
| `evolution` | Does it degrade? | Unbounded file growth, stale entries never cleaned, counter drift |
| `fresh-install` | Day-zero experience | What happens before any state files exist? Silent failures? |
| `adversarial` | Can it be gamed? | Skipping quality gates, ignoring learnings, malformed input |
| `integration` | Do layers connect? | Does output of layer X feed correctly into input of layer Y? |
| `observability` | Can you tell what happened? | Logging, error surfaces, silent failures, debugging affordances |

## Steps

### 0. Load project context from CLAUDE.md

Before selecting layers, scan for CLAUDE.md files that describe the project's ground truth:

```bash
# Project-level CLAUDE.md (most specific)
cat .claude/CLAUDE.md 2>/dev/null
# Repo-root CLAUDE.md
cat CLAUDE.md 2>/dev/null
# User-level CLAUDE.md (global preferences)
cat ~/.claude/CLAUDE.md 2>/dev/null
```

Read whatever is there and identify any claims, constraints, conventions, goals, or stated truths that are relevant to the layers you're about to doubt. CLAUDE.md content varies wildly by project domain — a marketing repo might state brand guidelines and approval workflows; a game project might list performance budgets and platform targets; a backend service might declare SLA requirements and data retention policies. Don't look for a fixed list of categories — read the file, understand the project's domain, and extract whatever would make your doubt questions sharper.

The most valuable doubt questions come from the gap between **what CLAUDE.md says should be true** and **what the code actually does**. Any stated claim is a target: "we always do X" → does the code actually do X? "Y is critical" → is Y actually tested/enforced?

If no CLAUDE.md files exist, proceed without — the layer taxonomy provides enough structure.

### 1. Load history and determine focus

Read `~/.second-brain/doubt-history.jsonl` (create if missing). Each line records a past run:
```json
{"timestamp":"ISO8601","layers":["hooks","stop-predicate"],"perspectives":["failure","race"],"findings":2,"issues":1,"fragile":1}
```

Parse arguments:
- `--layer <name>`: Force a specific layer. Pick the least-used perspective for it.
- `--changed`: Only doubt layers whose files changed recently (`git log --since="30 days ago" --name-only`).
- `--full`: Shallow scan of ALL 9 layers, `correctness` perspective only, 1 question each. Produces a coverage map.
- `<path-or-topic>` (free text): Target arbitrary code outside the predefined layers. See **Ad-hoc focus** below.
- No args: Use the selection algorithm below.

#### Ad-hoc focus (free text arguments)

When the argument doesn't match any flag, treat it as an **ad-hoc focus target**:

1. **Resolve the target**:
   - If it's a file/directory path (e.g., `src/ui/`, `components/ActionDots.tsx`): list the files there (`find <path> -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.sh' -o -name '*.md'`).
   - If it's a topic/keyword (e.g., `actiondots`, `authentication`, `caching`): search the codebase (`grep -rl <keyword> . --include='*.ts' --include='*.tsx' --include='*.sh'`).
   - Combine: `doubt src/ui/ actiondots` finds files in `src/ui/` related to "actiondots".

2. **Generate an ad-hoc layer**: Create a temporary layer definition from discovered files:
   ```
   Ad-hoc layer: "<target>"
   Key files: [discovered files, up to 10 most relevant]
   ```

3. **Select perspectives**: Pick 2-3 perspectives from the taxonomy that best fit the discovered code (e.g., if it's UI code, `correctness` + `failure` + `adversarial`; if it's a data pipeline, `race` + `evolution` + `integration`).

4. **Run the standard doubt protocol** (step 3) against the ad-hoc layer. All other steps (runtime state checking, conversational drilling, cross-layer chains, critic validation) apply unchanged.

5. **History**: Log ad-hoc runs to `doubt-history.jsonl` with `layers: ["adhoc:<target>"]` so they appear in rotation tracking.

Ad-hoc mode works in any repository — the predefined layers are only for the second-brain plugin itself.

### 2. Select (layer, perspective) pairs

Score each combination:

1. **Git change bonus (+3)**: Run `git log --since="30 days ago" --name-only --pretty=format:` in the plugin root. Map changed files to layers. Recently changed layers get +3.
2. **History rotation (+days since last doubt)**: For each (layer, perspective), count days since it last appeared in doubt-history.jsonl. Never-doubted pairs get +30.
3. **Pick the top scoring pairs.** Break ties by picking different perspectives for variety. Don't fix a number — pick as many as the session can handle. A small simple layer (quality-gate is one file, 5 lines) might take 2 minutes; a complex one (MCP server, learning pipeline) could take 20. Judge by complexity, not by a quota.

Report which pairs were selected and why before proceeding.

### 3. Doubt protocol (for each selected pair)

For each (layer, perspective):

1. **Read all key files** listed in the taxonomy for that layer.
2. **Check runtime state** — don't just read source code. Verify actual artifacts:
   - Do the output files exist? (`ls ~/.second-brain/`, `ls ~/.second-brain/projects/`, `ls ~/.second-brain/wiki/`)
   - What's in the data files? (`tail -5 ~/.second-brain/learnings.md`, `wc -l ~/.second-brain/.session-baseline-*.md`)
   - Is the state consistent with what the code claims to produce?
   - The gap between "the code would write X" and "X actually exists on disk" is where the best bugs hide.
3. **Start from doubt**: "I believe [layer] does NOT work correctly because..." — force yourself to find reasons to doubt.
4. **Drill conversationally with branching** — each answer must spawn the next doubt. Don't ask independent questions. Chain them, but at each level expand and prune:
   - **Branch:** generate 2–3 alternative attack vectors against the current claim, not just one. Each vector is a different angle (e.g. "the input is malformed" vs "the output is stale" vs "the dependency is missing").
   - **Evaluate each vector** as `sure` (likely to expose a real bug), `maybe` (worth a quick check), or `impossible` (the code clearly defends against it — drop it).
   - **Anti-self-deception rule:** to label a vector `impossible`, you must cite the specific file:line that defends against it. No `impossible` labels without a code-grounded reason. This blocks the failure mode where you optimistically prune the hardest doubts and let the post-hoc critic only see what survived.
   - **Log every branch** — drilled or abandoned — to a per-run scratchpad (`branches: [{vector, score, drilled|abandoned, reasoning, citation}]`). The step-4 critic receives the full log, not just findings, so it can flag systematic over-pruning.
   - **Drill the highest-scoring branch first.** If it produces VALIDATED, **backtrack** to the next-best branch instead of inventing a new doubt deeper down that chain — backtracking is cheaper than forced depth.
   - **Lookahead before drilling deep:** before going past 3 levels on one branch, ask "if this doubt held, would it produce a real, exploitable bug, or a theoretical one?" If theoretical, pivot to a different perspective on the same layer.
   - Example progression:
     - L0: "This layer doesn't work." → evidence it does.
     - L1: branch into [output stale, race condition, fresh-install gap] → evaluate `sure / maybe / impossible` (the `impossible` one needs a file:line cite) → drill `output stale`.
     - L2: "Output stale because the timestamp uses local TZ?" → VALIDATED → backtrack to `race condition`.
     - L2': "Two hooks write the same file without a lock?" → ISSUE found.
   The pattern is adversarial dialogue with deliberate exploration, not a fixed-depth chain or checklist. A trivial layer might need 2 exchanges across 1 branch; a complex one might need 10+ across 3–4 branches with backtracks. Stop when every remaining branch evaluates to `impossible` (with a citation) — not after a fixed count.
5. **Follow cross-layer chains**: If a finding in one layer touches another layer's input/output, trace the chain. The best findings come from following a failure across layer boundaries (e.g., "knowledge_search never returns results → vectors.db doesn't exist → ensure-dirs.sh doesn't create it → setup was never run").
6. **Answer each question honestly** by reading the actual code AND checking runtime state. Cite file:line. No speculation.
7. **Classify each answer**:
   - **VALIDATED**: Works correctly, code and runtime state prove it
   - **ISSUE**: Real bug or incorrect behavior
   - **FRAGILE**: Works now but would break under reasonable conditions
   - **UNKNOWN**: Can't verify from code alone (needs runtime testing)

### 3b. Re-doubt previous fixes (if history exists)

If `doubt-history.jsonl` shows previous runs that found ISSUE or FRAGILE findings, pick 1-2 of the most recent and verify they were actually fixed:
- Was the fix committed? (`git log --oneline --all -- <file>`)
- Does the fix address the root cause or just the symptom?
- Can you construct a scenario where the fix breaks?

This prevents the pattern where a fix is claimed but never lands, or where a fix introduces a new problem.

### 4. Critic validation

For any finding classified as ISSUE or FRAGILE, spawn a single `quality-reviewer` subagent:

```
Agent(subagent_type: "second-brain:quality-reviewer")
Prompt: "Validate these doubt findings independently. For each, read the cited file and line, and classify as CONFIRMED (real issue), DISPUTED (doubt session is wrong), or NEEDS-TESTING (can't tell from code). Be specific about why.

Also review the branch log (drilled + abandoned). For each branch labeled `impossible`, verify the citation actually defends against the angle described. Flag any branch where the `impossible` reasoning is hand-wavy or the citation is unrelated — this is where same-context pruning bias hides. Report SYSTEMATIC OVER-PRUNING if more than one abandoned branch has weak justification."
```

Include the finding details, file paths, line numbers, AND the branch log from step 3.4. One subagent call total — bundle all findings together. The branch log is what makes the post-hoc critic able to catch ICRH at branch-selection time.

### 5. Report

Output a structured report:

```markdown
# Doubt Session Report (YYYY-MM-DD)

## Focus
- Layers: [selected layers]
- Perspectives: [selected perspectives]
- Selection rationale: [why these were chosen]

## Findings

| # | Layer | Finding | Severity | File:Line | Critic |
|---|-------|---------|----------|-----------|--------|

## Validated (no issues)
- [layer]: [what was checked and passed]

## Recommendations
1. [For ISSUE findings]: specific fix
2. [For FRAGILE findings]: hardening suggestion
```

### 6. Log to history

Append to `~/.second-brain/doubt-history.jsonl`:
```bash
jq -nc \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson layers '["hooks","stop-predicate"]' \
  --argjson perspectives '["failure","race"]' \
  --argjson findings 2 \
  --argjson issues 1 \
  --argjson fragile 1 \
  --argjson confirmed 2 \
  --argjson disputed 0 \
  --argjson branches_generated 7 \
  --argjson branches_drilled 4 \
  --argjson branches_abandoned 3 \
  --argjson over_pruned 0 \
  '{timestamp:$t, layers:$layers, perspectives:$perspectives, findings:$findings, issues:$issues, fragile:$fragile, confirmed:$confirmed, disputed:$disputed, branches_generated:$branches_generated, branches_drilled:$branches_drilled, branches_abandoned:$branches_abandoned, over_pruned:$over_pruned}' \
  >> ~/.second-brain/doubt-history.jsonl
```

The `confirmed` and `disputed` counts from the critic gate track calibration over time — a skill that's always disputed is asking bad questions; one that's always confirmed is well-calibrated. The `branches_*` counts track the new branching pattern: a healthy run drills more than it abandons (drilled / generated > 0.5); an `over_pruned` count from the critic ≥ 1 means same-context bias is creeping back in. Old log entries lacking these fields are valid — readers must default missing branch fields to 0.

### 7. Self-assessment: compare against previous runs

If `~/.second-brain/doubt-history.jsonl` has previous entries, review this run's quality against past performance:

1. **Read the history** and compare this run's `issues` + `fragile` counts against previous runs. Is the hit rate improving, declining, or flat?
2. **Evaluate question quality**: Were this run's questions specific enough? Did they cite real line numbers and test real code paths? Or were they generic ("does this work?") without code grounding?
3. **Check for diminishing returns**: If recent runs keep finding 0 issues on the same layers, those layers may be well-hardened — the skill should prioritize untested layers more aggressively.
4. **Consider skill improvements**: Based on this run's experience, does the skill itself need changes? Examples:
   - New layers that should be added to the taxonomy (found code not covered by any layer)
   - Perspectives that consistently find nothing (consider replacing or refining them)
   - Question patterns that work well (capture as guidance for future runs)
   - The critic agreed with everything / disputed everything (is the doubt calibration off?)

Output a brief `## Self-Assessment` section at the end of the report with 2-3 sentences on what worked, what didn't, and whether the skill definition should be updated. If concrete improvements are identified, offer to apply them.

### 8. Integration offers

After the report, offer but do NOT auto-execute:
- "Promote finding #N to a learning via `/second-brain:improve`?"
- "Create a regression probe in `~/.second-brain/regressions/` for finding #N?"
- "Fix finding #N directly?"
- "Update the doubt skill with improvements from the self-assessment?"

## Context Budget

- **Layer count is flexible** — small layers can be covered quickly, complex ones take more context. Don't force a quota; judge by remaining context budget.
- **`--full` mode**: 1 question per layer, reads only the primary file. Broad coverage map.
- **One quality-reviewer subagent call** total, bundling all ISSUE/FRAGILE findings.
- If the skill is running during a session with high compact pressure, warn the user and suggest running via `/clear` first.
