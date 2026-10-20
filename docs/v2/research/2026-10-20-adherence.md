# Research: how v2 can make Claude look for and follow a project's knowledge

Question (the user's, 2026-10-20): where knowledge is kept matters less than whether Claude uses it. In the past
Claude ignored rules and documentation, either because it never looked for them or because it had them and did not
apply them. What do the official docs, the Ultimate Guide, our own history and the research literature say about
making Claude follow a project's knowledge, and what does that mean for v2? It feeds a new decision, V2-D20.

Sources:
- [DOCS] Claude Code docs, fetched 2026-10-20: memory (https://code.claude.com/docs/en/memory), hooks
  (https://code.claude.com/docs/en/hooks), skills (https://code.claude.com/docs/en/skills), subagents
  (https://code.claude.com/docs/en/sub-agents), context window and compaction
  (https://code.claude.com/docs/en/context-window), best practices (https://code.claude.com/docs/en/best-practices);
  Anthropic's "Effective context engineering for AI agents"
  (https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) and prompting best practices
  (https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices). Read by
  a subagent through page summaries; quotes are short and should be re-checked before they are relied on.
- [GUIDE] `FlorianBruniaux/claude-code-ultimate-guide` at `e784ef1` (unchanged), read by a subagent as data.
- [V1] our post-mortem ([../02-v1-postmortem.md](../02-v1-postmortem.md),
  [2026-10-19-v1-postmortem.md](2026-10-19-v1-postmortem.md)), v1's local store (1,635 entries, counts only), and
  the two private repos P1 and P2 ([2026-10-20-scale-real-repos.md](2026-10-20-scale-real-repos.md)), shape only.
- [LIT] [2026-10-20-rule-following-literature.md](2026-10-20-rule-following-literature.md): 46 findings from papers,
  vendor evaluations and practitioner posts, numbers not re-checked against the primary texts.

## 1. Both failures are real, and they are different problems

| | (a) Claude never looks | (b) Claude has it and does not apply it |
| --- | --- | --- |
| Literature | Agents opened the repo's policy file in 3.5% of runs, and 97.6% of violations happened with it unopened [LIT 10]; 71.1% never fetched policy documents they were told about [LIT 11]; a skill was auto-invoked in about 56% of runs (already in our notes) | With the policy read, 33-36% still violated [LIT 11]; with it in the system prompt, 25-32% for Sonnet and Opus 4.6 [LIT 15]; the best of 30 configurations kept a long handbook in force in 36% of tasks [LIT 8] |
| v1 and our repos | v1's pushed pointers were opened in 0-4% of cases even when the content was judged good; arrival of its own channel was never proven | A protocol loaded in every session was followed 0 times in 46-78 cases; a written convention was broken again and again and caught only in review; a "do this first" rule did not prevent its failure until it became a code check |
| Docs | Path rules arrive with the first matching Read or Write (D12); Explore and Plan skip `CLAUDE.md`; path rules and nested `CLAUDE.md` are summarised away by compaction and come back only on a new matching read [DOCS context window] | `CLAUDE.md` is "context, not enforced configuration", delivered as a user message after the system prompt, with no guarantee of compliance "especially for vague or conflicting instructions" [DOCS memory] |
| What fixed it | Making it unavoidable: one mounted file was opened in 91.6% of runs [LIT 11]; force-loaded skills beat chosen ones, 55.4 vs 51.2 vs 38.4 when retrieved [LIT 39] | A deterministic check whose failure is fed back: 70.1% compliance vs 55.0% for the same rules as text [LIT 30]; one round of feedback took verification to 90-100% [LIT 29]; a harness block stopped a loop 120 of 120 times [LIT 25] |

Both private repos had already reached the same answer on their own: each turned prose rules into checks that run
after a write (P1: reminders injected after Edit and Write, plus a lint test; P2: four validators after Edit and
Write that exit 2). Neither blocks before a write, both miss writes made through the shell, and both run in about
10 s budgets.

## 2. Why a rule in context is not followed (measured drivers)

- **Too many rules at once.** Compliance with all rules falls as their number grows: Claude Sonnet 4 followed 94.4%
  of 100 simple rules and 77.2% of 250 [LIT 1]; all-of-10 rules followed in about half the runs [LIT 2]; "perfect
  response collapses to zero by N=80" [LIT 3]. P1 delivers 818 list items' worth of rule files; one five-file task
  receives 265 KB.
- **Distance.** A rule's "influence decays with distance: across turns, across tool calls" [LIT 8]; instructions
  spread over turns lose 39% [LIT 7]; restating recovers part of it, not all [LIT 21].
- **The code wins over the text.** When examples in context show a competing pattern, instruction-following drops to
  50% or less after one example; a hint that the pattern conflicts adds 11-14 points [LIT 26]. In A1, the no-memory
  arm copied the fixture's CDN pattern in 10 of 10 runs (D17).
- **The current request wins** over a standing rule [LIT 8], and process rules that nothing rewards are bypassed
  [LIT 16].
- **Vague, conflicting or stale rules:** "Claude may pick one arbitrarily" [DOCS memory]; stale entries anchor
  behaviour [GUIDE memory-systems.md]; v1's store recorded docs contradicting the code (21 of 123 pages with a wrong
  status).
- **Wording:** prohibitions helped where positive directives hurt [LIT 12]; the reason behind a rule helps Claude
  generalise [DOCS prompting]; emphasise one line, not many [DOCS best practices]; current models over-trigger on
  "CRITICAL: You MUST" [DOCS prompting].

## 3. What the platform offers, by strength

| Mechanism | What it guarantees | Source |
| --- | --- | --- |
| `PreToolUse` deny with a reason | The tool call does not run; the reason is shown to Claude before it acts again | [DOCS hooks] |
| `Stop` / `SubagentStop` block | The turn does not end; the reason becomes Claude's next instruction (at most 8 continuations in a row) | [DOCS hooks], [GUIDE hooks-events-reference.md] |
| `PostToolUse` block or exit 2 | Claude sees the reason after the write, which is already on disk | [DOCS hooks] |
| `additionalContext` (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SubagentStart`, `SessionStart`) | Text arrives as a system reminder (next to the prompt or the tool result), at most 10,000 characters inline | [DOCS hooks]; arrival measured in D12 |
| Root `CLAUDE.md`, unscoped rules | Loaded at start, re-read after compaction; adherence not guaranteed | [DOCS memory, context window] |
| Path rules, nested `CLAUDE.md` | Loaded at the first matching file access, summarised away by compaction | [DOCS], D12 |
| Skills | Description listed (1,536 characters each); body only when invoked; after compaction the most recent body per skill is kept, first 5,000 tokens | [DOCS skills, context window] |

Gaps that fail open, from the guide's reference: a timed-out `PreToolUse` hook does not block (unless
`onFailure: "block"`); exit 1 does not block; a missing script silently disables a gate; `prompt` and `agent` hooks
written as instructions used to allow what they should block before v2.1.294 [GUIDE hooks-events-reference.md,
claude-code-releases.md].

## 4. What this points to for v2 (hypotheses for V2-D20)

1. **Sort each piece of knowledge by how it can be held**, because the evidence differs by kind:
   - *checkable* (a script can tell: a folder, a forbidden import, a colour literal, "avatars use `local`"): enforce
     it with a check, not with text alone [LIT 29-31];
   - *judgment* (a design specification, canon consistency, tone): deliver the rule itself at the moment of action
     and make Claude account for it at the end, since no check can decide it [LIT 20, 29: refusal and judgment stay
     low even with feedback];
   - *reference* (vision, lore, background): not delivered as rules; indexed by section and read on demand, with its
     hard rules extracted as cards of the first two kinds.
2. **Deliver the rule's text, not a pointer to it,** few at a time and at the moment it binds: the verbatim clause
   beat a one-line reminder (60-77% vs 31-60%) [LIT 20]; pointers were opened 0-4% in v1. Moments: when the prompt
   arrives; before the first write in an area; into subagents (`SubagentStart`, 3 of 3 in D12); again after
   compaction (`SessionStart` `compact`, 3 of 3). The always-on part stays an index, never the rules themselves.
3. **Make the first write in an area wait for its rules.** `PreToolUse` on Write and Edit denies the first write into
   an area whose rules Claude has not yet received, and the denial's reason carries those rules. That turns D12's
   "arrives with the first Write, too late" into "arrives before it", at the cost of one retried tool call. No study
   measures tool-time delivery [LIT §3], so this is the first thing to probe.
4. **Check, then feed back.** Checkable rules run after each write and at `Stop`; a violation blocks the turn with
   the rule, why it exists and the fix, written for the model [GUIDE ultimate-guide.md: linter messages that carry
   the fix]. Deterministic gates block; model-judged checks only advise [GUIDE spec-first.md, agent-harness.md].
5. **Account at the end for judgment rules.** At `Stop`, Claude names each delivered rule it applied and where it
   came from, or why it does not apply. That is A1's item (5) (sources named), which no arm passed in D17, and it
   leaves a trace a reviewer can read.
6. **Name the counter-pattern.** Where existing code contradicts a rule (P1's legacy files, the fixture's CDN images),
   the rule says which code not to copy and which exemplar to copy [LIT 26].
7. **Learn per rule.** Each rule carries a count of violations caught; a rule that keeps failing as text is promoted
   to a check, and one whose anchors moved is flagged stale (D16) [GUIDE agent-harness.md: turn a recurring
   correction into a lint rule, hook or test].

## 5. Limits

- No controlled study measures rule delivery at tool time, or separates "injected at tool time" from "blocked at
  tool time" [LIT §3]. Items 2 and 3 are untested; they need a probe.
- Selecting only the relevant rules did not beat loading all of them in the one small study (54.0% vs 55.0%,
  29 checks) [LIT 30]; the case for selection here is cost and the rule-count curves, not a measured compliance gain.
- Agents build to the check rather than the intent [LIT 33, 34], so checks cover what can be checked and judgment
  rules still need the accounting in item 5 and human review.
- Every block costs a turn and tokens; hooks must stay within D18's latency budget, and on Windows a hook that times
  out fails open (post-mortem cause 3).
- The v1 store counts come from keyword search and hand classification of LLM-extracted entries (about 1 real record
  in 10 candidates): small numbers, low to moderate confidence.
