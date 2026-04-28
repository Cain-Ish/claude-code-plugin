---
name: doubt
description: Adversarial validation of the second-brain plugin. Questions architectural layers from a position of maximum skepticism, drilling from general to granular. Rotates focus across runs using git-change priority, history rotation, and perspective variety so different questions are asked each time.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Agent Bash(git diff *) Bash(git log *) Bash(git show *) Bash(find *) Bash(grep *) Bash(ls *) Bash(wc *) Bash(cat *) Bash(head *) Bash(tail *) Bash(jq *) Bash(date *) Bash(test *) Bash(sort *) Bash(uniq *)
argument-hint: "[--layer <name> | --changed | --full]"
---

# Adversarial Doubt Session

Systematically question whether the second-brain plugin actually works. Start from doubt ("this probably doesn't work"), read the actual code, and prove or disprove each claim with line references.

## Layer Taxonomy

Each layer maps to specific files. Pick layers to doubt based on the selection algorithm below.

| ID | Layer | Key Files |
|----|-------|-----------|
| `hooks` | Hook system | `hooks/hooks.json`, `scripts/ensure-dirs.sh`, `scripts/session-load.sh` |
| `friction` | Friction detection | `scripts/log-friction.sh`, `scripts/smart-context.sh` |
| `drift` | Drift detection | `scripts/drift-detect.sh`, `skills/drift-check/SKILL.md` |
| `learning` | Learning pipeline | `skills/improve/SKILL.md`, `docs/reflection-protocol.md`, `scripts/extract-learnings.sh` |
| `mcp` | MCP server | `mcp/src/server.ts` |
| `feedback` | Knowledge feedback | `mcp/src/server.ts` (updateLearningFeedback tool) |
| `quality` | Quality gate | `scripts/quality-gate.sh`, `agents/quality-reviewer.md` |
| `budget` | Context budget | `scripts/budget-context.sh`, `scripts/session-load.sh` |
| `compact` | Compaction handling | `scripts/pre-compact.sh`, `scripts/post-compact.sh`, `scripts/lib.sh` |
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
{"timestamp":"ISO8601","layers":["hooks","friction"],"perspectives":["failure","race"],"findings":2,"issues":1,"fragile":1}
```

Parse arguments:
- `--layer <name>`: Force a specific layer. Pick the least-used perspective for it.
- `--changed`: Only doubt layers whose files changed recently (`git log --since="30 days ago" --name-only`).
- `--full`: Shallow scan of ALL 12 layers, `correctness` perspective only, 1 question each. Produces a coverage map.
- No args: Use the selection algorithm below.

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
   - Do the output files exist? (`ls ~/.second-brain/`, `ls ~/knowledge/.embeddings/`)
   - What's in the data files? (`tail -5 ~/.second-brain/friction-log.jsonl`, `wc -l ~/.second-brain/drift-log.jsonl`)
   - Is the state consistent with what the code claims to produce?
   - The gap between "the code would write X" and "X actually exists on disk" is where the best bugs hide.
3. **Start from doubt**: "I believe [layer] does NOT work correctly because..." — force yourself to find reasons to doubt.
4. **Drill conversationally** — each answer must spawn the next doubt. Don't ask independent questions. Chain them:
   - Start broad: "This layer doesn't work." → Answer with evidence it does.
   - Counter: "OK, so if it works, then surely the OUTPUT is wrong/incomplete/stale." → Answer with evidence.
   - Dig deeper: "Fine, the output is correct, but on line N this assumes X — what if X isn't true?" → Answer.
   - Keep going until you either find something real or run out of credible doubt.
   The pattern is adversarial dialogue, not a checklist. Each answer closes one doubt but should open a more specific one. Stop when the doubt becomes unreasonable — not after a fixed number of questions. A trivial layer might need 2 exchanges; a complex one might need 10+.
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
Prompt: "Validate these doubt findings independently. For each, read the cited file and line, and classify as CONFIRMED (real issue), DISPUTED (doubt session is wrong), or NEEDS-TESTING (can't tell from code). Be specific about why."
```

Include the finding details, file paths, and line numbers. One subagent call total — bundle all findings together.

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
  --argjson layers '["hooks","friction"]' \
  --argjson perspectives '["failure","race"]' \
  --argjson findings 2 \
  --argjson issues 1 \
  --argjson fragile 1 \
  --argjson confirmed 2 \
  --argjson disputed 0 \
  '{timestamp:$t, layers:$layers, perspectives:$perspectives, findings:$findings, issues:$issues, fragile:$fragile, confirmed:$confirmed, disputed:$disputed}' \
  >> ~/.second-brain/doubt-history.jsonl
```

The `confirmed` and `disputed` counts from the critic gate track calibration over time — a skill that's always disputed is asking bad questions; one that's always confirmed is well-calibrated.

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
- If the skill is running during a session with high compact pressure (check `~/.second-brain/.compact-count`), warn the user and suggest running via `/clear` first.
