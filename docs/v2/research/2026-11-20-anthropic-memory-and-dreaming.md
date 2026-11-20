# Anthropic's memory and dreaming talk, mapped onto v2

**Asked by the user (2026-11-20):** research the talk in [this video](https://www.youtube.com/watch?v=xo5D6TOgbs0) and
the work around it, read what the plugin does, and list what the talk is about, what the plugin does, and what to
improve or add. The weight is on the store, memory, dreaming, and how the talk says to organise a project's knowledge
for Claude (files, folders, indexes).

**How to read this note.**
- Every candidate in sections 6 and 7 is a candidate, not a decision.
- Each names the locked decision it touches, whether a reopen trigger has fired, who decides, and the smallest check
  that could fail. Under `01-process.md` rule 3, nothing here reopens a decision on its own.
- The talk is paraphrased from its transcript, not quoted.
- Documentation is quoted only where the text was fetched word for word.
- Items that came from the Antigravity CLI (agy, Gemini 4 Argon) are marked as such. Only what an abstract confirmed
  is kept.

## 1. The talk

- **What is published.** The video is a re-upload by a third-party channel (dated 2026-09-25). Its description is
  generic and does not match the talk. The talk itself is a session on context engineering, memory and "dreaming",
  given by Lamis, a member of technical staff on Anthropic's Applied AI team. The transcript gives the first name
  only.
- **The event.** AI Native DevCon, London, 2026. It is named in secondary sources:
  - [Tessl's registry of the conference's sessions](https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/files/talk-lamis-context-engineering-dreaming/transcript.md);
  - [The New Stack, 2026-08-12](https://thenewstack.io/anthropic-agent-memory-dreaming/).
- **A related session.** Anthropic gave one at Code w/ Claude 2026,
  ["Memory and dreaming for self-learning agents"](https://claude.com/code-with-claude/session/sf-memory-and-dreaming-for-self-learning-agents).
  Its page holds only the abstract: memory architectures for Managed Agents, and dreaming that verifies and enriches
  memory between sessions.
- **The talk's arc:**
  - a recap of a year of context engineering at Anthropic;
  - the current state of the art for memory;
  - what it takes to run memory in production;
  - dreaming, as a step toward continual learning;
  - a Q&A.

## 2. Where a project's knowledge lives: Anthropic's layout next to the plugin's

The user asked specifically which files and folders hold what. Anthropic's guidance is spread over the talk and five
documents. This table puts it in one place.

| Kind of knowledge | Anthropic's recommended home | When Claude sees it | What the plugin does |
|---|---|---|---|
| Project instructions every session needs: test and build commands, code that misleads, decisions not in the repo, anything corrected twice | `CLAUDE.md` under 200 lines, committed. Personal parts go in `CLAUDE.local.md` ([best practices](https://code.claude.com/docs/en/best-practices), [memory](https://code.claude.com/docs/en/memory)) | At session start | Leaves `CLAUDE.md` to the project and only lists it in the index. **This differs from Anthropic's advice:** decisions made in sessions go to `.project-map/captured.md`, not to `CLAUDE.md`. There they stay labelled until committed (D14), and they are not always-on |
| Rules for one area of the code | `.claude/rules/*.md` with `paths:` front matter | When Claude reads, writes or edits a matching file | Leaves the root `.claude/rules/*.md` out of its index, since Claude Code delivers them (D22's 17m, 06's 2k). D14 rejected a map under `.claude/`: the folder is write-protected, so every capture would prompt |
| Procedures and team workflows | Skills, `.claude/skills/<name>/SKILL.md` ([skill authoring](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)): the description says what the skill does and when to use it; the body is under 500 lines; reference files sit one level deep; long files get a table of contents; file names say what they hold | The description always; the body on use | Ships no skills. A repo's skill files are listed in the index like any other document |
| Docs, specs, ADRs, design documents | Files in the repo, loaded just in time through lightweight identifiers such as paths. Folder hierarchy, naming and timestamps are the signals ([context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)) | On demand | Listed by directory in the session-start index, followed by the forced yes/no per directory (D22) |
| What the agent learned and wrote down | A memory folder: one index file (Claude Code's `MEMORY.md`, 200 lines or 25 KB; the cookbook's `_index.md`, one line per file) plus small topic files named so that grep and glob find them | The index at start, topic files on demand | **One file**, `.project-map/captured.md`, listed by the index. No index inside the map and no topic files |
| Reference material and writable memory | Separate stores. Reference stores are read-only, partly as a defence against prompt injection ([Managed Agents memory](https://platform.claude.com/docs/en/managed-agents/memory)) | Mounted | Separated by labels, not enforced: committed entries are reviewed, uncommitted ones are labelled "unreviewed" |
| One person's preferences | Auto memory (machine-local) or `CLAUDE.local.md` | At start | Left to auto memory (D10). Since 2.2.0, the capture instruction sends project decisions to the map instead (06, 2s; G4) |
| Consolidated or curated memory | A Dreams output store, reviewed and then attached ([Dreams](https://platform.claude.com/docs/en/managed-agents/dreams)). For auto memory there is Claude Code's Auto-dream: it runs in the background and is toggled in `/memory`, with no manual `/dream` command since a 2026 release. The source is a Claude Code collaborator on [issue #39135](https://github.com/anthropics/claude-code/issues/39135), 2026-08-19; it is not on the memory page as fetched 2026-11-20 | Between sessions | **None in v2.** v1 had one (topic T16) |

## 3. Every topic of the talk, mapped to the plugin

The status column reads: done, partial, gap, or not applicable.

| # | What the talk says | What the plugin does today | Status |
|---|---|---|---|
| T1 | **Why context engineering.** New models are smarter, but intelligence does not compound inside an organisation without its context. Three problems: agents do not know their way around a codebase, do not know preferences, and do not get better the second time they do a task | The charter's problem statement is the same. A repo's knowledge comes through the index and the map; personal preferences are left to auto memory (D10). A mistake is kept only when someone states a rule about it | Partial: there is no learning from repeated mistakes |
| T2 | **CLAUDE.md.** A short Markdown file injected at session start steered the agent far better than expected. Humans and the agent can both read and write it. The problem is bloat as it grows | A plugin cannot ship a loaded `CLAUDE.md` ([platform channels](2026-10-19-platform-memory-channels.md), §1), so the plugin adds its own always-on text. Measured from `plugin/scripts/map.mjs` on 2026-11-20: the capture instruction is 1,349 bytes (904 before 2.2.0); the index header 143 bytes plus 2 to 6 KB of index; the naming line 304 bytes; the forced decision 227 bytes. The session-start text is capped at 10,000 characters and cut at a directory, with the map folder's line kept first (`map.mjs:142-157`) | Done (bounded); D22's size triggers watch it |
| T3 | **The memory tool.** The agent decides for itself when to read, write and update memory, within the session. Autonomy worked, and Anthropic has since stopped prescribing what memory tools must look like | Capture is Claude's own judgment under one instruction (`map.mjs:12-30`; D14, the user's answer of 2026-10-20). There is no memory tool and no MCP server: Claude uses its own Read, Edit, Grep and Bash (D18) | Done |
| T4 | **Skills and progressive disclosure.** The agent reads only a skill's front matter until the skill is needed, so its body can be as detailed as necessary. The analogy is a bookshelf: scan the titles, take down the book that bears on the conversation. The bottleneck: people still decide what becomes a skill | The document index is the bookshelf: file names grouped by directory (`map.mjs:113-137`). The forced yes/no per directory (`map.mjs:37`) is the scan of the titles, and bodies are read on demand. **Unlike skills, the index carries no description per file.** In the field, file names did not show which document binds a task (G3; D22's scope probe), and the `when:` field of captured entries is never surfaced (#115 Fog, 2026-11-03) | Partial |
| T5 | **Memory as a file system**, which the talk calls the current state of the art. Plain Markdown; agents search it with ordinary bash and grep; an index makes search fast; memory is allowed to grow large; the agent writes autonomously | `.project-map/*.md` are plain files in the repo (D11, D13), listed by the index. Claude searches them with its own tools; in the field, 9 map reads went through Bash ([04](../04-architecture.md), known weaknesses). But the capture instruction routes every entry into **one file**, `captured.md` (`map.mjs:14`). It grows: 21 entries in a week in one field repo (#115 Fog), and 67 in the field corpus of 2026-11-18. There are no topic files and no index inside the map | Format: done. "Grow large, with an index": gap |
| T6 | **Production problem: many agents writing at once** | Each worktree has its own working tree. Claude Code's Edit tool refuses to edit a file that changed since it was read, which is in effect the talk's hash check. That is behaviour seen in sessions, **not checked against Claude Code's docs**. A Bash append (`>>`) skips that check. Across branches, a single file that every session appends to is where merge conflicts land | Partial; the Edit check is unverified |
| T7 | **Production problem: one agent writes something wrong into context every agent reads** | An entry HEAD does not hold is labelled "unreviewed, not yet committed" on every path the hooks see (D14, D18). The commit's review is the review. Reads by subagents, the Grep tool and scripts stay unlabelled: an accepted risk ([04](../04-architecture.md)) | Done, with accepted risks |
| T8 | **Production problem: people and agents editing the same memory** | `git log` and `git blame`, plus each entry's `- source:` line (who stated it, and the date) | Done |
| T9 | **Production problem: memory goes stale, was wrong, or was injected** | D16 re-finds an entry's quote in the file its source names, at read time. D28 adds status lines (superseded, narrowed, expired, done). An entry that quotes a person carries only "unverified quote, captured <date>", and nothing re-checks it. On injection, D14's probe saw an injected rule captured in 1 of 3 runs; it stays labelled until someone commits it | Partial |
| T10 | **Principle: versioning.** Keep versions so a bad update can be rolled back; record which session or transcript led to an update, and who made it | Git holds the versions and the rollback; the source line holds who and when. A link to the session is deliberately absent: the capture instruction bans session ids. The reason given here is this note's inference, not the record's: a map can sit in a public repo | Done by git; the session link is left out on purpose |
| T11 | **Principle: concurrency.** Take a hash before drafting an edit and again before writing it; on a mismatch, re-read and redraft | As T6 | Partial, unverified |
| T12 | **Principle: permissions.** Tiers run from organisation-wide knowledge, which agents should only read, down to an agent's own scratchpad, which it may write | The plugin has tiers as labels, not enforcement: project documents are the people's source; committed map entries are reviewed; uncommitted entries are not; auto memory is personal. Nothing stops Claude editing a project document. In the D20 probe it edited a P2 canon document unasked in 2 of 5 runs (#115 Fog) | Partial, by the user's D14 answer (the commit review is the review) |
| T13 | **Principle: portability.** Curated memory is worth a lot, so keep it behind a clean interface that several products and systems can reach | Plain Markdown in git, readable and correctable with the plugin off (PM4). The labels and the index exist only inside Claude Code | Done |
| T14 | **The claimed results.** The second time an agent does a task it does it better, and the gain carries over to fewer tokens and faster one-shot runs | A1: the plugin kept the designer's document in 10 of 10 runs against native's 2, and followed it in 10 against 0. Tokens and steps were **the same as native, not fewer** ([charter](../00-charter.md), 2026-10-25) | Accuracy shown on A1; the cost claim is not met |
| T15 | **The limit of in-band memory.** An agent asked to do a task and curate memory at once has to split its effort between them. It also sees only its own session: it cannot see a mistake repeated across sessions, or what other agents run into | The plugin is purely in-band. Field misses of that kind: 3 project decisions kept only in auto memory (G4, [rethink of 2026-11-18](2026-11-18-field-checkup-rethink.md)); an option Claude offered, captured as the owner's own words (#115 Fog, 2026-10-29) | Gap |
| T16 | **Dreaming.** A second-order process over memory. It runs out of band, in batches and asynchronously, with its own budget. Inputs are a memory store and a set of transcripts, including tool calls and metadata. An orchestrator sends subagents through the transcripts, keeps the patterns that are common enough, and proposes changes one by one. Each proposal comes with example transcripts, prevalence stats and a reason, and a person accepts or rejects it. The process can be steered. It merges duplicates, drops what is stale, adds what is missing and reorganises. The talk's examples: a topic missing from the curriculum; a tool configured wrongly every time; a style rule for the whole fleet | **Nothing in v2.** v1 built this design at `v1-final`: `plugin/skills/dream/SKILL.md` (described there as an equivalent of Anthropic's Dreams API, run locally), `plugin/agents/dream-runner.md`, snapshot, diff, accept and discard scripts, a FORGET phase, and a session-start banner after 10 new transcripts (`dream-autostage.sh`). It copied transcripts into a per-dream folder of a machine-local store. v1's consolidation came to 4,452 product lines ([v1 post-mortem research](2026-10-19-v1-postmortem.md), §2.5). It staged its changes for review, so the review step the talk describes was not what v1 lacked. What sank it was RC1 (never measured against an outcome) and RC4 (machine-local, one person's transcripts). D14 rejected (f), an explicit capture command, and (g), mining raw transcripts, the latter after v1's cause 5. The charter's non-goals include "a transcript archive" and "a background process that rewrites knowledge without a reviewable diff" | Gap, on purpose |
| T17 | **Steering.** Whoever builds the memory and dreaming agents can tell them what matters in this organisation and what does not | One frozen, generic capture instruction. A project's areas are its own (D10), but a project has nowhere to say what it wants kept | Partial |
| T18 | **Not only for code.** The speaker also uses memory for slide decks: over time it learns how the speaker writes and lays out slides | Any project and any stack; the areas are the project's own, such as canon or brand (D10). Only A1's product-team scenario is measured (#115 Fog) | Done in scope; unmeasured outside A1 |
| T19 | **Do the simple thing that works.** From the Q&A on "reinventing databases": once a primitive has proved itself, codify it deterministically in the harness, and leave autonomy where judgment is needed | Hooks are deterministic: no model, no network, one git call at session start, at most 100 ms of added p95 (D18). Capture and selection are left to Claude's judgment | Done |
| T20 | **Q&A: an enterprise memory store.** The speaker pointed to the memory and dreaming APIs of Claude Managed Agents, which include versioning and hashing | Claude Code only. A managed store is outside D18 (no network, no model in hooks) and PM4 | Not applicable |
| T21 | **Q&A: permissions for dreaming.** A dream reads only the transcripts it is given, so give it the ones whose permissions match the memory store | Not applicable today. A constraint on any dream (candidate A-1): only this repo's sessions, and nothing private in the map files | A constraint for A-1 |

## 4. What the plugin does today

Read on `v2` at `8de667f` (release 2.2.0).

- **Surface** (`plugin/hooks/hooks.json`):
  - `SessionStart` on startup, clear, resume and compact;
  - `UserPromptSubmit`;
  - `PostToolUse` on Read, and on Bash when the command names the map folder (`if: Bash(*.project-map*)`);
  - `PostToolUseFailure` on Bash.

  Besides the hooks, one command, `/onboard` (`plugin/commands/onboard.md`), and no agents, skills or MCP server.
- **Session start** (`plugin/scripts/hook.mjs:17-24`, `map.mjs:113-157`):
  - one `git ls-files` call lists the tracked documents (`.md`, `.mdx`, `.markdown`, `.txt`, `.rst`), plus the map's
    uncommitted files, grouped by directory;
  - the root's `.claude/rules/*.md` are left out, since Claude Code delivers them;
  - Vercel's retrieval-led header line goes first;
  - the capture instruction and the naming line (D23) are added;
  - the text is capped at 10,000 characters;
  - an epoch marker is written to the OS temp folder.
- **The first typed prompt of each epoch** (`hook.mjs:25-28`, `map.mjs:37`). It gets the forced decision: yes or no
  per directory, then read the yes ones before changing anything. A subagent's report and another session's message
  are skipped.
- **A read of a map file**, by Read or by a Bash command (`hook.mjs:29-66`, `map.mjs:224-290`). It gets labels in
  file order:
  1. "unreviewed, not yet committed" when HEAD does not hold the entry word for word;
  2. the head of the entry's status line (D28);
  3. the quote re-found in the file its source names (D16), "not found word for word in <path>", or "unverified
     quote, captured <date>" for any other source;
  4. "cannot read <path>" when the source exists but cannot be read.

  Committed entries labelled only "unverified" are grouped into one line (2.0.1). Past the cap, and on any error,
  the labels fail closed.
- **The entry format** (`map.mjs:19-27`):

  ```
  ### <the part of the project it governs>
  > <the decision, rule or requirement, in the words used>

  - source: <who stated it, or the document's title or path>, <YYYY-MM-DD>
  - when: ["<kind of work it applies to>", "..."]
  - status: <superseded|narrowed|expired|done> <YYYY-MM-DD> by "<new heading>": <what still holds>
  ```

  Every entry goes into `.project-map/captured.md`.
- **Tests:** `plugin/test/selftest.mjs` (732 lines), plus smoke, bench and live scripts.

## 5. Related research, new since the notes of 2026-10-19

- **[Managed Agents memory stores](https://platform.claude.com/docs/en/managed-agents/memory)** (beta). This is the
  production design the talk describes.
  - *How a store reaches the agent:* it mounts as a directory, and its description and per-session instructions (at
    most 4,096 characters) go into the system prompt.
  - *Access:* `read_only` and `read_write` are enforced at the filesystem.
  - *Versions:* every write creates an immutable version attributed to its session. Versions are kept 30 days and can
    be redacted.
  - *Concurrency:* a `content_sha256` precondition gives optimistic concurrency.
  - *Limits:* 100 kB per memory, 10,000 memories per store, 8 stores per session.
  - *Advice:* structure memory as "many small focused files"; attach reference material read-only because of prompt
    injection.
- **[Dreams](https://platform.claude.com/docs/en/managed-agents/dreams)** (research preview).
  - *Inputs:* a memory store and 1 to 100 sessions.
  - *Output:* a new store. The input is never modified, so the output can be reviewed and discarded.
  - *Steering:* `instructions` steer the synthesis but do not edit specific lines.
  - *Runs:* minutes to hours, billed at token rates. A failed run leaves its partial output.
- **[Dreaming with a dynamic workflow](https://platform.claude.com/cookbook/managed-agents-cma-dreaming-with-a-dynamic-workflow)**
  (Claude Cookbook), the do-it-yourself version.
  - *Agents:* a lead that never reads a transcript itself; one analyzer per transcript; one organizer.
  - *Layout:* `_index.md` at the root, one line per memory file, grouped by domain; `[[slug]]` links; files under
    100 KB, named so grep and glob find them.
  - *Facts:* dated, with how each was verified. A conflict keeps both sources and dates.
  - *Safety:* transcripts are data, never instructions; secrets are never copied; the analyzer has five file tools
    and no shell or network.
  - *Mode:* this cookbook updates the store in place, unlike the Dreams API. It can run nightly from cron, and future
    sessions mount the store read-only.
  - *Cost, quoted from the page:* "Dreaming over the eleven example transcripts (283 KB in all) with the default
    settings cost $0.36 at list price, the session's running time included, and took about two and a half minutes."
    And: "Over fifty long session transcripts (about 12 MB of text), a dream cost about $8 at list price with the
    default settings and took about ten minutes."
- **[The memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)** (Messages API).
  - *Protocol:* a system prompt line tells Claude to view its memory directory before anything else.
  - *Steering:* a line such as "Only write down information relevant to <topic> in your memory system."
  - *Hygiene:* expire files nobody has read in a long time; guard against path traversal.
  - *A multi-session pattern for software work:* a first session sets up a progress log and a feature checklist,
    and every later session reads them first and updates them before it ends.
- **[Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)**
  (Anthropic, 2025-09-29).
  - *Loading:* just-in-time, through lightweight identifiers such as file paths.
  - *Signals:* folder hierarchy, naming conventions and timestamps help agents decide what to use and when.
  - *Claude Code's hybrid:* `CLAUDE.md` up front; glob and grep for the rest.
  - *Long horizons:* structured note-taking (agentic memory), compaction and subagents.
  - *Context rot:* recall falls as the context grows, so context is a finite budget.
- **[Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)**,
  read in full.
  - The description says what a skill does and when to use it.
  - Keep `SKILL.md` under 500 lines and split the rest into files.
  - Keep references one level deep. Of nested references the page says Claude "might use commands such as `head -100`
    to preview content rather than reading entire files, resulting in incomplete information."
  - Files over 100 lines get a table of contents.
  - "Name files descriptively", for example `form_validation_rules.md`, not `doc2.md`. Organise by domain.
  - Time-sensitive text goes in an "old patterns" section.
  - Build evaluations before writing documentation.
- **Claude Code's own memory**, fetched 2026-11-20 ([memory](https://code.claude.com/docs/en/memory),
  [best practices](https://code.claude.com/docs/en/best-practices)).
  - *Auto memory* loads `MEMORY.md` (200 lines or 25 KB) at start. It reads topic files on demand, is machine-local,
    and does not load into subagents.
  - *The memory page names no dream or consolidation feature.* Auto-dream exists all the same. Per a Claude Code
    collaborator's comment on [issue #39135](https://github.com/anthropics/claude-code/issues/39135) (2026-08-19),
    `/memory` shows "Auto-dream: on", consolidation runs in the background, and there is no manual `/dream` command.
    Its internals are known only from community reverse-engineering
    ([guide note](2026-10-19-claude-code-ultimate-guide.md), finding 4).
  - *Auto-dream works on auto memory only,* never on a repo's files.
  - *The best-practices page* says `CLAUDE.md` should hold decisions that are not in the repo, code that misleads, and
    anything Claude had to be corrected on twice. Its test for a line, paraphrased: could Claude find this in the code,
    and would it go and look? A rule that cannot have exceptions belongs in a hook.
  - *Team memory:* a team-memory folder gated to remote sessions appears only in community sources, so it is
    unverified. A documented native format for a project's shared memory would fire D13's trigger.
- **Critique: [The New Stack, 2026-08-12](https://thenewstack.io/anthropic-agent-memory-dreaming/)**, commentators on
  the talk, paraphrased:
  - human review of proposed diffs becomes a rubber stamp at scale;
  - a bad memory becomes standing policy, and a poisoned one persists;
  - dreaming costs a second pass on top of the work;
  - proposals drawn from recent batches pull the store toward whatever happened lately;
  - versioning records what changed, not what has stopped being true;
  - transcripts are full of text the agent did not write;
  - each proposed memory should carry its provenance, its evidence and a condition for when it expires.
- **Papers.** agy named these four. Each was checked against its arXiv abstract; agy's figures were not in the
  abstracts and are left out.
  - [MemDev-Bench](https://arxiv.org/abs/2610.27524) (2026-10). Memory helps code agents localise and edit. It also
    makes them fail tasks they could otherwise solve, mainly by reusing memory without re-checking that it applies.
    Raw past trajectories cut more steps than compressed memories, because compression drops process information.
  - [The Compliance Trap](https://arxiv.org/abs/2607.10608) (2026-07). Agents adopt conflicting memory at the first
    decision point even when it is wrong for the task. After that their success collapses, and stronger agents lose
    more.
  - [MemoryDojo](https://arxiv.org/abs/2611.09721) (2026-11). 155 multi-session trajectories, five memory systems:
    all are open to poisoning that travels through memory.
  - [SWE-ContextBench](https://arxiv.org/abs/2602.08316) (2026-02). Accurately summarised and retrieved past
    experience raises accuracy and cuts runtime and tokens. Unfiltered or wrongly chosen context gives little or
    negative benefit.
- **Already in [prior research](2026-10-19-prior-research-and-sota.md)**, not repeated here: ACE, ReasoningBank,
  Agent Workflow Memory, sleep-time compute, Letta, mem0's move to add-only, Zep, Copilot Memory, MINJA, and A35
  (consolidation as a delayed poisoning substrate).

## 6. Candidates: what to improve

Each candidate gives the talk topics it serves, the change, the decisions it touches and their trigger state, the
native option where one exists, the decider, and the smallest check.

**I-1. A one-line description for each indexed document** (T4).
- *Change:* take it from the document's own front matter (`description:`) or its first heading, as a skill's
  description works.
- *Touches:* D22's index format and D18's always-on bytes.
  - *This note's estimate:* P2's index is 6.1 KB for 190 documents, so about 50 characters each adds about 9.5 KB.
    That passes the 10,000-character cap.
  - *No trigger fired.* G3's trigger (a P2-cell check against `2.1.0`) concerns the forced decision's text, not the
    index format.
  - *The nearest D22 trigger:* "most of a project's binding documents declare their scope in a form a hook can read",
    which reruns (S-b).
- *Native option:* none. Claude Code lists skills by description, not documents.
- *Decider:* the user opens it; evidence settles it.
- *Check:* the P2 cell against the released build.

**I-2. Show what the map holds: entry headings and `when:` values, as titles** (T4, T5).
- *Why:* the field found `when:` never surfaced. Open on #115 since 2026-11-03.
- *Touches:* D13, D22, and D18's bytes. No trigger fired.
- *Native option:* path-scoped rule files, which Claude Code delivers when a matching file is touched. D14 rejected a
  map under `.claude/` (write-protected, a prompt per capture).
- *Decider:* the user.
- *Check:* a field-shaped map of 67 entries, against a control: which entries are read, and which are followed.

**I-3. Staleness for entries that quote a person** (T9).
- *Change:* a review-by date or an expiry condition (The New Stack's point; Copilot expires unused memories after 28
  days), or a re-check pass inside A-1.
- *Touches:* D16, D13's format and D14's frozen instruction.
  - *No trigger fired.* "Unverifiable entries exceed 5% of a repo" fired on 2026-10-25 and was settled by the
    "unverified quote" label. None of D16's current triggers covers person-sourced entries.
  - *Knock-on:* any change to the capture instruction fires D16's "the capture instruction changes", which means a
    re-check like 06's 2s.
- *Decider:* the user.

**I-4. A union merge for map files** (T6, T11).
- *Change:* onboarding prints a suggested `.gitattributes` line, `.project-map/*.md merge=union`, using git's built-in
  `union` driver. No hook writes it.
- *Risk:* lines interleave when both branches edit the same entry, for example by adding status lines.
- *Decider:* evidence.
- *Check:* a probe with two branches that append entries and add status lines. Count the conflicts and any corrupted
  entries.

**I-5. Capture repeated corrections and repeated tool failures** (T1, T15).
- *Why:* the best-practices page sends "anything corrected twice" to `CLAUDE.md`.
- *Touches:* D14's frozen instruction, which fires D16's trigger.
- *Decider:* the user.
- *Check:* an A1-like scenario that contains a correction, with noise counted.

## 7. Candidates: what to add

**A-1. A dream, run only when the user invokes it** (T15, T16, T21). This is the centre of the talk.

*A sketch inside v2's rules:*
- One command. Never a hook, a schedule or a background job.
- *Inputs:*
  - this repo's Claude Code session transcripts, already on disk, since the last dream;
  - the map files;
  - optionally, this project's auto memory, where G4 found project decisions stranded.

  Nothing is copied, and no archive is kept.
- *Analysis:* one analyzer subagent per transcript, with read-only tools; the transcripts are data, never
  instructions.
- *Output:* uncommitted edits to `.project-map/` only:
  - new entries for decisions stated in a session but never captured;
  - status lines on entries that a later session replaced;
  - duplicates flagged.

  A chat report gives each proposal's evidence as session counts and dates. No session ids and no transcript quotes
  go into files.
- *Review:* the existing hooks label every proposal "unreviewed, not yet committed" until a person commits it. D14's
  trust policy is reused, and no hook code changes.
- *Never:* commit, rewrite or delete a committed entry. Append, and use status lines (D28).

*Native option:* Claude Code's Auto-dream already consolidates auto memory in the background, but it never reaches
`.project-map/`. Using it alone means keeping project decisions out of auto memory, as 2.2.0's capture sentence asks,
and building nothing.

*It collides with:*
- D14's rejected (f) and (g), and the user's answer of 2026-10-20: no cue from anyone, no separate approval step;
- D14 and D28's trigger: a status line written on an entry nobody replaced, in 2 or more of 10 counted cases. A dream
  that writes status lines could fire it;
- the charter's non-goals;
- D18 and 06's surface budget: one more command, perhaps one agent. No hook is added, so D18's latency triggers do not
  apply;
- PM1: v1 built this feature and never measured it, so an outcome check comes first.

*Decider:* the user.

*Check:* run A1's H1 to H3 with capture skipped, then run a dream over their transcripts. Measure:
- C1 to C3 recovered, against the capture arm;
- noise kept;
- status lines written on entries nobody replaced;
- whether an injected tool output reaches the map without the unreviewed label;
- the usage it costs.

**A-2. The map as an index plus topic files**, in place of one `captured.md` (T5, T6).
- *Sources:* Managed Agents' "many small focused files"; the cookbook's `_index.md`; the skill rules (one level deep,
  descriptive names); auto memory's `MEMORY.md` plus topic files.
- *Gains:*
  - each read and its labels are smaller;
  - fewer merge conflicts;
  - the file names act as titles in the index.
- *Cost:* the hooks already list and label many map files. The change is mainly D14's frozen instruction and D13's
  shape, and it fires D16's "the capture instruction changes".
- *Native shape:* auto memory uses the same shape, but it is personal and machine-local (D10).
- *Decider:* the user, then evidence.
- *Check:* A1, plus the 67-entry map split by area, against a control: tokens read and rules followed.

**A-3. A steering note the project owns** (T17).
- *Change:* a short file in the map folder saying which areas this project keeps (canon, brand, engineering), so that
  capture, and any dream, weigh what they keep by it.
- *Sources:* the memory tool's "Only write down information relevant to <topic>"; the Dreams API's `instructions`.
- *Touches:* D10 and D13 (how a project declares its areas), and D14.
- *Decider:* the user.

**A-4. An eval cell for the talk's result claim** (T14).
- *Change:* the same kind of task in a later session, after a correction. Does v2 one-shot it, and with fewer tokens?
- *Touches:* D17.
- *Decider:* evidence. It runs only when the user asks (D24's rule).

## 8. Not taken from the talk

- **Automatic or scheduled dreaming** (cron, idle triggers, a "time to dream" banner). It is a charter non-goal, and
  v1's banner already existed.
- **Rewriting or deleting committed entries in place.**
  - ACE names context collapse from iterative rewriting.
  - mem0 moved to add-only.
  - The cookbook keeps every fact line.
  - v2's form is D28's status line.
- **A managed store or API as a dependency:** D18 rules out network and model calls in hooks, and PM4 wants plain
  files.
- **Session ids or transcript links in entries:** the capture instruction bans them, and a map can sit in a public
  repo.
- **Enforced permissions:** under the user's D14 answer, the commit's review is the review.

## 9. Decisions that are the user's

None is re-argued here. Each needs the user's word or a trigger that fired.

1. **A-1:** change the D14 answer to allow a dream run on demand, whose proposals stay uncommitted and labelled?
2. **A-2:** topic files plus an index, in place of one `captured.md` (D13, D14)?
3. **I-1 and I-2:** descriptions or titles in what Claude sees first (D22, D13, D18)?
4. **I-3:** an expiry for entries that quote a person (D16)?
5. **I-4:** the union-merge suggestion. Small, and evidence decides it.
