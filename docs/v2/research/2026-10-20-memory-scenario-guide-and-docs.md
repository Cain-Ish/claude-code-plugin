# Research: the A1 memory scenario against the Ultimate Guide and the official docs

Question: what do the Claude Code Ultimate Guide and the official Claude Code docs say about the user's A1 scenario
(decisions made or read in earlier sessions, kept by Claude's own judgment, recalled in a fresh session), beyond
[2026-10-19-claude-code-ultimate-guide.md](2026-10-19-claude-code-ultimate-guide.md)? It feeds V2-D17 (the eval
plan), V2-D14 (capture) and V2-D13/D18 (recall).

Sources:
- [GUIDE] `FlorianBruniaux/claude-code-ultimate-guide`, shallow clone on 2026-10-20: HEAD `e784ef1`, VERSION 3.44.1,
  the same commit as the earlier note, so nothing changed. Read as data; nothing from it was run. Paths below are
  relative to that repo. Read by a subagent; the claims marked Doc that matter here were checked against [DOCS].
- [DOCS] Claude Code docs, "How Claude remembers your project", https://code.claude.com/docs/en/memory, fetched
  2026-10-20.

Confidence: Doc (official docs, or the guide citing them), Opinion (the guide's recommendation), Inconsistent (the
guide contradicts itself), Unverified.

## 1. Auto memory, the native baseline

- **Claude decides what to keep, unprompted.** "Claude doesn't save something every session. It decides what's worth
  remembering based on whether the information would be useful in a future conversation." Notes have a `type`
  (user, feedback, project, reference). [DOCS] §Auto memory. **Doc.** The guide gives only example contents and
  disagrees with itself on them (`guide/core/glossary.md` "Auto memory" says corrections and preferences;
  `guide/core/memory-systems.md` §2.2 says decisions, patterns and preferences). **Inconsistent.**
- **What loads, and when.** The first 200 lines or 25 KB of `MEMORY.md`, an index with one line per memory, load at
  the start of every session; topic files are read on demand with the normal file tools ("Recalled 2 memories").
  [DOCS]. **Doc.** So recall of a detail depends on the index line pointing at it and on Claude choosing to open the
  topic file.
- **Machine-local.** "Auto memory is machine-local ... Files are not shared across machines or cloud environments."
  [DOCS]. **Doc.** The guide's release notes mention a fix for "mounted team memory stores (`CLAUDE_MEMORY_STORES`)"
  (`guide/core/claude-code-releases.md`, v2.1.172); neither the official memory page nor a web search confirms that
  variable. **Unverified.** If a native team memory appears, it is a reopen event for V2-D11 and the eval's M1 arm.
- **Subagents.** The docs say the main session's auto memory is not loaded into subagents, forks excepted [DOCS].
  The D12 probe saw it reach general-purpose and plugin agents (redirected directory). Already recorded under D12.
- **Where it can live.** `autoMemoryDirectory` is read from any settings scope, project and local included, under
  the workspace-trust rule for hooks. With `permissions.blockReadsOutsideWorkingDirectories` on, a repository-chosen
  directory is neither loaded nor written [DOCS]. **Doc.** This corrects the earlier note's finding 3 ("refused in
  project settings").
- **Off switches:** `autoMemoryEnabled: false` in settings, or `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` [DOCS]. `--bare`
  also skips it, along with hooks, plugins, skills and `CLAUDE.md` (`guide/core/glossary.md` "Bare mode"), so it
  does not isolate memory alone.
- **No provenance.** Memory files carry modified times (v2.1.75, v2.1.214), not a source or author
  (`guide/core/claude-code-releases.md`). **Doc.** A1's item (5), "where each decision came from", is not something
  auto memory records by design.
- **Partly untrusted already.** Since v2.1.284 Claude Code strips invisible characters and imitation markup from
  `MEMORY.md` and recalled notes (`guide/core/claude-code-releases.md`). **Doc.**

## 2. Capture by Claude's own judgment

- **The guide does not settle the user's choice.** It prefers hook capture because "the agent doesn't need to decide
  to remember" (`guide/core/memory-systems.md` §6.1), while A1 needs exactly that judgment. Model judgment inside a
  hook means `type: "prompt"` or `type: "agent"` hooks, or a nested `claude -p`, all spending model tokens outside
  the session (`guide/core/hooks-events-reference.md` "Timeout exceptions"). **Doc + Opinion.**
- **Capture points:** `PreCompact` can block compaction (600 s timeout); `PostCompact` gets the summary; `Stop` gets
  the last assistant message; every event gets `transcript_path` (`guide/core/hooks-events-reference.md`). **Doc.**
- **A second compaction trigger:** since v2.1.299 a conversation over 200K tokens idle for about 54 minutes is
  compacted (`"idleCompaction": false` turns it off). In-session capture races two triggers. **Doc (guide).**
- **External documents:** reading a document is not permission to store it. The guide's "publication contract"
  keeps candidates out of retrieval until reviewed and records source, freshness, audience and contradictions
  (`guide/core/context-engineering.md` §11). It fits the designer's notes in A1. **Opinion.**
- **Provenance is hard to prove:** a content hash proves which text was supplied, not that it occurred in a session;
  in one inspected tool, fabricated evidence was accepted (`docs/resource-evaluations/autoharness-2026.md`).
  **Opinion (chosen reproductions).**

## 3. Recall when the task arrives

- Since v2.1.299, `UserPromptSubmit` hooks see the raw prompt before a skill or slash command expands; their
  `additionalContext` arrives as a system reminder beside the prompt (`guide/ultimate-guide.md` §7.2). **Doc.**
- Silent-unless-relevant patterns: a regex intent gate, and identity re-injection that does nothing when its marker
  is present (§7.5). **Opinion.** No new measurement of recall reliability beyond the earlier note's Vercel and BM25
  figures.

## 4. Evaluating a memory setup

From `guide/roles/agent-evaluation.md`, `guide/core/agent-harness.md`, `guide/core/memory-systems.md` §3.7 and
`guide/ops/ai-unit-economics.md` §6. **Opinion** (citing papers and standard statistics) unless noted.

- Freeze the reference answers and the decision rule before the results; control and record the initial state
  (working tree, fixtures, caches), not only the commit.
- Repeated runs of one task are not independent tasks; replay a scenario 10 to 100 times and gate on the pass rate.
  Not detecting a difference does not show two arms are equal.
- Score each link of the chain apart: present, loaded, used, effect verified. Classify a failure as absent, stale,
  failed loading, misleading retrieval or ignored.
- Pair each test with a permitted neighbour in a fresh session: a case that should recall only part of the
  knowledge, so over-application shows.
- Record the whole model-and-harness pair: in one preprint (2 models x 3 harnesses x 50 tasks) the harness moved
  tokens per solved task up to 40x while pass rates moved 0 to 8 points. **Measured (third-party preprint).**
- Start a new evaluation epoch when the model, the CLI or the harness changes.
- `claude plugin eval` (v2.1.269, `--disallow-tools` since v2.1.299) runs scored eval suites; the guide covers it
  only in release notes. **Doc, not checked against the official docs here.**

## 5. Corrections to the 2026-10-19 note

- Finding 2 and gap 3: hook extraction adds no tokens to the session, but judging what to keep is still a model
  call (the guide's own §6.1 calls it "LLM-based projection").
- Finding 3: `autoMemoryDirectory` is honoured in project and local settings, under workspace trust ([DOCS]).
- §3 "no semantic retrieval": the index loads at start and topic files are read on demand by Claude ([DOCS]); there
  is still no search.
- Finding 20: per-hook timeouts can raise `SessionEnd` to 60 s for non-plugin hooks only; a plugin cannot rely on
  it for capture.
- Finding 25: add `PreCompact` as a capture point and idle compaction as a second trigger.

## For v2

- The eval's M1 arm is the right baseline: the docs describe auto memory as exactly A1's capture (Claude's own
  judgment, no cue) with recall through an index. A1's provenance item and team sharing are what it lacks by design.
- The eval adds a neighbour session and scores the chain (kept, loaded before writing, followed, explained); see
  [05-eval-plan.md](../05-eval-plan.md).
- Capture by Claude's own judgment is the user's choice (V2-D14's user answer); prior research A18 says unprompted
  capture is rare in practice. The eval measures it before any capture design.
