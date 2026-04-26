---
name: improve
description: Deep analysis of the current or most recent session. Categorizes signals (positive, negative, neutral), identifies learning opportunities, and proposes improvements to skills, quality rules, and knowledge base entries. Use for manual deep-dive — automatic learning happens via hooks.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(cat *) Bash(grep *) Bash(find *) Bash(ls *) Bash(wc *) Bash(jq *) Bash(bash *) Bash(git checkout:*) Bash(git add:*) Bash(git commit:*) Bash(git push:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(gh pr create:*) WebSearch WebFetch mcp__knowledge-base__knowledge_search mcp__knowledge-base__knowledge_index mcp__plugin_context7_context7__resolve-library-id mcp__plugin_context7_context7__query-docs
---

# Deep Session Analysis

Perform a thorough analysis of the current or most recent session to extract actionable learnings.

This skill is for manual deep-dives. Automatic learning happens at session end via the Stop hook.

## Tool Integration

Read ~/.second-brain/tool-registry.json to discover available tools.
Use any relevant tools to enhance your analysis:
- Documentation tools: verify if tool usage followed current best practices
- Search tools: check if issues are documented with known solutions
- Memory tools: look for patterns across past sessions
- Knowledge search: find related past learnings

## Analysis Process

### 1. Load Context

Read the session metadata:
```bash
cat ~/.second-brain/.last-session-meta.json
```

Read the signal patterns reference:
```
Read ${CLAUDE_PLUGIN_ROOT}/skills/improve/signal-patterns.md
```

Read current learnings and quality rules:
```bash
cat ~/.second-brain/learnings.md
cat ~/.second-brain/quality-rules.md
```

### 2. Read Friction Log

Check what friction was detected during the session:
```bash
cat ~/.second-brain/friction-log.jsonl | jq '.' | tail -50
```

### 3. Analyze Signals

Categorize everything observed in the session:

**Negative signals** — what went wrong:
- List each issue with specific examples
- Note the root cause
- Propose a learning to prevent recurrence

**Positive signals** — what worked well:
- Note approaches the user accepted without correction
- Identify patterns worth reinforcing

**Persona drift** — AI tells detected:
- List any filler phrases, over-commenting, or narration patterns
- Note cookie-cutter code or unnecessary abstractions
- Flag any AI attribution in commits or messages

**Neutral signals** — emerging patterns:
- New domains or tools encountered
- Conventions discovered
- Edge cases identified

### 4. Apply Balance Test

For each proposed learning, evaluate:
- **Frequency**: Will this recur? (Single occurrence = noise)
- **Impact**: How much time/friction does it save?
- **Token cost**: How much context does the learning add?
- **Rule**: Only propose if `frequency × impact > token_cost`

### 5. Present Proposals

For each accepted learning, present:

```
## Proposal N: [Title]

**Signal**: [What was observed]
**Root cause**: [Why it happened]
**Proposed learning**: [The actionable rule]
**Destination**: [learnings.md / quality-rules.md / wiki/sessions/]

Pros:
- [benefit 1]
- [benefit 2]

Cons:
- [cost or trade-off]
```

### 6. Apply Accepted Proposals

For learnings the user approves:

- **learnings.md**: Append under `## [YYYY-MM-DD] Title` with Why section
- **quality-rules.md**: Add new bullet under appropriate category
- **persona.md**: Add anti-pattern or learned preference under the appropriate section
- **wiki/sessions/**: Create a session insight page in the knowledge base

Update index.md and log.md for any wiki changes.

### 7. Plugin Self-Improvement (Optional)

Check if auto-improve is enabled:
```bash
jq -r '.auto_improve // false' ~/.second-brain/config.json
```

If `false`, skip this step entirely. If `true`, proceed.

#### 7a. Build a proposal

Before touching any plugin code, write a structured proposal to `~/.second-brain/.improve-proposal.json`.
This is the evidence gate — no proposal, no code changes.

```json
{
  "title": "short description of the improvement",
  "description": "what changes and why — one paragraph max",
  "evidence": [
    {
      "type": "friction|learning|pattern",
      "timestamp": "exact timestamp from friction-log.jsonl or date from learnings.md",
      "session_id": "session where this was observed",
      "signal": "the actual user correction, error, or pattern observed"
    }
  ],
  "changes": [
    {
      "file": "${CLAUDE_PLUGIN_ROOT}/path/to/file",
      "action": "modify|add|delete",
      "description": "what specifically changes in this file"
    }
  ],
  "measurable_impact": "what gets better — be specific (e.g. 'eliminates the retry pattern seen in 3 sessions')",
  "risk_assessment": "what could break — or 'none' with reasoning"
}
```

**Evidence rules:**
- MUST cite 2+ entries from friction-log.jsonl or learnings.md with real timestamps
- Each entry must quote the actual signal (user prompt, error message, or learning text)
- "Could theoretically happen" is not evidence — only cite things that DID happen
- If you cannot find 2+ real citations, STOP — the improvement is not justified

**Reject the proposal yourself if ANY of these apply:**
- The change is cosmetic rewording with no behavioral impact
- You're adding error handling for scenarios that haven't actually failed
- You're restructuring code that isn't causing friction
- The improvement is a "best practice" not backed by observed problems
- You can't point to a specific user correction or tool failure that triggered it

#### 7b. Validate the proposal

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-proposal.sh
```

This script checks:
- Proposal JSON is well-formed with all required fields
- Evidence entries have timestamps and at least 2 exist (proving recurrence)
- Cited timestamps exist in the friction log
- All target files are inside `${CLAUDE_PLUGIN_ROOT}` (can't modify other plugins)
- No version field modifications attempted

If validation fails, either fix the proposal or abandon — don't force it through.

#### 7c. Apply changes and create PR

Only after proposal validation passes:

1. Make the changes to files under `${CLAUDE_PLUGIN_ROOT}`
2. Validate the plugin itself:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh
   ```
3. If plugin validation fails, fix issues and re-validate
4. Create a branch and PR:
   ```bash
   cd ${CLAUDE_PLUGIN_ROOT}
   git checkout -b improve/YYYY-MM-DD-short-description
   git add -A
   git commit -m "improve: short description of what changed"
   git push -u origin HEAD
   ```
5. Create the PR with evidence in the body — read the proposal file and include
   the evidence entries directly so the reviewer can verify:
   ```bash
   gh pr create --title "improve: short description" --body "$(cat <<'EOF'
   ## Summary
   [title and description from proposal]

   ## Evidence (from friction log / learnings)
   [paste each evidence entry: timestamp, session, signal quote]

   ## Changes
   [list each file changed and what was modified]

   ## Impact
   [measurable_impact from proposal]

   ## Risk
   [risk_assessment from proposal]

   ## Validation
   - `validate-proposal.sh` passed
   - `validate-plugin.sh` passed
   EOF
   )"
   ```
6. Clean up: `rm ~/.second-brain/.improve-proposal.json`
7. Write today's date to `~/.second-brain/.last-plugin-improve`
8. Report the PR URL to the user

**Rules:**
- Never modify `plugin.json` version — that's a release concern
- Never modify `hooks.json` structure without validation passing
- Always create a PR — never push directly to main
- Keep changes focused — one PR per improvement area
- If proposal validation fails, do NOT create a PR — report why and stop

### 8. Re-index

If wiki pages were created/updated, trigger re-indexing:
```
knowledge_index(force: false)
```
