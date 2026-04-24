---
name: improve
description: Deep analysis of the current or most recent session. Categorizes signals (positive, negative, neutral), identifies learning opportunities, and proposes improvements to skills, quality rules, and knowledge base entries. Use for manual deep-dive — automatic learning happens via hooks.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(cat *) Bash(grep *) Bash(find *) Bash(ls *) Bash(wc *) Bash(jq *) WebSearch WebFetch mcp__knowledge-base__knowledge_search mcp__knowledge-base__knowledge_index
---

# Deep Session Analysis

Perform a thorough analysis of the current or most recent session to extract actionable learnings.

This skill is for manual deep-dives. Automatic learning happens at session end via the Stop hook.

## Tool Integration

Read ~/.claude-companion/tool-registry.json to discover available tools.
Use any relevant tools to enhance your analysis:
- Documentation tools: verify if tool usage followed current best practices
- Search tools: check if issues are documented with known solutions
- Memory tools: look for patterns across past sessions
- Knowledge search: find related past learnings

## Analysis Process

### 1. Load Context

Read the session metadata:
```bash
cat ~/.claude-companion/.last-session-meta.json
```

Read the signal patterns reference:
```
Read ${CLAUDE_PLUGIN_ROOT}/skills/improve/signal-patterns.md
```

Read current learnings and quality rules:
```bash
cat ~/.claude-companion/learnings.md
cat ~/.claude-companion/quality-rules.md
```

### 2. Read Friction Log

Check what friction was detected during the session:
```bash
cat ~/.claude-companion/friction-log.jsonl | jq '.' | tail -50
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
- **wiki/sessions/**: Create a session insight page in the knowledge base

Update index.md and log.md for any wiki changes.

### 7. Re-index

If wiki pages were created/updated, trigger re-indexing:
```
knowledge_index(force: false)
```
