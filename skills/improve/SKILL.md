---
name: improve
description: Deep analysis of the current or most recent session. Categorizes signals (positive, negative, neutral), identifies learning opportunities, and proposes improvements to skills, quality rules, and knowledge base entries. Use for manual deep-dive — automatic learning happens via hooks.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Agent Bash(cat *) Bash(grep *) Bash(find *) Bash(ls *) Bash(wc *) Bash(jq *) Bash(bash *) Bash(git checkout:*) Bash(git add:*) Bash(git commit:*) Bash(git push:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(gh pr create:*) WebSearch WebFetch mcp__knowledge-base__knowledge_search mcp__knowledge-base__knowledge_index mcp__plugin_context7_context7__resolve-library-id mcp__plugin_context7_context7__query-docs
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
**Destination**: [learnings.md / quality-rules.md / wiki/sessions/ / wiki/learnings/]

Pros:
- [benefit 1]
- [benefit 2]

Cons:
- [cost or trade-off]
```

### 5.5. Adversarial critic gate (REQUIRED before any write)

Same-context judge-and-author causes Iterative Self-Refinement Reward Hacking (ICRH) — your scores rise while quality falls. Every proposed learning **must** pass an asymmetric critic before being written.

**Step A — generate candidate framings (you, the author).** For each proposal that passed the balance test in step 4, draft **2–3 candidate framings** of the same learning, varying along these axes:

- **Scope:** narrow ("never use `${user_config.X}` in `hooks.json`") vs broad ("never depend on plugin-option substitution in subprocess command fields")
- **Phrasing:** rule-shaped ("must not...") vs heuristic-shaped ("prefer... because...")
- **Trigger specificity:** when this rule fires (always / only on hook authoring / only on cross-platform code)

The candidates must be genuinely different — not paraphrases. If you can only produce paraphrases, abandon the proposal entirely; do not attempt to write any candidate. Paraphrase-only output is a signal that there's only one real framing of the friction, and the critic gate is wasted on it.

**Step B — critic vote (fresh-context subagent).** Dispatch one subagent per proposal with all candidates bundled together:

```
Use the Agent tool with subagent_type: "second-brain:quality-reviewer"
(or "general-purpose" if the proposal is non-code).

Prompt the critic with ONLY these inputs (no transcript, no friction log):
- The 2–3 candidate framings (labelled A / B / C)
- The destination file (learnings.md / quality-rules.md / persona.md)
- One representative example of the friction they claim to address (anonymized)
- The current contents of the destination file

Ask the critic to:
1. For each candidate, answer independently:
   a. Specific enough to be actionable? (yes/no)
   b. Generalizes beyond the single incident? (yes/no)
   c. Conflicts with anything already in the destination? (yes/no)
   d. Would removing it cause real friction to recur? (yes/no)
2. **Vote:** pick the strongest candidate (A / B / C), or NONE if all fail. **Tiebreak rule:** if two candidates have identical yes/no profiles, pick the one with the narrowest scope. Narrow rules are easier to evict via decay if they stop helping; broad rules accumulate and are hard to remove later.
3. **Confidence score for the winner** (0.3 = borderline / hold inline only, 0.5–0.69 = surface as suggestion, 0.7+ = auto-apply, 0.9+ = strong evidence). Be conservative — most first-time learnings should land 0.4–0.6. Only repeat-evidence learnings deserve 0.8+.
4. **Final verdict on the winner:** ACCEPT / REJECT / REVISE. If REVISE, return the rewritten text.
```

The confidence score gets written into the meta line in step 6. Decay later evicts entries whose confidence stayed low AND went unused.

Only write the winning candidate when the critic returns ACCEPT. If REVISE, apply the critic's rewrite before writing. If REJECT or NONE, drop the entire proposal silently — do not retry within the same session, and do not fall back to a non-winning candidate.

Log every critic verdict (accept/revise/reject + reason) to `~/.second-brain/critic-log.jsonl` so reviewers can audit acceptance rates over time. Use jq to build each line so embedded quotes stay valid JSON:

```bash
jq -nc \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg s "$SESSION_ID" \
  --arg pt "$PROPOSAL_TITLE" \
  --arg d "$DESTINATION" \
  --arg v "$VERDICT" \
  --arg r "$REASON" \
  '{timestamp:$t, session_id:$s, proposal_title:$pt, destination:$d, verdict:$v, reason:$r}' \
  >> ~/.second-brain/critic-log.jsonl
```

### 6. Apply Accepted Proposals

For learnings the user approves AND the critic accepted:

- **learnings.md**: Append under `## [YYYY-MM-DD] Title`, then a meta line `<!-- meta: confidence=0.X hits=0 last_used=YYYY-MM-DD -->` (use the critic's confidence score; hits starts at 0; last_used = today), then a blank line, then the Why section. Format must be exact — `scripts/decay-learnings.sh` parses these fields to decide eviction.
- **quality-rules.md**: Add new bullet under appropriate category
- **persona.md**: Add anti-pattern or learned preference under the appropriate section
- **wiki/sessions/**: Create a session insight page in the knowledge base
- **wiki/learnings/**: For each new entry written to `learnings.md`, also create a wiki mirror at `wiki/learnings/YYYY-MM-DD-short-title.md` with `[[wiki-link]]` cross-references to the entities/concepts it touches and a back-link to the originating session page. This keeps learnings visible as graph nodes in Obsidian.
- **regressions/** (when feasible): For each accepted learning that can be validated with a one-line probe + regex, write a regression file to `~/.second-brain/regressions/<YYYY-MM-DD-slug>.md` with frontmatter:
  ```yaml
  ---
  learning_slug: 2026-04-27-no-filler-phrases
  probe: "Hello, how are you today?"
  expected_pattern: "^(?!.*Certainly!|.*Great question)"
  forbidden_pattern: "Certainly!|Great question"
  ---
  Probe context (optional): anything that grounds the test in a realistic scenario.
  ```
  Skip this when the learning isn't probe-amenable (e.g., subjective architectural rules — those need human review, not regex). Without these files, `/second-brain:regress` has nothing to replay; with them, it can verify the lesson still holds session-over-session.

Update index.md and log.md for any wiki changes.

### 7. Plugin Self-Improvement (Optional)

Check if auto-improve is enabled:
```bash
jq -r '.auto_improve // false' ~/.second-brain/config.json
```

If `false`, skip this step entirely. If `true`, proceed by following the protocol in:

```
${CLAUDE_PLUGIN_ROOT}/scripts/improve-protocol.md
```

That file is the single source of truth for the proposal schema, the evidence
gate, the validators to run, the branch-naming convention (timestamped to avoid
same-day collisions), and the PR body template. Read it first, then execute.

The same protocol fires automatically from `session-load.sh` when
`SUGGEST_PLUGIN_IMPROVE=true` is written into `.pending-reflection.json`.

### 8. Re-index

If wiki pages were created/updated, trigger re-indexing:
```
knowledge_index(force: false)
```
