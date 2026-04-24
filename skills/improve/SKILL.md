---
name: improve
description: Deep analysis of the current or most recent session. Categorizes signals (positive, negative, neutral), identifies learning opportunities, and proposes improvements to skills, quality rules, and knowledge base entries. Use for manual deep-dive — automatic learning happens via hooks.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(cat *) Bash(grep *) Bash(find *) Bash(ls *) Bash(wc *) Bash(jq *) Bash(bash *) Bash(chmod *) Bash(git *) WebSearch WebFetch mcp__knowledge-base__knowledge_search mcp__knowledge-base__knowledge_index mcp__plugin_context7_context7__resolve-library-id mcp__plugin_context7_context7__query-docs
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

If any proposals improve the plugin itself (skills, hooks, scripts, signal patterns, agents),
apply them directly to the plugin source at `${CLAUDE_PLUGIN_ROOT}`.

**Improvement filter — every change MUST pass ALL of these:**
- **FRICTION-DRIVEN**: tied to a real friction signal (user correction, retry, tool failure) — not a stylistic preference
- **RECURRING**: the problem appeared in 2+ sessions or 2+ times in one session — single occurrences are noise
- **MEASURABLE**: you can state what gets better (fewer friction signals, fewer retries, faster completion)
- **SCOPED**: changes one specific behavior — no "while I'm here" cleanup or speculative improvements
- **SAFE**: cannot break existing working behavior — if unsure, skip it

**REJECT changes that are:**
- Cosmetic rewording of skill instructions with no behavioral impact
- Adding error handling for scenarios that haven't actually failed
- Restructuring that doesn't fix a concrete problem
- "Best practice" changes not backed by observed friction

**What can be improved (only if filter passes):**
- Skill instructions (SKILL.md files) — better prompts, missing steps, new tool integrations
- Signal patterns — new positive/negative/drift signals discovered during analysis
- Hook scripts — better friction detection patterns, improved extraction logic
- Agent definitions — refined instructions based on observed behavior
- Validation rules — new checks discovered from failures

**Workflow:**

1. Apply the improvement filter to each candidate. Drop anything that doesn't pass ALL criteria
2. Make the changes to files under `${CLAUDE_PLUGIN_ROOT}`
3. Run validation:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh
   ```
4. If validation fails, fix the issues and re-validate
5. Create a branch and PR:
   ```bash
   cd ${CLAUDE_PLUGIN_ROOT}
   git checkout -b improve/YYYY-MM-DD-short-description
   git add -A
   git commit -m "improve: short description of what changed"
   git push -u origin HEAD
   gh pr create --title "improve: short description" --body "$(cat <<'EOF'
   ## Summary
   - [what changed and why]
   
   ## Filter criteria met
   - [which friction signals drove this change]
   - [recurrence evidence]
   - [what measurably improves]
   
   ## Validation
   - `validate-plugin.sh` passed
   
   ## Source
   Generated by `/second-brain:improve` session analysis.
   EOF
   )"
   ```
6. Write today's date to `~/.second-brain/.last-plugin-improve`
7. Report the PR URL to the user

**Rules:**
- Never modify `plugin.json` version — that's a release concern
- Never modify `hooks.json` structure without validation passing
- Always create a PR — never push directly to main
- Keep changes focused — one PR per improvement area

### 8. Re-index

If wiki pages were created/updated, trigger re-indexing:
```
knowledge_index(force: false)
```
