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

### 2. Select 2-3 (layer, perspective) pairs

Score each combination:

1. **Git change bonus (+3)**: Run `git log --since="30 days ago" --name-only --pretty=format:` in the plugin root. Map changed files to layers. Recently changed layers get +3.
2. **History rotation (+days since last doubt)**: For each (layer, perspective), count days since it last appeared in doubt-history.jsonl. Never-doubted pairs get +30.
3. **Pick top 2-3 scoring pairs.** Break ties by picking different perspectives for variety.

Report which pairs were selected and why before proceeding.

### 3. Doubt protocol (for each selected pair)

For each (layer, perspective):

1. **Read all key files** listed in the taxonomy for that layer.
2. **Start from doubt**: "I believe [layer] does NOT work correctly because..." — force yourself to find reasons to doubt.
3. **Ask 3-5 questions**, drilling from general to granular:
   - General: "Does [layer] actually fire/run/produce output in a real session?"
   - Specific: "What happens when [edge case from the perspective]?"
   - Granular: "On line N of file X, this code assumes Y — is that always true?"
4. **Answer each question honestly** by reading the actual code. Cite file:line. No speculation.
5. **Classify each answer**:
   - **VALIDATED**: Works correctly, code proves it
   - **ISSUE**: Real bug or incorrect behavior
   - **FRAGILE**: Works now but would break under reasonable conditions
   - **UNKNOWN**: Can't verify from code alone (needs runtime testing)

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
  '{timestamp:$t, layers:$layers, perspectives:$perspectives, findings:$findings, issues:$issues, fragile:$fragile}' \
  >> ~/.second-brain/doubt-history.jsonl
```

### 7. Integration offers

After the report, offer but do NOT auto-execute:
- "Promote finding #N to a learning via `/second-brain:improve`?"
- "Create a regression probe in `~/.second-brain/regressions/` for finding #N?"
- "Fix finding #N directly?"

## Context Budget

- **2-3 layers per normal run**, not all 12. Each layer reads ~3-5 files of 50-200 lines.
- **`--full` mode**: 1 question per layer, reads only the primary file. Broad coverage map.
- **One quality-reviewer subagent call** total, bundling all ISSUE/FRAGILE findings.
- If the skill is running during a session with high compact pressure (check `~/.second-brain/.compact-count`), warn the user and suggest running via `/clear` first.
