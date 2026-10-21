# v2 decision ledger

Rules: [01-process.md](01-process.md). One record per decision; ids are never renumbered. A LOCKED decision is
settled; it reopens only when one of its "reopen if" events is observed.

## Status

| Id | Question | Status | Decider | Depends on |
| --- | --- | --- | --- | --- |
| V2-D01 | How are decisions made, checked and tracked? | LOCKED 2026-10-19 | user | — |
| V2-D02 | Where is v1 cut? | LOCKED 2026-10-19 | user | — |
| V2-D03 | Which branches carry v1 and v2? | LOCKED 2026-10-19 | user | D02 |
| V2-D04 | Where do v2 planning decisions and research live? | LOCKED 2026-10-19 | evidence | D03 |
| V2-D05 | How are v2 versions numbered? | LOCKED 2026-10-19 (default) | user | D03 |
| V2-D06 | Which plugins are enabled while working on v2? | LOCKED 2026-10-19 | user | — |
| V2-D10 | Scope: which knowledge does v2 hold, and what is out of scope? | LOCKED 2026-10-20 (reopened and re-locked the same day) | user | — |
| V2-D11 | Where does a repo's knowledge live? | LOCKED 2026-10-20 | user + evidence | D10, D12 |
| V2-D12 | Which delivery channels actually arrive, and where? | LOCKED 2026-10-20 | evidence | — |
| V2-D13 | What does an entry of the project map hold, and within what delivery budget? (Selection: D22) | LOCKED 2026-10-21 | evidence | D10, D11, D12, D20 |
| V2-D14 | How does knowledge enter the map, and who may write it? | OPEN | user + evidence | D11, D13 |
| V2-D15 | Onboarding: how does the plugin turn a repo's existing rules into the map, or map a repo that has none? | LOCKED 2026-10-21 (run 4, after a block) | evidence | D13 |
| V2-D16 | How does the map stay fresh? | OPEN | evidence | D13 |
| V2-D17 | How is value measured (eval tasks, arms, thresholds)? | LOCKED 2026-10-20 | evidence + user | D10 |
| V2-D18 | What runs where (runtime, hooks, MCP) and what is the surface budget? | OPEN | evidence | D12, D13, 02-v1-postmortem.md |
| V2-D19 | How is value measured at scale: a large repo with big documents, where context fills quickly? | OPEN | user + evidence | D10, D17 |
| V2-D20 | By what mechanism does v2 make Claude follow the knowledge that binds a task, once delivered? (Finding it: D22, D18) | LOCKED 2026-10-21 | evidence | D12, D17 |
| V2-D21 | How does v2 know what exists in a repo (its inventory) without a per-language parser? | OPEN | evidence | D10, D13 |
| V2-D22 | Selection: how do the entries that bind a task reach Claude without a hand-made list, within 8 KB? | BLOCKED 2026-10-21 (budget and route to the user) | evidence | D12, D13, D15, D20 |

Frontier (rule 6): **D22 is BLOCKED** (2026-10-21), on the assumption that one push of at most 8 KB at prompt time
holds a task's essential knowledge. Investigation tasks need 8 to 18 KB, and a model pick finds relevant entries but
not the essential ones. The user decides how much context a task gets and by what route; D22 re-checks under that
answer. D14, D16 and D18 do not wait on it.

---

## Setup decisions

### V2-D01 — Decision process
- **Choice:** the record, rules 1-10 and step gate in [01-process.md](01-process.md).
- **Rejected:** decide by argument and review at the end (v1: the deciding experiment S1 was built, 2,710 lines,
  and never run; audit rounds re-checked the same ground); one GitHub issue per decision (duplicates the ledger;
  also raised by the Gemini review); step notes in an issue (moved to commit bodies, one home); one ADR file per
  decision (Gemini's proposal: one ledger file is one read for an agent, fifteen files are fifteen); deleting the
  three-strike rule or the step gate (Gemini's proposal: the user asked for both explicitly).
- **Check:** the user reviews 01-process.md and accepts it or names changes. **Result:** pass (user accepted it as
  written, 2026-10-19). Second opinion:
  Gemini Pro reviewed charter + process on 2026-10-19; accepted and rejected points are in the commit that applied
  them.
- **Reopen if:** a decision is re-argued twice without a fired trigger, or the step gate is skipped twice; either
  means the process does not hold.
- **Amended (2026-10-20, by the decider):** the user asked that every step verify the assumptions it rests on, so
  that a result showing the plugin losing its main idea sends the work back to approach it differently. Added to
  rule 9's `Doubted:` line and to `/v2-step` §3; the charter now names the main idea. No rule renumbered; not a
  reopen, since the decider changed its own answer.

### V2-D02 — v1 cut point
- **Choice:** merge PR #114, then cut v1 at 0.57.1 (commit `9718cee`), tag `v1-final`.
- **Rejected:** cut at 0.57.0 (`ea56cdc`); that freezes a version with known MUST findings, including a persistent
  prompt-injection path through learned warn rules and a guard bypass through Windows 8.3 short names.
- **Check:** user answer (2026-10-19). Release `v1-final` and branch `v1` exist on GitHub at `9718cee`. **Result:**
  pass.
- **Reopen if:** a security fix to v1 is needed (it lands on branch `v1`; the cut point does not move).

### V2-D03 — Branches
- **Choice:** `main` keeps serving v1 to marketplace installs until v2 is ready and merged. v2 is developed on branch
  `v2`, started from `main` with every v1 file removed (clean slate). v1 is readable at tag `v1-final` and branch
  `v1`, which takes v1 security fixes after v2 lands.
- **Rejected:** an orphan `v2` branch (unrelated histories make the eventual merge to `main` awkward, and
  `git show v1-final:<path>` comparisons get harder); keeping v1 code beside v2 (v1's two-minute pre-push suite on
  every docs push, and v1 assumptions leaking into v2); a new repository (loses issues, stars and the marketplace
  URL).
- **Check:** user answer (2026-10-19). Branches `v1` and `v2` exist on GitHub. **Result:** pass.
- **Reopen if:** the marketplace needs to serve v1 and v2 side by side.

### V2-D04 — Home of v2 planning knowledge
- **Choice:** everything about v2 (charter, process, decisions, research, probes) lives on branch `v2` under
  `docs/v2/`, tracked and public. Raw research material (transcripts, local paths) stays in the gitignored
  `docs/v2/research/raw/`.
- **Rejected:** v1's rule D2 ("the knowledge base outside the repo is the only home for decisions"): it made
  decisions readable only through a working v1 plugin, and the system being rebuilt cannot be the store of its own
  redesign. v1's research also lived in gitignored `docs/researchs/`, local to one machine.
- **Check:** the files are tracked on `origin/v2` and a fresh clone of `v2` contains them. **Result:** pass
  (fresh shallow clone of `v2` at `b6ee109`, 2026-10-19, lists every `docs/v2/` file).
- **Reopen if:** v2's own map format is ready (D13); then this repo's v2 knowledge moves into it.

### V2-D05 — Version numbering
- **Choice:** v2 plugin versions start at `2.0.0-alpha.1`, tagged `v2.0.0-alpha.N`. The old tags `v1.4.0`, `v2.11.0`
  and `v2.11.1` (May 2026, earlier numbering) stay as they are; the `v1-final` release notes explain them.
- **Rejected:** deleting or renaming the old tags (destructive on a public repo, for no current gain); continuing
  0.x (hides the clean break).
- **Check:** default chosen in the prep session; recorded here for the user to object. **Result:** pass (no
  objection yet).
- **Reopen if:** the user objects, or v2 approaches `2.11.0`, where the old tags would collide.

### V2-D06 — Plugins enabled while working on v2
- **Question:** which plugins should load in sessions on this branch? Too many skills overflow the skill listing:
  in the prep session about half of ~460 skills appeared with no description, so Claude cannot route to them, and
  every tool call ran the hooks of all enabled plugins.
- **Options:** (a) keep everything; (b) disable `ecc` for this project only (≈350 skills, 77 agents, 27 hook
  commands, mostly language reviewers that do not apply here); (c) a minimal set: ponytail, mattpocock-skills, exa,
  built-in agents.
- **Mechanism (documented):** `"enabledPlugins": {"ecc@ecc": false}` in the worktree's `.claude/settings.local.json`
  disables a user-level plugin for one user in one project; that file is not committed. The skill listing gets 1%
  of the context window; when it overflows, descriptions of the least-used skills are dropped first
  (https://code.claude.com/docs/en/skills#skill-descriptions-are-cut-short).
- **Choice (user, 2026-10-19):** (c) minimal: `ecc` and `exa` disabled for the v2 checkout through its
  `.claude/settings.local.json`; ponytail and mattpocock-skills stay. Built-in WebSearch replaces exa.
- **Check:** `/context` in a fresh session in the v2 checkout shows no `ecc:` skills or agents, and every listed
  skill has its description (no overflow). **Result:** pass (2026-10-19, CLI 2.1.303, 1M-token window). A fresh
  headless `/context` lists 68 skills (Skills row 9.1k tokens), none from `ecc`. Its `--debug` log reports 11
  plugins, 9 enabled and 2 disabled (`ecc`, `exa`), and no skill-listing budget warning. The Skills row is measured
  after the budget, and an overflow writes that warning to the debug log (doc above), so no description was
  dropped. The session's own skill listing shows every description. `/context` does not list agents; the session's
  agent types are the built-ins only. Attempts: 0.
- **Observed, not chosen:** four plugins synced from the claude.ai account (`design`, `engineering`, `productivity`,
  `cowork-plugin-management`) also load: 23 skills, no hooks, and MCP connectors that wait for authentication. They
  fit the budget.
- **Reopen if:** a step needs a disabled plugin's skill or agent; or a session's `--debug` log shows the
  skill-listing budget warning (for example on a smaller-window model: the budget is 1% of the window).

---

## Product decisions

Each has a draft check. It is finalised (pre-registered) when work on the decision starts.

### V2-D10 — Scope: the project's knowledge areas
- **Question:** which kinds of knowledge does v2 hold? Candidates: lead developer (structure, conventions,
  decisions and their rejected options), PM (goals, scope, priorities, what is in flight), designer (design system,
  component inventory, UX rules), QA and ops where present. What is explicitly out (initial list in the charter)? Is
  the personal layer (one user's preferences) left to Claude Code's native auto memory? Is v1's `~/knowledge` data
  imported?
- **Check:** the user's explicit answers, dated, recorded here. The draft named a grilling session; it ran as one
  written list of five questions, each with a recommended answer, because the user had asked to proceed without
  further rounds before the list went out. The pass condition is unchanged.
- **Result:** pass (2026-10-20). The user accepted the five recommended answers as written: (1) v2 holds lead
  developer, PM and designer knowledge, as tags on one store rather than persona agents, with QA and ops
  later; (2) the charter's non-goals stand as written; (3) one person's own preferences are left to Claude Code's
  auto memory; (4) no automatic import of v1's `~/knowledge` data, at most a one-time seed of decisions the user
  reviews; (5) the map is committed in the repo and reviewed like code (D11's question, recorded under D11).
- **Reopened (2026-10-20, same day):** the trigger "the user adds or drops a role" fired. The user said the three
  roles were an example, not the scope: projects differ in which knowledge leads. An app built on a canon of books or
  a fictional universe has strong concept rules; a pure development project has mostly engineering decisions; a
  marketing-led product has a strong brand and audience base. Re-lock check: the same, the user's explicit dated
  answer. Result: pass; answers (2) to (5) stand, answer (1) is replaced by the choice below. Not a failed attempt.
- **Choice:**
  - v2 holds the knowledge that a project's key people hold and the code does not show. Which knowledge areas a
    project has is the project's own, not a fixed list in v2: the lead developer, PM and designer of A1; the canon of
    an app built on books or a fictional universe; the brand and audience of a marketing-led product; the engineering
    decisions of a pure development project. QA and ops are areas a project may have, not a separate deferral.
  - An area is an attribute of a piece of knowledge (which area, who asserted it) within the one map of a repo. It is
    not a persona agent and not a separate store, and v2 builds no area-specific machinery (PM6). How a project
    declares its areas and how the attribute is written down is D13's; how a new map finds a repo's areas is D15's.
  - Out of scope: the charter's non-goals ([00-charter.md](00-charter.md#what-v2-is-not-confirmed-by-v2-d10)),
    confirmed as written; a personal-preference layer (Claude Code's auto memory holds it, and v2 builds none); any
    automatic import of v1's `~/knowledge` store.
  - v1's `~/knowledge` data may seed a map at most once, as proposals the user reviews entry by entry (PM5). How a
    map is seeded is D15's.
- **Rejected:** a fixed list of roles (the first choice: projects differ in which knowledge leads, user 2026-10-20);
  persona agents per role (agents control context, they are not job titles: Ultimate Guide finding 30; v1's role
  card, keyed on agent type, delivered a test-first card to a research dispatch: prior-and-SOTA A33); a v2 personal
  layer (it duplicates auto memory, which D12 found reaching the main session, general-purpose and plugin agents); an
  automatic v1 import (v1's store came from unreviewed LLM extraction over transcripts, PM5, and had one author,
  PM4).
- **Reopen if:** the user adds or drops a non-goal; the first slice's eval shows that labelling knowledge by area
  changes no acceptance outcome; Claude Code removes or restricts auto memory. Attempts: 0.
- **Evidence:** roles work as views over knowledge (tagged by role, owner or path authority), not as persona
  agents (Ultimate Guide gap 5 and finding 30; prior-and-SOTA rule 11, low confidence); v1 scope creep drew 3 of 5
  re-audit MUSTs (post-mortem cause 6).

### V2-D11 — Home of a repo's knowledge
- **Options:** (a) in the repo, committed and shared by the team through review; (b) in the repo but git-excluded
  (solo use); (c) a user directory outside the repo (v1); (d) native auto memory only (per machine, Claude-written).
- **Known constraint:** the native channels that reach subagents and cost nothing until used (`CLAUDE.md`,
  `.claude/rules` with `paths:`) read files from the repo tree (research: platform capabilities).
- **Check (the draft, made concrete before it was evaluated, 2026-10-20):** passes when (1) the user's dated answer
  names a sharing model; (2) D12's result shows files in that home reaching the main session, general-purpose and
  plugin agents through a native channel, with no plugin code (otherwise the option needs a hook, PM3); and (3) PM4's
  location half holds: every file of that home is tracked in git, so it is opened and corrected with an editor and
  a reviewed commit, no plugin needed. PM4's format half (a person reads and corrects one entry in v2's own format
  with the plugin disabled) needs D13's format, so it moves into D13's check.
- **Result:** pass (2026-10-20). (1) The user's answer, given with D10: (a), committed in the repo and reviewed like
  code. (2) D12: root `CLAUDE.md`, its imports and unscoped rules reach the main session (also after `/compact`),
  general-purpose and plugin agents 3 of 3; path rules and nested `CLAUDE.md` reach them after a matching read. All
  are files in the repo tree. (3) Under (a) every map file is a tracked plain file. Exhibit of the same shape: this
  ledger, a tracked plain file, had one entry corrected by a plain text edit, visible as a reviewable diff (the D10
  evidence citation, `9350136`), with no plugin involved.
- **Choice:** (a). A repo's team knowledge (the D10 knowledge areas) lives in plain files committed to that repo and
  changes through reviewed commits. Anything machine-local (an index, a cache) is rebuilt from those files by one
  command (PM4). One person's preferences stay in auto memory (D10). Where in the repo, and in which files, is D13's.
- **Rejected:** (b) git-excluded: the team cannot share or review it (user answer); (c) a user directory:
  machine-local, one author, unread by anyone else (v1's store, PM4); (d) auto memory only: per machine, written by
  Claude without review (PM5), not shared, and probed only when redirected into the repo (D12).
- **Reopen if:** a user needs a map in a repo where they may not commit it (then (b) is the candidate); a D12 reopen
  shows repo-tree files no longer reaching the main session natively. Attempts: 0.
- **Evidence:** team knowledge in the repo, reviewed like code; personal memory local; derived indexes as local
  caches (prior-and-SOTA rule 5: Cursor removed Memories, Devin moved Knowledge to Skills); v1's local store had one
  author and 35 `PROJECT.md` shards (post-mortem cause 4).

### V2-D12 — Delivery channels that arrive
- **Check (pre-registered 2026-10-20, probe P1, [probes/V2-D12-channels](probes/V2-D12-channels/)):** a fresh
  temporary git repo, the installed CLI, `claude -p` on Haiku, user settings excluded, a probe plugin loaded with
  `--plugin-dir`, and Bash, Grep and Glob denied so nothing can search for a nonce. Each channel carries its own
  random nonce, new for every run: root `CLAUDE.md`, an `@import` target, an unscoped rule, a path rule
  (`paths: src/**`), a nested `src/CLAUDE.md`, a project skill and a plugin skill with `paths:` (nonce in the
  description), plugin hook `additionalContext` on SessionStart (startup and compact tagged apart), SubagentStart
  and UserPromptSubmit, plugin MCP server instructions, and auto memory if a project can point it into the repo.
  Cells: the main session at start, after reading `src/a.ts`, and after `/compact` in a session that never quoted
  a nonce before compacting; Explore, Plan, general-purpose and a plugin agent at start and after reading
  `src/a.ts`; and write-first, where the main session creates `src/components/Avatar.tsx` without reading any file
  and a path rule and a nested `CLAUDE.md` there each ask for their nonce in the file. Three runs.
- **Pass (pre-registered):** a channel arrives in a cell if its nonce is quoted verbatim (or, write-first, written
  into the file) in 3 of 3 valid runs; 0 of 3 means it does not arrive; 1 or 2 means unreliable, which counts as not
  arriving (PM2). A run is valid when the main session quotes the positive control (root `CLAUDE.md` at start),
  nothing quotes the negative control (a nonce in a file nothing loads), every subagent answers in the required
  format, and the transcript shows no direct read of a nonce-bearing file other than the trigger and no nonce in a
  prompt written to a subagent. The check passes when every cell has three valid runs. The choice then records, per
  channel, the contexts where it arrives.
- **Result:** pass (2026-10-20, CLI 2.1.304, 3 of 3 runs valid; table and notes in
  [the probe README](probes/V2-D12-channels/README.md#results-2026-10-20-claude-code-21304-haiku-3-of-3-runs-valid)).
  Arrival, 3 of 3 unless stated:
  - Root `CLAUDE.md`, its `@import` and unscoped rules: the main session, also after `/compact`; general-purpose and
    plugin agents. Never Explore or Plan.
  - Path rules and nested `CLAUDE.md`: the main session, Plan, general-purpose and plugin agents, only after they
    read a matching file. Explore 2 of 3 (one denied read): unreliable, so not proven. In the main session also after
    `/compact`, because compaction re-attaches the recently read file. **Not before the first Write of a new file**
    (0 of 3 in the written content); they arrive with that Write.
  - Skills with `paths:`: a project skill is listed after a matching read, in agents that have the Skill tool. A
    plugin skill is listed from the start; its `paths:` gate did not apply.
  - Plugin hooks: SessionStart reaches the main session only and is gone after `/compact` unless the `compact`
    matcher emits again; SubagentStart reaches every subagent at start and never the main session;
    UserPromptSubmit reaches the main session on every prompt and never a subagent.
  - Plugin MCP server instructions: the main session from the start; a subagent only after its first tool call.
  - Auto memory (redirected into the repo): the main session, also after `/compact`, and general-purpose and plugin
    agents (the docs say subagents do not get it). Never Explore or Plan.
- **Choice:** a channel may carry v2 content only in the contexts where it arrived 3 of 3 above (PM2). At start,
  Explore and Plan get only SubagentStart context and skill descriptions (a plugin skill's `paths:` did not gate
  it). No probed channel delivers path-scoped knowledge before the first Write of a new file.
- **Rejected:** taking the documented channel table as the answer (three cells differ: auto memory in subagents,
  path rules after compaction, plugin skill `paths:`); a path rule as the way to shape a new file (0 of 3).
- **Reopen if:** a Claude Code release changes how `CLAUDE.md`, rules, skills, hooks or MCP instructions load
  (PM8); or a design depends on a context not probed here (an interactive session, another model, auto memory at
  its default location). Attempts: 0.
- **Evidence so far (documented, not yet probed):** research/2026-10-19-platform-memory-channels.md (Explore and Plan
  skip `CLAUDE.md`; path rules reach every agent type on file touch but are not re-injected after compaction; hook
  context above 10,000 chars becomes a file preview). Path rules may arrive after planning has started (Ultimate
  Guide finding 1). Push a small index, load details on observable triggers, never on model choice alone (Vercel:
  passive index 100% vs skill 53-79%; prior-and-SOTA rule 3).
- **Probe note:** from Git Bash, run `claude -p "/compact"` (any slash command) with `MSYS_NO_PATHCONV=1`, or MSYS
  rewrites the leading `/` into a Windows path and the model receives a path instead of the command.

### V2-D13 — Shape of the project map
- **Question:** node kinds (decision, convention, inventory, goal, design rule, …), file format, the always-on
  index and its byte cap, what loads on path touch, what is read on demand, size caps per node.
- **Draft check:** a paper map for two repos (this repo at `v1-final`, and one front-end sample), measured always-on
  bytes against the cap, plus three navigation tasks per repo that must reach the right file, and a person reading
  and correcting one entry with the plugin disabled (PM4's format half, moved here from D11). Since D10's re-lock the
  areas are the project's own, so the paper map also covers a project whose leading area is not engineering (a
  canon- or marketing-led sample) without a change to the format. At scale (research 2026-10-20-scale-real-repos):
  the paper map also covers the two large private repos P1 and P2 (P2 as the canon-led sample), with an always-on cap
  and a cap on bytes delivered per task, both measured against the repo's own native setup (P1: 29.5 KB always on;
  265 KB of path rules for one five-file task).
- **Test bed (2026-10-20):** the format is the target of D15's conversion and the source of D20's delivery, so it
  must carry what D20's mechanism needs. The paper map covers all three shapes of the test bed (charter): v1's repo,
  P1 and P2. Assumption to test (any stack, charter): an inventory of what exists is computed without a
  per-language parser, on shell, TypeScript and C# alike.
- **From D20 (2026-10-21):** the format carries a rule's own text, its source and its area, and fits about 2 KB per
  task: 1.7 to 2.5 KB for 5 to 8 rules in D20's stage 2, against 265 KB of P1 path rules. Two findings for the
  format:
  - A card that quotes its source's inline default handed Claude the counter-pattern (R0 R6: in 2 of 3 misses Claude
    copied the quoted line as a fallback).
  - Whether a card must name the code not to copy is still open: 9 of 27 cards did, where their source did.

  D13's check adds selection: for each of D20's four tasks, the index or router must bring the same 27 rules D20
  delivered by hand, and that share is measured before D18.
- **Evidence so far:** store only what the code cannot say, and no generated overviews (arXiv 2602.11988: −0.5 to
  −2 points, +20-23% cost); the always-on layer is a routing index under ~3,000 chars (arXiv 2606.20512: +4.7 points,
  all from reaching the right file); compute structure such as the component inventory from code on demand
  instead of storing it (prior-and-SOTA rules 1, 2, 7).
- **Narrowed (2026-10-21):** one question that one check can answer (rule 1 of the record). What does an entry
  hold, and how do the entries that bind a task reach Claude without a hand-made list, within what byte budget?
  The rest of the draft moves out:
  - The inventory of what exists, computed without a per-language parser, becomes V2-D21.
  - A person reading and correcting an entry with the plugin disabled (PM4's format half) moves to D15, where real
    entries exist.
  - The hand-made paper map and its navigation tasks are dropped as over-built: a map written by someone who knows
    the tasks would repeat D20's oracle. The blind map below replaces it, and P2 is the canon-led sample.
  - Node kinds are left to the result: it shows whether rules and references need different handling.
- **Options:**
  - (a) Native: the repo as it is run today (path rules on touch, pointers, skills). Its recall is already
    measured by D20 stage 1.
  - (b) A prompt-time ranker. On `UserPromptSubmit` (D12: arrives 3 of 3), a lexical scorer ranks the map's entries
    against the prompt and delivers the best until a byte cap. No model call.
  - (c) An always-on index Claude chooses from. Not run: must-choose retrieval is the failure D20 stage 1 measured
    (no run opened any of the v1 repo's 17 skills; every rule in a document nothing points to was missed, 15 of 15),
    and a skill the model had to invoke went uninvoked in 56% of runs ([VERCEL] in research
    2026-10-19-prior-research-and-sota).
  - (d) A model in the hook picks entries from an index: seconds per prompt and a model dependency in a hook.
    Attempt 3 only.
  - (e) Scope routing at the first write (D20's deny). A plan never writes, and of the three repos only P1's sources
    declare a scope, so it stays D18's net, not the selector.
- **Check (pre-registered 2026-10-21, before the script exists; probe
  [probes/V2-D13-selection](probes/V2-D13-selection/)):**
  - *Blind map.* A script builds each repo's map from its files at D20's pinned commits. It never reads the tasks or
    the cards. Every tracked doc file (`.md`, `.mdx`, `.markdown`, `.txt`, `.rst`) is split into entries, one per
    block. A block is a paragraph, a top-level list item with what is indented under it, a table, or a code fence.
    Each entry keeps its source (path and heading path) and, where its file's frontmatter has `paths:`, that scope.
    Blocks over 1,200 bytes are split at line ends, and identical blocks are kept once.
  - *Two corpora.* *Pointed:* the instruction files (`CLAUDE.md`, `CLAUDE.local.md` and `AGENTS.md` anywhere, and
    doc files under `.claude/rules`, `skills`, `commands` and `agents`), plus every doc file they name by path,
    transitively. *All docs:* every tracked doc file.
  - *Ranker (b).* BM25 (k1 1.2, b 0.75) of the task prompt against each entry's file path, heading path and text.
    Tokens are lowercase letters and digits, with camelCase split (the whole word kept too), a fixed English
    stopword list, and a trailing `s` dropped from words over three letters. Each distinct prompt term counts once.
    Entries are taken in score order, each one that still fits under the cap (one that does not is skipped), and an
    entry that scores 0 is never delivered. An entry costs the UTF-8 bytes of its source line plus its text (1 KB = 1,024 bytes).
  - *Held.* A card is held when the delivered entries, source lines included, cover at least 80% of its word
    trigrams. Cards are quoted and trimmed, so exact containment would fail; trigrams are taken within each
    stretch between elisions. P1 R1's source is a config file, so only a doc that repeats it can hold it.
  - *Native (a), from stage 1, no new runs:* a rule-run counts when the rule was in context before the first write
    (for the plan, at all). That was 0.60 of rule-runs, and 13 of 27 rules in all five runs.
  - *Pass:* on the all-docs corpus at 8 KB per task (under the 10,000-character `additionalContext` limit), every
    task holds at least 80% of its cards (P1 5 of 6, P2 build 7 of 8, R0 7 of 8, the plan 4 of 5), and the share
    held across all 27 is above native's 0.60.
  - *Reported, with no threshold:* recall at 2, 4, 16 and 32 KB; the pointed corpus; each card's coverage against
    the whole corpus, which tells a corpus miss from a ranking miss; bytes delivered per task; the share of
    delivered bytes that hold a card; ranking time per prompt; map size per repo (entries and KB).
  - *Attempts, planned now.* If attempt 1 fails, attempt 2 adds a selection key written blind: an agent that sees
    the repo but not the tasks writes trigger terms per source file, and the ranker scores them with the entry.
    The scorer is not tuned against the 27, because that would be fitting. If attempt 2 fails, attempt 3 is (d).
  - *If it passes:* entries are the sources' own blocks with their anchors, so D15 inherits a mechanical first pass,
    and v2 adds no always-on bytes for selection.
  - *Not tested:* whether Claude follows a ranker's noisier set, since D20 delivered exactly the binding rules
    (D18's first slice); follow-up prompts, where a ranker should stay silent; subagents and compaction; the hook's
    runtime (D18); whether an entry should quote its source or state the rule and point to it (Fog, D15).
- **Attempt 1 result (2026-10-21): fail.** Run as registered
  ([probes/V2-D13-selection](probes/V2-D13-selection/README.md#attempt-1-2026-10-21)). The blind maps hold 2,854
  (P1), 10,229 (P2) and 3,414 (R0) entries. At 8 KB the ranker held 6 of 27 cards (0.22, against native's 0.60):
  P1 2 of 6, P2 build 0 of 8, R0 1 of 8, the plan 3 of 5. At 32 KB it held 8. Ranking took 2 to 7 ms per prompt
  after a 100 to 300 ms index build.
  - *A ranking miss, not a corpus miss.* Against the whole corpus, 21 of 27 cards reach the 80% bar. Five P2 cards
    fall short because they stitch a heading to its body, and P1 R1 sits in a config file. At a 60% bar the whole
    corpus holds 26, and the ranker still holds 6 at 8 KB. The bar changes no outcome.
  - *Why.* A binding rule shares few words with the task. In ranked order, the first entry that holds a card sits
    beyond 60 KB, or scores 0, for 13 of the 21 cards the corpus holds at the 80% bar.
  - *What it shows about the format.* The h1 and h2 sections that hold a task's cards come to 14 to 32 KB per task,
    and the whole files 14 to 186 KB. So with the sources' own blocks as entries, any selector coarser than one block
    overflows 8 KB, and the 10,000-character `additionalContext` limit with it.
  - *For the format.* Indexing the sources in place cannot replace onboarding's conversion: their blocks are too
    coarse to select and too big to deliver. An entry is a trimmed quote with its source anchor, its area and a
    selection key, written at onboarding (charter: the one standard format).
- **Attempt 2 as planned is ruled out by a count, not run (2026-10-21).** Per-file trigger terms raise every entry of
  a matched file alike, so inside the file the order is still attempt 1's text match. The holding files are 14, 82,
  186 and 60 KB, so three of the four tasks would fail at 8 KB by construction (rule 5: a count that decides the
  same thing beats a run). This is not a failed check, and the attempt count stays at 1. The plan was written before
  the size count existed. One more count fixes what the key must do. The h1 and h2 sections that hold the cards
  have 18, 61, 27 and 34 rule items, which as compact entries is about 5 to 10 KB per task, while their whole files
  have 19 to 276. So the key has to find the right sections and tell rules apart inside them, per rule, not per
  file.
- **Attempt 2 check (pre-registered 2026-10-21, before any model call):**
  - *Converter, blind.* For each doc file of the all-docs corpus, a fresh Sonnet 5.5 call (CLI 2.1.305, no tools,
    no settings, its own system prompt) sees only the file's path and its map blocks, numbered with their heading
    paths. It never sees the tasks or the cards, and its output is not edited. Files over 40 KB are sent in parts
    split at block boundaries. For each rule it finds, it returns:
    - the rule in the file's own words, trimmed, with cuts marked and at most 300 characters (verbatim, so D20's
      first reopen trigger does not fire);
    - the numbers of the blocks it came from;
    - an area name;
    - 3 to 8 applies-when terms.

    A rule is anything that tells someone working on the project what to do, not do, or stay consistent with.
  - *Ranker.* Attempt 1's BM25, unchanged, over each entry's area, applies-when terms, quote, file path and heading
    path. A delivered entry costs its source line plus its quote.
  - *Held.* Attempt 1's 80% trigram bar, judged on the source blocks the delivered entries cite. This measures
    whether the right source is selected, not how faithful the quote is (D15's reviewer check).
  - *Pass:* unchanged (all docs, 8 KB, every task at least 80% of its cards, the total above 0.60).
  - *Cost first.* A pilot converts one file per repo and projects the cost from bytes. If the projection is above
    25 USD, the user is asked first. Pilot (2026-10-21): 0.10 USD for three files, projecting 27.90 USD. The user
    approved the Sonnet run as registered the same day.
  - *For D15.* The converter's output is D15's prototype bootstrap. D15's reviewer check ("accepts at least 80% of
    the generated entries") reuses it rather than building a second converter.
- **Attempt 2 result (2026-10-21): fail.** Run as registered
  ([probes/V2-D13-selection](probes/V2-D13-selection/README.md#attempt-2-2026-10-21)).
  - *Converter:* 421 calls, none failed, 22.35 USD. It produced 6,367 entries (P1 1,834, P2 2,756, R0 1,777), 531 to
    765 KB per repo as compact entries, against 1.6 to 3.6 MB of blocks.
  - *Recall:* at 8 KB the ranker held 6 of 27 (0.22): P1 3 of 6, P2 build 0 of 8, R0 0 of 8, the plan 3 of 5. At
    32 KB it held 10.
  - *Where it was lost.*
    - Conversion: of the 21 cards the corpus holds, the converter's entries cite the source of 15. It skipped two
      P2 canon rules and four R0 rules.
    - Ranking: for P1 and the plan, the best entry citing each converted card ranks within about 9 KB. For R0 and
      P2 build it ranks at 5 to 125 KB: in R0, hundreds of entries concern hooks, JSONL files and sessions, and
      the task's eight rules are among them.
  - *A flaw in the check, found now.* Five P2 build cards stitch a heading to its body, so they cannot reach the 80%
    bar against the whole corpus (attempt 1). The P2 build task could not reach 7 of 8 under any selector. This
    changes neither result, because both attempts also fail on R0, but it is fixed before any further attempt. The
    scores above stand as registered (rule 2).
- **Held rule corrected (2026-10-21, disclosed; the registered scores stand):** a card is holdable when the whole
  corpus covers at least half of its trigrams, and held when the delivered blocks cover at least 0.8 times what the
  corpus covers ([corrected.mjs](probes/V2-D13-selection/corrected.mjs),
  [results/held-corrected.json](probes/V2-D13-selection/results/held-corrected.json)). 26 of 27 cards are holdable;
  P1 R1, in a config file, is not. At 8 KB, attempt 1 holds 6 and attempt 2 holds 7 (0.26). Neither verdict changes.
- **Attempt 3 is ruled out by a count, not run (2026-10-21).** Every block the converter cited, taken together,
  holds P1 5 of 6, P2 build 6 of 8, R0 5 of 8 and the plan 5 of 5. So on attempt 2's entries no selector, (d)
  included, can reach 7 of 8 on either build task. Lifting that ceiling means converting again with a prompt changed
  after seeing which rules it missed, and that is fitting. Rule 4 applies: the framing is wrong, and a count showed
  it before a third run. Selection recall is bounded by onboarding recall.
- **By hand, R0 (public):** of the 26 entries attempt 2 delivered at 8 KB for the R0 task, 5 bind it and 21 are on
  the same topics (JSONL files, other hooks, project slugs) without binding it. The 8 KB delivered was mostly
  non-binding, so the cap was not what failed here; the selector was: lexical keys do not separate rules inside a
  repo's own topic. How large a task's whole binding set is stays unmeasured (the sections holding the cards came
  to about 5 to 10 KB as compact entries).
- **Split (2026-10-21):** as with D20, the question is split at what the checks settled. The entry's shape locks
  here. Selection becomes V2-D22, behind D15, because its recall is bounded by onboarding's. This lock was not
  pre-registered as such: the registered check tested selection, and that failed twice. The shape rests on what
  those runs showed whatever the selection result. If the phase-gate review (rule 8) finds that insufficient, D13
  returns to CHECKING.
- **Choice (2026-10-21), the entry:**
  - The rule in its source's own words, trimmed, with cuts marked. The converter's 300-character limit is an
    unverified default (one card Claude followed in D20 was 353); D15's reviewer settles it.
  - Its source anchor: the file, the heading path and the blocks it came from.
  - The area it governs, and applies-when terms.
  - Written at onboarding (D15) into the map's plain files (D11).

  The delivery budget stays at most 8 KB per task, below the 10,000-character `additionalContext` limit; the sets
  D20 delivered and Claude followed were 1.7 to 2.5 KB. What this shape stands on:
  - D20 stage 2: entries of this shape, written by hand, were followed (7 of 8 native misses fixed).
  - Attempt 1: the alternative, the sources' own blocks, overflows the limit at section or file grain (14 to 186 KB
    per task) and cannot be selected at block grain.
  - Attempt 2: the shape can be built blind for all three repos, in 421 calls with none failing, for 22.35 USD. It
    comes to about a third of the blocks' text.
- **From D22 (2026-10-21), a budget finding declared before D22 ran:** under the user's scope, the essential knowledge
  of an investigation task was 25 to 45 entries, 8.2 to 17.9 KB, on five of six tasks. D13's 8 KB came from D20's
  build tasks with 5 to 8 hand-picked rules (1.7 to 2.5 KB). Even the platform's ceiling (about 9.7 KB of
  `additionalContext`) does not hold 11 to 18 KB. D22 is blocked on this; the user decides budget and route.
- **From D15 (2026-10-21):** an entry also carries `context` (the table header or bold lead label its quote's
  meaning depends on) when the quote lacks it. This is an addition to the shape; the quote stays verbatim.
- **Rejected:**
  - Indexing the sources in place, with no conversion (attempt 1).
  - Per-file selection keys (ruled out by the size count).
  - A paper map written by hand, which would repeat D20's oracle.
  - Restated entries: they would fire D20's first reopen trigger.
- **Reopen if:**
  - A selector reaches D22's pass on the sources' own blocks.
  - D15's reviewer finds converted quotes reworded, or rejects more entries than its bar allows.
  - D20 reopens on what can be delivered verbatim.

  Attempts: 2 (both on selection, which moved to D22).

### V2-D14 — Capture and trust
- **Question:** how knowledge enters (explicit command or skill; Claude proposes a map edit as part of the diff;
  end-of-session suggestion; never raw transcript mining?), who may write it, and how untrusted text is kept out.
- **Draft check:** user answer on the review model; a probe that a poisoned tool output cannot reach the map without
  appearing in a reviewable diff.
- **User answer (2026-10-20, given with D17):** Claude decides on its own what is worth keeping, with no cue from
  anyone; an entry it adds shows up in the working-tree diff and is committed with the work, with no separate
  approval step. The commit's review is the review. Tension to settle in the check: prior-and-SOTA A18 found that
  agents rarely capture on their own (43 of 44 kept learnings came from an explicit command), so the mechanism has to
  make unprompted capture reliable; D17's capture metric measures it.
- **Evidence so far:** capture explicitly at decision points; background extraction only proposes (prior-and-SOTA
  rule 9: 43 of 44 kept learnings were explicit); treat every memory write as untrusted (rule 10: MINJA 98.2%
  injection success). v1's unreviewed LLM extraction became a persistent prompt injection (post-mortem cause 5).
  Contested: the Ultimate Guide prefers capture in hooks; that adds no tokens to the session, but judging what to
  keep is still a model call, and the docs describe auto memory as Claude's own unprompted judgment (research
  2026-10-20 §1-2). Capture points: `PreCompact`, `Stop`; compaction now also fires on idle (v2.1.299). D17's
  baselines (2026-10-20): with no cue, auto memory kept the developer's and the PM's spoken decisions in 10 of 10 runs
  and dropped the one-off detail, but kept nothing of a designer's document that Claude read and reviewed (0 of 10),
  and recorded no source. Unprompted capture works for decisions said in passing, not for knowledge read in a
  document; that gap, provenance and team sharing are where capture design has room. Native option to weigh (memory
  docs, fetched 2026-10-21): any settings scope may move auto memory, but only to an absolute or `~/` path, under
  workspace trust, so a team can share it only by each person pointing a local setting into their own clone (as D17's
  M1 arm did). v2's sharing has to beat that; it is also the natural competitor for the second-person run.

### V2-D15 — Onboarding (bootstrap)
- **Question (widened 2026-10-20 by the user):** the plugin's entry point. On install, how does it turn a project's
  existing rules and documents into the map's standard format, or map a project that has none, so that everything
  later is delivered and enforced from that format? Within it: what is converted into entries and what stays a
  document indexed by section; whether the source stays the home with the entry anchored to it, or the entry
  replaces it (two copies drift, D16); how a project's areas are found (D10).
- **Inputs it must accept:** the test bed's three shapes. v1's repo at `v1-final`: no `CLAUDE.md` anywhere in the
  tree (only a 0.9 KB instruction file for another agent); 180 Markdown files, 1.5 MB, 731 KB of it in 17
  project-knowledge skills (architecture contract, change control, debugging playbook and the like), so its rules
  load only when a skill is invoked; plus concept documents, and a store outside the repo. P1: a 29.5 KB root file and 29
  path-scoped rule files (578 KB, 818 list items), plus reminders and a lint test after writes. P2: a 9.9 KB root
  file pointing into 1.9 MB of documents (152 KB of rules, 13 files, 599 list items), a hand-written pointer index and
  five validators; nothing path-scoped. End projects will bring shapes none of these has.
- **Draft check:** a prototype bootstrap on two repos; a human reviewer accepts at least 80% of the generated
  entries as correct and useful, and the generated index stays under the D13 cap. At scale: a rules document of at
  least 100 KB is distilled into entries without losing a planted rule, and each entry keeps its source anchor
  (research 2026-10-20-scale-real-repos §3: v1 held 3 entries for a repo with about 600 rule items). Since
  2026-10-20: run on all three test-bed repos; a reviewer compares each entry with its source and finds its meaning
  unchanged; a repo with no rules gets a map from its code (stand-in: the A1 fixture, which has no rule files).
- **From D13 (2026-10-21):** D13's attempt 2 converter, run blind on all three test-bed repos, is this decision's
  prototype bootstrap; the reviewer check runs on its output. PM4's format half (a person reads and corrects an
  entry with the plugin disabled) moved here from D13.
- **Narrowed (2026-10-21):** does the blind converter, run unchanged, turn a repo's documents into entries that are
  faithful, binding and complete enough to build on? Settled with it: whether the source stays the home, the
  on-disk form a person can correct (PM4), and the repo with no rules. Not settled here:
  - *How a project's areas are found.* The converter's `area` field is a per-entry topic: 1,398 (P1), 2,106 (P2)
    and 1,253 (R0) distinct labels, nearly one per entry. That does not answer D10's question, and no bar set today
    could measure a consolidation not yet designed. It moved to D22 on 2026-10-21: whether selection needs areas at
    all is D22's question, and if it does not, the per-entry label serves D10's area attribute as it is.
  - *The draft's "generated index under the D13 cap":* dropped, because D13 locked no always-on index.
- **Reviewer (user, 2026-10-21):** Gemini Pro in the browser, in place of the human reviewer the draft named. The user
  allowed P1 and P2 text to go to Gemini for this check: an exception to process rule 10, for D15 only, with only
  counts in this repo. A model reviewer is weaker than a person. D13's reopen trigger ("D15's reviewer finds
  converted quotes reworded, or rejects more entries than its bar allows") fires on this reviewer's verdicts as
  written.
- **Check (pre-registered 2026-10-21, before the fidelity script, the sample or any paste;
  probe [probes/V2-D15-onboarding](probes/V2-D15-onboarding/)):**
  - *Input.* D13 attempt 2's converter output, unchanged: 6,367 entries from 421 calls, made blind to every task.
  - *1. Verbatim, every entry, no model.* Each stretch of an entry's quote between cut marks that has three or more
    words must appear as a contiguous word sequence in the blocks the entry cites. Words are letters and digits,
    lowercased, so whitespace, case and markdown marks do not count. **Bar: at least 95% of entries per repo.**
    Also counted: quotes over 300 characters, and entries with no stretch of three words.
  - *2. Sample.* A section is a source file's blocks under one h1 and h2 heading pair. A section over 6 KB of block
    text is cut at block ends into windows of at most 6 KB, and each window counts as a section. Per repo, 20
    sections, in three strata: 9 with entries in pointed files (D13's pointed corpus), 6 with entries in unpointed
    files, and 5 with no entries. If a stratum is short, the remainder comes from the next. *Amended before any
    paste:* the first draw excluded sections over 6 KB and took 14 per repo, and the excluded sections held 1,215 of
    P1's 1,834 entries. That draw's counts were the only thing seen; no review had run. The order is
    sha256 of `d15-2026-10-21` plus the section key, lowest first. The A1 fixture's two docs (style guide and
    README) are converted with the same converter and added whole to R0's pastes. Both are public, and A1 is
    reported separately.
  - *3. Gemini, pass A (sections only).* Gemini lists every rule in each section. It gets the converter's
    definition of a rule word for word, and it does not see the entries.
  - *4. Gemini, pass B (same chat, now with the entries).* For each entry, Gemini gives three verdicts:
    - *binds:* is it a rule by that definition?
    - *faithful:* does the trimmed quote still say what the source says in context? Trimming that drops a
      condition, exception or scope is a failure. D20's R6 showed a quote out of context handing over the
      counter-pattern.
    - *area fits:* report-only.

    For each rule from pass A, Gemini names the entry that covers it, or none.
  - *Bars, per repo:*
    - *Precision:* at least 80% of reviewed entries both bind and are faithful.
    - *Recall:* at least 80% of pass A's rules are covered by an entry.
  - *5. Planted rules.* Eight rules per document are written in the document's own style. Each is inserted as its
    own block at seeded positions, after blocks chosen by the same seed rule. The documents are P1's 169 KB
    document, P2's 134 KB document, and R0's largest (it has none over 100 KB). Each document is converted again
    with the converter unchanged. A planted rule is found when an entry cites its block. **Bar: none of the 24
    lost.** The planted text stays private.
  - *6. PM4 round trip.* R0's entries are rendered as one Markdown file per source file (entries grouped by heading,
    each with its quote, source and applies-when terms; not per area, which is unsettled). One quote is changed by a
    plain text edit, with the plugin's code out of the loop, and the files are parsed back. **Pass:** exactly that
    entry differs.
  - *Pass:* all six parts.
  - *Attempts, planned now.* If precision, recall or the planted rules fail, attempt 2 revises the converter's prompt
    and is re-tested only on a fresh seed (`d15-2026-10-21-b`), fresh sections and fresh planted rules, never on the
    sections or rules that produced the misses (D13: tuning against seen misses is fitting).
  - *Reported, not counted:* converter recall against D20's 27 rules (already inspected in D13: the cited blocks
    hold 21 of 26 holdable); cost per MB of docs; Gemini's area verdicts.
  - *Settled by citation, no run (rule 5).* A repo with no rules gets no synthesised conventions. Generated overviews
    of code score lower and cost more (arXiv 2602.11988, in D13's evidence). Its map starts from the inventory (D21)
    and from captured work (D14). The charter's "maps what the code shows" is read as that inventory, not as
    invented rules.
  - *Settled by part 1's result.* If quotes are verbatim, the source stays the home: an entry is a committed
    derivative of its source, anchored to its blocks, and drift goes to D16.
- **Attempt 1 result (2026-10-21): fail, on recall only.** Counts in
  [probes/V2-D15-onboarding/results](probes/V2-D15-onboarding/results/).

  | Part | P1 | P2 | R0 | Bar |
  | --- | --- | --- | --- | --- |
  | 1. Verbatim (all entries) | 99.1% | 96.6% | 99.0% | 95%: pass |
  | 4. Precision (binds and faithful) | 0.98 (53) | 0.92 (50) | 0.96 (55) | 0.8: pass |
  | 4. Recall (pass A's rules covered) | 0.79 (76) | **0.48** (94) | **0.73** (59) | 0.8: **fail** |
  | 5. Planted rules found | 8 of 8 | 8 of 8 | 8 of 8 | none lost: pass |
  | 6. PM4 round trip | | | 126 files, 1 edit, 1 entry changed | pass |

  A1's two docs: 7 entries, all binding and faithful; 9 of 9 rules covered. Quotes over 300 characters: 53, 72 and
  60. P2's verbatim misses are mostly tables restated as lists. The sample was amended before any paste, as
  recorded above. Cost: 0.02 USD for A1 and 1.19 USD for the planted runs. P1 pass B errored once in Gemini and was
  retried in the same chat.
  - *Where recall was lost.* By stratum, the share of pass A's rules covered:
    - sections with entries in pointed files: 78%, 67% and 87%;
    - sections with entries in unpointed files: 84%, 54% and 75%;
    - sections where the converter wrote nothing: 0 of 1, 0 of 22 and 0 of 9.

    The missed rules are real: P2's canon base and UI language, and R0's skill routing.
  - *Why, across all 421 converter calls and not only the sampled misses.* The converter's yield falls with the size
    of its input:

    | Input size | Rules per KB |
    | --- | --- |
    | Under 5 KB | 3.1 to 3.6 |
    | 5 to 15 KB | 1.5 to 1.8 |
    | 15 to 30 KB | 1.0 to 1.3 |
    | 30 to 40 KB | 0.7 to 1.2 |

    The two P2 inputs that returned no entries were halves of a game-data text file, where none is right. The
    gradient holds inside rule files alone (`CLAUDE.md` and `.claude/`): P1 3.5, 2.2, 1.4 and 1.1 rules per KB; R0
    3.1, 1.7, 1.3 and 1.0. So input size, not the kind of document, drives the loss. The planted rules, eight per
    document, were all phrased as explicit rules and were all found. That set could not detect the loss recall
    found, which is the plainer rules in long inputs.
- **Attempt 2 check (pre-registered 2026-10-21, before any re-run):**
  - *The one change.* The converter's input is one section window of at most 4 KB, cut at block ends, instead of
    up to 40 KB per file part. 4 KB is the best band in the table above; 5 to 15 KB already halves the yield. The
    prompt is unchanged (sha256 `e95d64a29c59`). The planned attempt 2 was a prompt revision; the evidence, taken
    from all 421 calls and not from the sampled misses, points at size, so prompt revision moves to attempt 3.
    Changing one thing keeps a pass or a fail attributable.
  - *Equivalence.* Parts are a deterministic function of the section windows. So converting a sampled window alone
    gives exactly what a full conversion would give for it, and the check converts only the fresh sample and the
    planted documents. The full re-conversion waits for D22.
  - *Fresh sample.* Seed `d15-2026-10-21-b`, windows of at most 4 KB, 20 per repo in the same strata (9, 6, 5).
    Windows overlapping attempt 1's sampled sections are excluded. The strata come from attempt 1's entries, as a
    stratification device only. A1 is dropped: 9 of 9, nothing to learn.
  - *Same parts and bars as attempt 1:*
    - verbatim at least 95%, on the new entries;
    - Gemini passes A and B with the same prompts, in fresh chats: precision and recall each at least 0.8 per
      repo, with area-fits report-only;
    - none of the planted rules lost;
    - PM4 is not re-run, because the format is unchanged.
  - *Fresh planted rules.* Eight per document, at seed-b positions. Each is a plain declarative sentence in the
    body's register, with no "Rule:" lead and no imperative, so that this part can disagree with recall.
  - *Cost:* about 5 USD. *If it fails:* attempt 3 revises the prompt, on seed `-c`.
- **Attempt 2 result (2026-10-21): fail, on R0's recall.** Counts in
  [results/*-a2.json](probes/V2-D15-onboarding/results/).

  | Part | P1 | P2 | R0 | Bar |
  | --- | --- | --- | --- | --- |
  | Verbatim (new entries) | 99.7% | 99.6% | 98.5% | 95%: pass |
  | Precision | 0.92 (142) | 0.81 (88) | 0.97 (135) | 0.8: pass |
  | Recall | 0.86 (116) | 0.96 (57) | **0.73** (257) | 0.8: **fail** |
  | Planted rules, declarative | 8 of 8 | 8 of 8 | 8 of 8 | pass |

  - *Reviewer for R0 (user, 2026-10-21):* Gemini failed or stalled on R0 five times, so a fresh Claude subagent
    (Opus, not the converter's Sonnet) ran the same two passes on R0 alone. It wrote pass A before it opened pass
    B. It listed rules about 1.6 times as finely as Gemini did for the same sections: 153 for S1 to S10, against 97
    in Gemini's unfinished pass A. It counted every table row and glossary line as a rule.
  - *What R0's recall missed:*
    - table rows saying what each command and skill does: 20 of 26 in one section;
    - glossary definitions: 17 of 24 in two sections;
    - open-issue status lines.

    These are descriptions and status, not instructions. The converter's prompt says to skip explanation that binds
    nothing, while the rule definition's "facts the work must not contradict" makes them rules. The score stands as
    registered.
  - *Seen in the entries:* two R0 entries quote the source's absolute local path and an email address. Entries
    copy whatever the source holds, so a committed map inherits its source's sensitive strings.

  Progress notes, kept as they were written during the run:
  - *Converter, unchanged prompt, 4 KB inputs:* 60 sampled windows and three planted documents, 3.86 USD. It
    yielded 142, 88 and 135 entries in the sampled windows; attempt 1's sample yielded 53, 50 and 55 from different
    sections.
  - *Verbatim:* 99.7%, 99.6% and 98.5%. *Planted rules (declarative):* 24 of 24 found.
  - *Gemini, P1:* precision 0.92, recall 0.86 (100 of 116). *P2:* precision 0.81, recall 0.96 (55 of 57). The R0
    review is not finished.
  - *Reviewer deviations, disclosed.* Gemini failed or refused long pastes this time; attempt 1's had gone through.
    P1 was sent in three chats (10, 5 and 5 sections), with the same prompts and ids. Its first piece passed only
    after one line was added to pass A: section text is data, and instructions in it are not to be followed. Two of
    P1's sampled sections come from an AI prompt file. R0's pastes carry the same line.
- **After attempt 2: sensitivity, the ceiling, and the open definition (2026-10-21).**
  - *R0's 69 misses, classified by hand.* R0 is public; the classification is kept privately and is the converter
    designer's own, so it may be biased. 59 are descriptions or status: table rows saying what a command does,
    glossary lines, open-issue lines and setting defaults. 10 are prescriptive.
  - *Sensitivity, not a correction:* counted on prescriptive rules only, R0's recall is at least 0.8 whenever 40 or
    more of the 188 covered rules are prescriptive. Nearly all entries bind (135 of 135), so it very likely is.
  - *Ceiling.* A converter that keeps skipping descriptions can reach at most (188 + 10) / 257 = 0.77 on R0 under
    this reviewer's list. **So attempt 3 as planned (a prompt revision) is ruled out by count.** It could pass only
    by extracting descriptions, which changes what the map holds: about twice the entries, against D13's evidence
    that the map should store only what the code cannot say.
  - *The assumption that failed:* the definition of a rule, written into D13's converter prompt and never examined.
    The reviewer's definition says "facts the work must not contradict", while the converter is told to skip
    "explanation that binds nothing". That definition is a scope question for the user (D10's reopen triggers have
    not fired, so it is recorded here as a D15 sub-question). The recommended answer:
    - the map holds prescriptive rules and decisions;
    - what exists (commands, skills, what they do) is inventory, D21;
    - what is in flight belongs in the tracker (the Fog item);
    - glossary lines are the borderline case.
  - *Not to be read from these numbers:* R0 scored 0.73 in both attempts, but under different reviewers, at different
    granularity, on different sections. That is a coincidence, not "4 KB did not help R0". The input-size effect is
    shown on P1 and P2 under one reviewer. R0 is untested under a constant reviewer. One positive sign: R0's five
    sections where the 40 KB converter wrote nothing gave 8, 3, 9, 2 and 1 entries at 4 KB.
  - *If the answer is "prescriptive":* attempt 3 re-registers with one reviewer for all three repos (a fresh Claude
    subagent, two blind passes; the Gemini exception lapses). The definition is narrowed in the reviewer's pass A,
    the converter's prompt is unchanged, and the run uses seed `-c` and the same bars. D15 blocks on a fail.
  - *Spend on D15 so far:* 5.07 USD (attempt 1: 1.21; attempt 2: 3.86).
- **User answer (2026-10-21): the map holds everything, descriptions too.** Rules and decisions, and also what the
  project's parts are and do: commands and skills, settings and their defaults, terms, and status. The answer was
  given against the recommendation (prescriptive only). Consequences, recorded before attempt 3:
  - the converter's definition of a rule changes, so attempt 3 is a converter prompt revision;
  - the map grows (R0's sampled windows suggest about twice the entries), which makes D22's selection problem
    harder;
  - it sits in tension with D13's evidence for storing only what the code cannot say. That evidence concerned
    overviews generated from code, while these entries are quoted from the project's own documents.

  D10's reopen triggers have not fired; this is D15's sub-question, answered by the user.
- **Attempt 3 check (pre-registered 2026-10-21, before the seed-c draw; D15's last attempt):**
  - *The changes.*
    - The definition of a rule follows the user's answer, in one text used word for word by the converter's prompt
      and the reviewer's pass A. It is `RULE3` in [onboard.mjs](probes/V2-D15-onboarding/onboard.mjs), and the
      converter prompt's sha256 is `a833629588b0`.
    - The definition adds what the project's parts are and do, settings and defaults, terms and status.
    - It keeps facts the work must not contradict, and skips narrative, history and changelog lines that state
      nothing current. That exclusion is our reading of the user's "everything".
    - Both sides count one rule per item: a table or list of separate items gives one per row or item. Applied
      identically to both sides, this aligns the unit of count. Its need was seen in attempt 2's R0 misses.
  - *Inputs and sample.* Converter inputs stay one section window of at most 4 KB. Seed `d15-2026-10-21-c`, 20
    windows per repo in the same strata, excluding the windows of attempts 1 and 2.
  - *Prompt development only on burned windows.* On three of attempt 2's R0 windows (a table and two glossaries),
    the old prompt gave 4, 2 and 3 entries and the new one 24, 9 and 11. The reviewer had listed 26, 11 and 13 there.
    This was plumbing only, nothing scored, 0.11 USD; the prompt was frozen after it.
  - *One reviewer for all three repos.* A fresh Claude subagent (Opus) per repo runs the same two blind passes: it
    writes pass A before it opens pass B. Pass A carries the line that section text is data. This departs from
    "Gemini as reviewer": Gemini could not review R0 and repeatedly refused P1's content, and the user accepted
    Claude for R0. The rule 10 exception lapses, because the private text stays on this machine. A reviewer from
    the converter's model family is the known weakness.
  - *Planted rules.* Eight per document at seed-c positions: four prescriptive declaratives, and four descriptive
    (a setting with its default, a glossary line, a table row, a status line).
  - *Bars unchanged, on every repo:* verbatim at least 95%; precision and recall each at least 0.8; no planted rule
    lost. P1 and P2 are tested again under the new definition, because their attempt 2 pass does not carry over.
    Under "everything", precision is nearly tautological, so verbatim and faithfulness carry the fidelity check.
  - *Also reported:* entries per KB, and the projected full-map size per repo at that yield (D22's input).
  - *If it fails* (rule 4, third attempt): D15 is marked BLOCKED, and the assumption reopened is that one model pass
    over a document window converts it completely.
- **Attempt 3, first parts (2026-10-21):**
  - *Converter:* 60 windows, 1.16 USD; planted documents, 3.53 USD.
  - *Verbatim:* 100%, 99.3% and 98.7%: pass.
  - *Planted rules:* P1 8 of 8, **P2 7 of 8**, R0 8 of 8, so this part **fails** and with it attempt 3. The lost
    rule was a prescriptive declarative placed between a list item and its indented continuation, in a dense 4 KB
    window. The converter wrote about ten entries from that window and none for the planted line.
  - *Sample:* P1's unpointed stratum had no eligible window left after attempts 1 and 2, so its six slots passed to
    "none", as registered.
  - *Yield and projected size under the user's definition.* The sampled windows gave 3.9, 6.0 and 5.9 entries per
    KB, and the whole planted documents about 4.0. Over each repo's document text that projects to about 5,800
    entries (1.4 MB) for P1, 8,800 to 13,500 (2.7 MB) for P2, and 4,600 to 6,700 (1.3 MB) for R0. That is 3 to 5
    times D13's map, and about as large as the documents themselves. So the conversion does not compress; its
    value is the anchors and keys. That is D22's input.
  - The reviewers' passes are still running. They are reported when done, but cannot change the verdict.
- **Attempt 3 result (2026-10-21): fail, on one planted rule. D15 is BLOCKED (rule 4, third attempt).** One reviewer
  (Opus) for all three repos, two blind passes each
  ([results/*-a3.json](probes/V2-D15-onboarding/results/)):

  | Part | P1 | P2 | R0 | Bar |
  | --- | --- | --- | --- | --- |
  | Verbatim | 100% | 99.3% | 98.7% | 95%: pass |
  | Precision | 0.95 (161) | 0.85 (142) | 0.96 (166) | 0.8: pass |
  | Recall | 0.82 (282) | 0.98 (239) | 0.94 (254) | 0.8: pass |
  | Planted rules (half descriptive) | 8 of 8 | **7 of 8** | 8 of 8 | none lost: **fail** |

  - *A new failure in the faithfulness data.* 19 of P2's 21 unfaithful entries are table rows quoted without their
    header row. One rule per row left the numbers without the columns that give them meaning.
  - *Reviewer note.* After its first write, P1's reviewer set two coverage cells to null, because it had judged
    those entries non-binding. That makes the score stricter.
  - *A near miss.* Every other part passed. Rule 4 allows a fourth attempt after a near miss with a known cause, but
    the pre-registration named BLOCKED as the outcome of a third fail, so that stands.
  - *The reopened assumption:* one model pass over a document window converts it completely. Two failures of it were
    seen:
    - a plain line skipped in a dense window;
    - table rows cut off from their header.

    What replaces it is the next step's question. The obvious candidate is a second pass that checks each window's
    blocks against the entries written and keeps a table's header with its rows. It is not designed here.
  - *What the runs showed, not locked while D15 is BLOCKED:*
    - quotes are verbatim in every attempt (96.6% to 100%), so the source can stay the home, with the entry an
      anchored derivative;
    - the PM4 round trip passed;
    - 4 KB inputs recover what long inputs lose;
    - the user's scope answer stands;
    - a bare repo gets no synthesised conventions (citation).
  - *Spend on D15:* 9.87 USD (attempt 1: 1.21; attempt 2: 3.86; attempt 3: 4.80, including the 0.11 USD smoke).
- **Going up a level (2026-10-21, the user: "continue with the converter fix").** D15 stays BLOCKED on the old
  assumption. It is replaced by a named one: *conversion is an extract pass plus a verify pass over the same window,
  and an entry carries the context its quote's meaning depends on.* The re-check below is **run 4 overall**; the
  counter is not reset.
  - *Plumbing on burned data only, nothing scored (0.18 USD).*
    - P2's lost planted rule: its attempt 3 window was converted again with the verify pass, twice. Both times the
      first pass cited it, and the verify pass added one other entry each time. So attempt 3's loss looks like
      run-to-run variance, not a blind spot. The verify pass is kept as a second chance against that variance.
    - Of attempt 3's 21 unfaithful P2 entries: 11 are table rows cut from their header, 7 are "**Rejected:**" list
      items whose quote dropped the label, which turns a rejected option into a rule, and 3 are other. All 21 get
      context under the rule below; whether it repairs them is for the reviewer.
  - *Context, deterministic, as an addition to D13's entry.* When the first cited block is a table, or a part of
    one, the entry carries the table's header line; when the block is led by a bold label, it carries the label. In
    both cases only when the quote lacks it. It is shown with the entry and is never folded into the quote. No D13
    reopen trigger fires: the quote stays verbatim.
  - *Verify pass.* Same system prompt (sha256 `a833629588b0`). The message is the same numbered blocks, plus the
    entries already written with their block numbers, plus "list only the rules in these blocks that no entry above
    states". Its entries are merged after deduplication on the normalised quote, and every entry is tagged pass 1 or
    2.
- **Run 4 check (pre-registered 2026-10-21, before the seed-d draw):**
  - Same six parts and same bars, on every repo: verbatim at least 95%; precision and recall at least 0.8; none of
    the planted rules lost; the PM4 round trip passes, run again because the entry gained `context`.
  - Seed `d15-2026-10-21-d`, 20 windows of at most 4 KB per repo, excluding attempts 1 to 3. One fresh Opus reviewer
    per repo, two blind passes. Pass B shows each entry's context. Fresh planted rules, four prescriptive and four
    descriptive per document.
  - *Reported to attribute the gain:* precision and recall counting first-pass entries only, the verify pass's
    yield, the duplicates it dropped, and the cost per KB.
  - *If run 4 fails, D15 stays BLOCKED and goes to the user.* A fifth run is not planned.
- **Run 4, automatic parts (2026-10-21):**
  - *Verbatim:* 99.9%, 99.4% and 98.8%: pass.
  - *Planted rules:* 8 of 8 in each repo, half of them descriptive: pass.
  - *PM4 round trip with context:* pass.
  - *Verify pass:* it added 24, 12 and 16 entries to the first pass's 163, 196 and 166 (6% to 13%). It dropped no
    duplicates, and no verify call failed. Context was attached to 98, 57 and 59 of the sampled entries.
  - *Cost:* 2.02 USD for the windows and 5.43 USD for the planted documents. Two passes cost about 1.6 times
    attempt 3.
  - *Sample:* P1's unpointed stratum is still empty, so its slots passed to "none", as in attempt 3.
- **Run 4 result (2026-10-21): pass, on all six parts.** One fresh Opus reviewer per repo, two blind passes each
  ([results/*-a4.json](probes/V2-D15-onboarding/results/)):

  | Part | P1 | P2 | R0 | Bar |
  | --- | --- | --- | --- | --- |
  | Verbatim | 99.9% | 99.4% | 98.8% | 95% |
  | Precision | 0.98 (187) | 0.95 (208) | 0.97 (182) | 0.8 |
  | Recall | 0.97 (214) | 0.97 (240) | 0.98 (265) | 0.8 |
  | Planted rules, half descriptive | 8 of 8 | 8 of 8 | 8 of 8 | none lost |
  | PM4 round trip with context | | | pass | pass |

  - *Where the gain came from.* With first-pass entries only, recall is 0.92, 0.94 and 0.92 and precision 0.99,
    0.95 and 0.98. The first pass alone would have lost 3 of the 24 planted rules (P1 one, R0 two), and the verify
    pass found all three. So the verify pass is what holds the "none lost" bar.
  - *What remains.*
    - P2 has 10 unfaithful entries, mostly items under a heading that frames them ("Deliberately Rejected",
      "Anti-Patterns"), quoted as neutral statements. Context covers bold labels and table headers, not headings.
    - Reviewer changes after a first write: P2 set one entry from faithful to not faithful and one from non-binding
      to binding; R0 set one area label to not fitting. Where one listed rule spanned two entries, reviewers
      credited one.
  - *Cost:* about 16 USD per MB of document text for the two passes on Sonnet. A full conversion of the test bed
    (4.9 MB of documents) projects to about 78 USD.
  - *Spend on D15:* 17.50 USD (attempts 1 to 3: 9.87; plumbing after the block: 0.18; run 4: 7.45).
- **Choice (2026-10-21):** onboarding converts every document file of a repo blind:
  - one section window of at most 4 KB per model call, with an extract pass and then a verify pass over the same
    window;
  - entries of D13's shape, the quote verbatim, plus `context` (the table header or bold lead label the quote's
    meaning depends on) when the quote lacks it;
  - the scope is the user's: rules, decisions, and what the project's parts are and do, settings, terms and status;
  - the source stays the home, and an entry is a committed derivative anchored to its blocks (drift: D16);
  - the map is plain Markdown, one file per source file, which a person can correct with the plugin off (PM4);
  - a repo with no documents gets no synthesised conventions; its map starts from the inventory (D21) and from
    captured work (D14). This rests on the citation. The A1 fixture's documents were converted and reviewed only in
    attempt 1, with the 40 KB converter and the old definition.

  Not settled here: how a project's areas are found. The converter's labels are per-entry topics (1,253 to 2,106
  per repo); the question moved to D22.
- **Rejected:**
  - One pass over inputs up to 40 KB (attempt 1: recall 0.48 to 0.79).
  - One pass at 4 KB under a prescriptive-only definition (attempt 2: R0 0.73; also the user's scope answer).
  - One pass at 4 KB under the user's scope (attempt 3: a planted rule lost, and table rows and labels cut from
    their context).
  - Indexing sources in place (D13).
- **Reopen if:**
  - A person reviewing a sample rejects more than 20% of entries. The reviewer here was a model, of the
    converter's family for P1, P2 and R0 in run 4.
  - Heading-framed entries, quoted without the heading that changes their meaning, exceed 5% of a repo's sampled
    entries.
  - A project keeps its rules in documents outside `.md`, `.mdx`, `.markdown`, `.txt` and `.rst`.
  - The converter's model or prompt (sha256 `a833629588b0`) changes.
  - The onboarding cost per MB is ruled out by D18's budget.

  Attempts: 3 failed, then run 4 passed after going up a level (rule 4).

### V2-D16 — Freshness
- **Question:** claims carry anchors (path, symbol, test); a deterministic check (git and regex, no model) flags
  drift; flagged claims are never delivered as current.
- **Draft check:** seeded drift (rename, delete, edit) on a sample map; the check flags 100% of seeded cases and
  0 false alarms on an unchanged tree.
- **Evidence so far:** every record carries code anchors, provenance and a verified-at commit, checked before
  delivery (prior-and-SOTA rule 6: GitHub Copilot Memory). v1 delivered a lesson citing line numbers that had moved
  (concept §2).

### V2-D17 — Measurement
- **Question:** the acceptance scenario, the arms (no memory between sessions; Claude Code's auto memory; v2), the
  metrics (charter table) and the thresholds.
- **User answers (2026-10-20):** A1 is the user's scenario (charter): knowledge from three earlier sessions, captured
  by Claude's own judgment, recalled in a fresh session; one scenario first instead of four tasks; the designer's
  document lives outside the repo; no cue to remember; the native baseline is auto memory instead of a hand-written
  `CLAUDE.md`. A first proposal (four tasks on documents written in advance) was replaced before anything ran.
- **Check (pre-registered 2026-10-20):** the scenario, arms, checks, metrics and protocol in
  [05-eval-plan.md](05-eval-plan.md). It passes when (1) the harness in `probes/V2-D17-eval/` (Node, no npm packages,
  at most 400 lines without fixture and session scripts) passes the smoke check: gold outputs pass every item, each
  planted wrong output fails exactly its own item, the test prompts hold no answer token and no history prompt a cue
  word; (2) the M1 pilot shows auto memory writing in a headless session; (3) M0 and M1 run 10 times each, all runs
  valid; (4) the thresholds are written into 05-eval-plan.md from those runs by its rule (a margin larger than M1's
  run-to-run spread on counts and tokens, no fewer passing runs on pass items), never guessed in advance (Gemini
  review). If M0 passes the folder, specification and no-CDN items in every run, the fixture measures nothing: a
  failed attempt, and the fixture changes. If M1 passes every item in every run, D17 records that v2's case rests on
  team sharing, on Explore and Plan (which auto memory does not reach, D12) and on cost, and the user sees it before
  any threshold is set. The neighbour session N, the failure chain (not kept, not loaded, ignored), the epoch rule and
  ten runs came from the guide and docs check
  ([research/2026-10-20-memory-scenario-guide-and-docs.md](research/2026-10-20-memory-scenario-guide-and-docs.md)),
  added before anything ran. Model (Sonnet 5.5) and run count are proposed defaults, open to the user until the pilot.
  The harness stays small; v1's had 2,710 lines and never ran.
- **Progress (2026-10-20):** (1) met: the harness ([probes/V2-D17-eval](probes/V2-D17-eval/), `b6d24c7`, 328 lines)
  passes its smoke check. (2) met: in the M1 pilot, auto memory wrote in headless sessions (4 writes, 3 files: an
  index and two notes). The pilot cost 0.30 USD for five sessions, so ten runs per arm cost about 4 USD in all. It is
  a valid run in the pre-registered epoch, so it counts as M1 run 1. Results in the probe README.
- **Result:** pass (2026-10-20). (3) M0 and M1 ran ten times each, all 20 runs valid, one epoch (CLI 2.1.304, Sonnet
  5.5), about 4 USD; the user gave the go for the remaining runs after the pilot, on the proposed model and run count.
  (4) The thresholds are in [05-eval-plan.md](05-eval-plan.md#thresholds), computed by the pre-registered rule from
  `results/summary.json`. Neither pre-decided outcome occurred: M0 failed T3 and T4 in every run, so the fixture
  measures; M1 passed no run in full. What the baselines show: auto memory kept the developer's and the PM's spoken
  decisions in 10 of 10 runs and followed them (folder 10, no CDN 7, at the first Write too), never kept the
  one-off port, and never over-applied them (N3 10 of 10); it never kept the designer's specification that Claude
  read and reviewed (C2 0 of 10); no arm named its sources (T5 0 of 20). Against M0, M1 lowered T's median tokens
  from 132,036 to 97,602 at about the same cost.
- **Choice:** scenario A1 with the neighbour N; arms M0 and M1 as run; the checks, metrics, protocol and harness in
  05-eval-plan.md and [probes/V2-D17-eval](probes/V2-D17-eval/); the thresholds as computed. The v2 arm runs the
  same harness in the build phase, once as the same person and once as a second person with only the committed map.
- **Rejected:** the first proposal (four tasks on documents written in advance: not the user's scenario); a
  hand-written `CLAUDE.md` as the native baseline (the user's answer: auto memory is the native way); `claude plugin
  eval` as the runner (one prompt per case, no chained sessions); an LLM judge (deterministic checks suffice).
- **Reopen if:** the CLI, the model or the fixture changes before the v2 arm runs (a new epoch: the baselines run
  again, the rule stays); the user sets targets for C2, T3 or T5 or changes the rule (a new attempt, rule 2); a native
  team memory ships (M1 would then reach a second person). Attempts: 0.

### V2-D18 — Runtime and surface budget
- **Question:** which code runs where, which hook events (if any) v2 uses, the latency budget per hook, whether an
  MCP server is needed, and the maximum count of skills, agents, hooks and scripts.
- **Draft check:** derived from D12 and the post-mortem's rules; every hook named with a measured p95 under load
  below its budget on Windows. At scale: the prompt-time router's p95 measured over a map the size of P1's or P2's.
- **Evidence so far:** one v1 Edit ran 8 hooks and at least 52 processes; under load a spawn cost 314 ms and about
  217 guard runs failed open (post-mortem cause 3, proposing at most one non-shell hook per event, p95 ≤ 100 ms at 8
  concurrent sessions). A PreToolUse timeout fails open unless the hook sets `"onFailure": "block"` (CLI ≥ 2.1.295;
  platform note §7).
- **From D22 (2026-10-21):** a prompt-time model pick over a map costs 4 to 18 s and 0.20 to 0.71 USD per call (Sonnet).
  It cannot run on every prompt; once per task it might. A lexical pick costs 6 to 20 ms after a 0.1 to 0.3 s index
  build.
- **Boundary to verify (2026-10-20, public plugin):** a map entry is never turned into a command the plugin runs.
  Only the project's own hooks and tools run, under Claude Code's workspace trust; a plugin that ran checks defined in
  a cloned repo's map would open a new way to execute untrusted code.

### V2-D19 — Measurement at scale
- **Question:** A1 (D17) runs on a 16-file fixture. How is value measured where the user's projects actually are: a
  large repo whose documents hold the important rules and criteria, where a task's context fills quickly (scenario
  A2)? Asked by the user on 2026-10-20: v1 failed on such repos and on its own.
- **Options:** (a) public fixture: this repo at `v1-final` (736 files, 1.5 MB of Markdown), materialised at run time
  with `git archive` into a scratch folder, never copied into the `v2` tree; (b) the user's private repos P1 and P2,
  run locally, with task prompts kept out of this public repo (`research/raw/`, gitignored) and only numbers
  published; (c) a large synthetic fixture; (d) (a) for the committed, reproducible scenario and (b) as a local
  confirmation.
- **User answer (2026-10-20):** all three repos are test cases: v1's own repo, P1 and P2. All are on GitHub, so each
  run starts from a clean copy and nothing is lost. The question that matters is not where knowledge is kept but
  whether Claude follows it: in the past Claude ignored rules and documents, either because it never looked for them
  or because it had them and did not apply them. Runs use scratch clones; the private repos' results enter this
  public repo as numbers only (working rules).
- **Shared with D20 stage 1 (2026-10-21):** the native arm's runs on the test-bed tasks are this decision's native
  baseline.
- **Gap (2026-10-20):** part of v1's knowledge lived in its store outside the repo, which a scratch clone does not
  have. For A2 the v1 repo's knowledge is what it commits (concept documents, skill bodies); the store enters only
  through D10's one-time reviewed seed.
- **Arms:** the repo as it is run today (its instruction file, rules, hooks and skills; at scale this is the native
  competitor, not an empty repo), the same plus auto memory, and v2 in the build phase.
- **Draft measures:** rule items followed, checked deterministically, reusing a repo's own validators where it has
  them; duplicates created, checked against an inventory generated from the code; research cost (Glob and Grep calls
  and reads of files the output never imports, counted apart from reads it needs); peak and growth of per-turn input
  tokens; compactions; instruction bytes loaded (a project `InstructionsLoaded` hook in the harness that appends to a
  log).
- **Draft check:** the user's answers (which repos, whether private repos may run locally with numbers only, that
  the tasks are realistic); the D17 harness extended and smoke-checked; a pilot with its cost reported before the
  baselines; then baselines and thresholds by D17's rule, unless the user sets fixed targets.
- **Evidence so far:** P1's native setup loads 29.5 KB always and 265 KB of path rules for one five-file task; P2's
  knowledge is 1.9 MB of documents read on demand and 6,740 scripts found only by search; v1's store held 3 entries
  for P2 against about 600 rule items, and its P1 decisions sat in an archive sessions did not load
  ([research/2026-10-20-scale-real-repos.md](research/2026-10-20-scale-real-repos.md)).

### V2-D20 — Adherence: how v2 makes Claude look for and follow the knowledge
- **Question:** knowledge in the map is worth nothing unless Claude (a) has the part that binds the task before it
  acts and (b) applies it. By what mechanism does v2 achieve both? Asked by the user on 2026-10-20: in the past Claude
  either never looked for a rule or document, or had it and ignored it.
- **Narrowed (2026-10-21):** the check that decided this answers the second half only, because stage 2's selection
  was an oracle. The first half, which rules reach Claude for a task, moved to D13 (the format and its index) and
  D18 (what runs where, and its surface budget), measured against the same 27 rules. On 2026-10-21 it moved on
  from D13 to D22.
- **Options:** (a) native only: an index in `CLAUDE.md` plus path rules and skills (how P1 runs today); (b) delivery:
  the rules' own text, few at a time, when the prompt arrives, before the first write in an area (a `PreToolUse` deny
  whose reason carries the rules), into subagents and again after compaction; (c) (b) plus deterministic checks fed
  back after writes and at `Stop`; (d) (c) plus accounting at `Stop`, where Claude names each delivered rule it
  applied and its source, or why it does not apply.
- **Draft check:** a probe under `probes/V2-D20-adherence/` with planted rules of three kinds (checkable, judgment,
  reference) in the A1 fixture and in one task on a scratch clone of P1; arms (a), (b) and (d); per rule kind:
  delivered before the first write, followed at the first write and at the end, violations fixed after feedback,
  extra turns and tokens, hook p95 on Windows. The pass condition is written before it runs.
- **Two stages (2026-10-21, research 2026-10-21-rethink):** no adherence number we hold was measured in the
  test-bed repos. **Stage 1** runs only arm (a), each repo as it is run today: one task per repo plus one planning or
  review task, each binding rule leaving a decidable trace in the output (no LLM judge, D17), and for each miss the
  failure chain (never loaded, loaded but not read, read but not applied). **Stage 2** builds only the arms that
  answer the failures stage 1 shows. If stage 1 finds a repo's own setup following its rules, v2's case there is
  cost and knowing where to look, and that is recorded before any gate is built. The bullets below describe stage 2.
- **Stage 1 check (pre-registered 2026-10-21, before any task run):**
  - *Setup.* The harness [probes/V2-D20-adherence/native.mjs](probes/V2-D20-adherence/) runs each session in a fresh
    worktree of a scratch clone pinned to a commit, with the repo's own `CLAUDE.md`, rules, skills and hooks (setting
    sources project and local; no user settings, plugins, MCP servers or auto memory; Bash and the web off, so nothing
    is installed or built). Sonnet 5.5, headless. An `InstructionsLoaded` hook logs every instruction file that
    loads and what triggered it; hook output is read from the event stream.
  - *Tasks.* Four, in a private config passed by path (task text and rules of private repos never enter this repo):
    one build task in each test-bed repo and one review or planning task. Each binding rule has a deterministic check
    on the output (where a file must be; a regex that must or must not match), a kind, and the way the native setup
    delivers it (always on, path rule, pointer, skill, document, hook). The config's hash is recorded with every run,
    so a change after results is visible (rule 2). Before the pilot, every check passes a correct sample and fails a
    plausible wrong one, both written into the config (the harness's `checks` mode, as D17's smoke check did).
  - *Runs.* A pilot of one run of the P1 build task, with its cost reported. Then five runs per task, if that
    projects to at most 25 USD; otherwise the user is asked first. A run is valid when the session ends in success on
    the pinned model, at the pinned commit, and the `InstructionsLoaded` log holds the session-start load where the
    repo has a `CLAUDE.md`.
  - *Outcome per repo, decided now.* The premise holds in a repo if one of its binding rules fails its check in at
    least 2 of 5 runs. It does not hold if every rule passes in at least 4 of 5 runs. Each miss is classed as not in
    context (split by whether the native setup pointed at the rule) or in context but not applied.
  - *What stage 2 then builds.* Misses mostly not in context: the delivery arm (b). Misses mostly in context: checks
    and accounting (c, d). Both: both. No miss in any repo: no adherence arm. v2's case in these repos is then cost and
    knowing where to look, and the user hears that before D13.
  - *Also recorded, with no threshold:* followed at the first write as against at the end (the repo's own hooks
    fixing after the write), instruction bytes loaded, tokens, turns, tool calls before the first write.
- **Stage 1 result (2026-10-21):** run as registered. Pilot 0.30 USD, then 20 runs, all valid, one epoch (CLI
  2.1.305, Sonnet 5.5), 6.37 USD ([probes/V2-D20-adherence](probes/V2-D20-adherence/README.md#results-2026-10-21)).
  The premise holds in all three repos: P1 (a rule missed 5 of 5, another 3 of 5), P2 (three rules missed 5 of 5 in
  the build, one 5 of 5 in the plan), the v1 repo (one rule missed 4 of 5, another 2 of 5). Both kinds of miss
  occur: 25 misses with the rule not in context, 16 with it in context but not applied, as scored; two checks were
  found wrong on reading the outputs and are corrected by hand next to the score (22 and 13), which changes no
  outcome. So stage 2 builds both, as registered: delivery (b), and checks with accounting (c, d). What the misses
  share: every rule in a document nothing points to was missed (15 of 15); rules the neighbouring code already shows
  were followed without the rule in context, and rules it contradicts were missed, one of them in the always-on file;
  no run opened any of the v1 repo's 17 project skills. Not a failed attempt.
- **Stage 2 check (pre-registered 2026-10-21, before any stage 2 Sonnet run):**
  - *Question.* Given the rules that bind a task, does delivering their own text at the right moment make Claude
    follow them (b), and which rules also need checks fed back and an account at `Stop` (c, d)? **Selection is an
    oracle:** each task's hand-identified rules (27) are delivered, so stage 2 tests following, not finding. What
    picks the right rules for a task stays with D13 and D18, and a lock here covers following only.
  - *Setup.* Stage 1's harness, tasks, pinned commits and epoch (CLI 2.1.305, Sonnet 5.5; the runs switch the
    auto-updater off; a run on another CLI version means arm (a) re-runs in that epoch before any comparison). Arm
    (a) is stage 1's 20 runs. Each rule gets a card: its text quoted, trimmed, from the repo's own files, with its
    source and the area it governs. A card names the counter-pattern only where its source does (9 of 27; recorded
    per rule), and one fixed line heads every delivery: where existing code differs from a rule, follow the rule.
    Cards and checks stay in the private config; its hash is recorded with every run.
  - *Arm (b), delivery* ([probes/V2-D20-adherence/deliver.mjs](probes/V2-D20-adherence/)): the task's cards as
    `UserPromptSubmit` context (D12: arrives 3 of 3), and once per area a `PreToolUse` deny before the first write
    there, its reason carrying that area's cards. The two channels are not tested apart; each run records what the
    denied first attempt held, which is what prompt delivery alone produced.
  - *Arm (d), (b) plus checks and account:* after each write, the failing pattern checks of that file are fed back
    (`PostToolUse` block reason); at the first `Stop`, the failing pattern checks plus a request to end the reply with
    a section headed `## Rule account` naming every card as applied (where) or not applicable (why), with its
    source. No separate arm (c).
  - *Rule class, declared now.* Pattern-held, 17 rules: a data check holds them, and the check fed back is the
    scoring regex itself, so for these arm (d) measures whether Claude fixes a named violation, not whether a check
    written at onboarding would find it. Judgment, 10 rules (canon, design, the plan): no check, only the account.
  - *Checks.* Two corrected before any stage 2 run; stage 1's scores stand (rule 2). P3a ignores a line that names
    the excluded creature in order to reject it; P5 accepts the governing vision named by file name, and another
    vision does not count. On the stage 1 replies each reproduces the hand count (5 of 5, 2 of 5), and arm (a) is
    compared under the corrected checks. Under (d) the scored reply is the answer before the `Stop` block plus what
    follows it, with the account section cut, so naming a source in the account cannot pass a reply check; with no
    heading, only the answer before the block is scored.
  - *Arrival first (D12's rule).* Three channels carry content here that D12 did not probe: a `PreToolUse` deny
    reason, a `PostToolUse` block reason and a `Stop` block reason. Before any Sonnet run, three Haiku runs each give
    every channel its own nonce, taken from the environment and in no file. A channel may carry cards only if its
    nonce is quoted or written in 3 of 3 runs, counting only runs in which that channel's hook fired. Two trials
    preceded this rule, and both are kept with the private run data. In the first, the post-write nonce was scored by
    a file edit, which Claude declined as unrequested although its reply referred to the request. In the second, the
    deny asked for an extra first line. In 2 of 3 runs Claude would not write a line the user had not asked for, so
    the file was never written and the post-write hook never fired. Now each nonce only asks to be quoted. One Haiku
    run per arm then checks the plumbing.
  - *Runs.* Pilot: one P1-build run in each of (b) and (d), with its cost. Then (b), five runs per task. (d) runs, five
    per task, only on tasks where (b) leaves a rule missed or regressed. If all of stage 2 projects above 25 USD, the
    user is asked first. A run is valid under stage 1's criteria, plus every card delivered at prompt arrival (the
    hook's log) and, under (d), a `Stop` hook call. An invalid run is replaced, at most two per task and arm, and
    reported.
  - *Outcome per rule, decided now.* Missed in (a): fails in 2 or more of 5 runs (8 rules: P1 R2 and R6, P2 R5, R6
    and R7, R0 R4 and R6, P2-plan P5). Fixed by an arm: missed in (a) and fails in at most 1 of 5. Regressed: fails
    in at most 1 of 5 in (a) and in 2 or more in the arm.
  - *What locks.* (b) fixes every rule missed in (a) and regresses none: D20 locks (b), and (c) and (d) are rejected
    for these repos. (b) leaves rules missed and (d) fixes them without regressions: D20 locks (c) if every rule
    left is pattern-held (the account adds nothing proven), or (d) if a judgment rule is among them. A rule that no
    arm fixes is a failed attempt (attempt 1, rule 4), recorded with its class and kind. Flagged to the user before
    any lock, with no threshold: an arm whose median cost on a task exceeds 1.5 times arm (a)'s, and a hook p95 on
    Windows above 1 s.
  - *Not tested:* finding (the oracle above); subagents and compaction (0 of 20 stage 1 runs used either, so the
    `SubagentStart` and post-compaction deliveries are not built); prompt-time and pre-write delivery apart; the
    repos' own lint, tests and builds (Bash stays off).
- **Stage 2 result (2026-10-21):** run as registered
  ([probes/V2-D20-adherence](probes/V2-D20-adherence/README.md#stage-2-results-2026-10-21)). The config's hash was
  `08a2dc047fb1` before the pilot and after the last run.
  - *Arrival:* the three new channels arrived 3 of 3. The pilot cost 0.44 USD in (b) and 0.52 USD in (d).
  - *Arm (b):* 20 runs, all valid, one epoch (CLI 2.1.305), 7.52 USD. Of the 8 rules missed in (a), it fixed 7: P1 R2
    and R6, P2 R5, R6 and R7, R0 R4, and P2-plan P5. R0 R6 was still missed, followed in 2 of 5 runs. Nothing
    regressed. P3a scores 4 of 5 as registered, and 5 of 5 by hand: "stays out" rejects the creature, but the check's
    negation list lacks it.
  - *Arm (d):* so it ran on R0-build only: 5 runs, all valid, 2.33 USD. R6 was followed 5 of 5, every other rule 5 of
    5, and nothing regressed.
  - *Where the effect came from, by first attempts.* With only the cards from prompt arrival, the first writes (the
    ones the deny then stopped) already followed every P1 rule in 5 of 5 runs, and R0 R4 in 5 of 5. R6 was right at
    the first attempt in 5 of 10 runs across (b) and (d). The re-delivery at the deny fixed none of the 3 R6 misses
    left in (b). The fed-back check fixed both (d) runs that needed it. In 2 of the 3 (b) misses, the script sourced
    `lib.sh` but added a fallback that is the very line the card quotes from the skill.
  - *Cost:* median cost against (a) was 1.02, 1.27, 1.19 and 0.98 times for (b) on P1, P2 build, R0 and the plan,
    and 1.25 times for (d) on R0. Hook p95 inside the hook process was 24 ms in (b) and 82 ms in (d). No flag fired.
    The cards came to 1.7 to 2.5 KB per task. Two (b) plan runs read no file and passed every check at 0.03 USD.
- **Choice (2026-10-21):** (c), for following. The rules that bind a task are delivered as their own text, quoted
  with their source, when the prompt arrives. As tested, a one-time deny delivers them again before the first write
  in their area. After writes and at `Stop`, the failing data checks of pattern-held rules are fed back. The deny was
  tested only as part of this bundle. Whether it earns its cost goes to D18: it makes Claude rewrite each denied
  file, which took P1's output from about 5.3k to 9k tokens. D18 may keep it only as a net for areas that prompt-time
  selection missed. Which rules reach Claude for a task (selection) is not settled here; it belongs to D13 and D18.
- **Rejected:**
  - (a) native only: it missed rules in all three repos (stage 1).
  - (d)'s account at `Stop`, as an adherence mechanism in this test bed: no judgment rule needed it, and all 10 held or
    were fixed by delivery alone. Whether Claude names the rules it followed and their sources is A1 item (5),
    measured by D17. It is not decided here.
- **Reopen if:**
  - D13's format changes what can be delivered verbatim.
  - A judgment rule stays missed, failing in 2 or more of 5 runs, with its card delivered.
  - A Claude Code release changes how a deny reason, a block reason or `UserPromptSubmit` context reaches the model.
  - The pattern checks written at onboarding (D15) catch materially less than this probe's scoring regexes, which
    were fed back as the checks.

  Attempts: 0.
- **Revised draft (2026-10-20, test bed):** real deployments deliver rules converted from what a repo already has,
  so the delivered rules are not written for the probe. For one task per test-bed repo (P1 first, as the pilot, with
  its cost reported before the rest), the rules that bind it are hand-converted from the repo's own rule files and
  documents, and the probe records their count and bytes against what the native setup loads for that task (P1:
  265 KB). A1's planted decisions stay as the public part. The private repos' converted text stays in
  `research/raw/` (gitignored) or the scratch clone, never in the probe folder, which holds only counts and bytes.
- **Boundary to verify:** the checks come only from the project's own rules in the map. A check that is not traced
  to an entry is out of scope (charter non-goal: code reviewer, D10).
- **Any stack (user, 2026-10-20):** a public plugin cannot ship per-language checks. A checkable rule is held either
  as a pattern the plugin reads as data (glob, regex, file exists, forbidden string), written at onboarding and
  reviewed, or by the project's own linter or validator, whose result the plugin only feeds back. The probe records,
  for each converted checkable rule, which of the two holds it, or neither; that turns "checkable" into a measured
  share.
- **Work without a write (user, 2026-10-20):** Claude also plans, designs the architecture and reviews, and none of
  these has a first write to gate. Their channels are prompt arrival, `SubagentStart` (Plan and Explore skip
  `CLAUDE.md`, D12) and accounting at `Stop`. The probe adds one such task (a plan or a review) in one test-bed repo,
  so the result is not read as covering work it did not test.
- **Evidence so far:** both failures are measured and differ: agents opened a repo's policy file in 3.5% of runs and
  ignored 25-36% of policies they had read; v1's pointers were opened in 0-4% of cases and a protocol loaded every
  session was followed 0 times in 46-78; a deterministic check fed back raised compliance to 70.1% from 55.0% for the
  same rules as text, and verification to 90-100%; the docs call `CLAUDE.md` "context, not enforced configuration"
  and only hooks apply "regardless of what Claude decides"; no study measures delivery at tool time
  ([research/2026-10-20-adherence.md](research/2026-10-20-adherence.md)).

### V2-D21 — Inventory of what exists
- **Question (split from D13, 2026-10-21):** how does v2 know what already exists in a repo (components, scripts,
  content entries), so Claude reuses instead of duplicating, without a per-language parser (any stack, charter)?
- **Draft check:** on shell, TypeScript and C# alike (the test bed), an inventory computed from file names and
  paths, or from the repo's own tools, answers "does X exist, and where" for a task's nouns; duplicates created are
  counted against it (D19's draft measure).
- **Evidence so far:** compute structure such as the component inventory from code on demand instead of storing it
  (prior-and-SOTA rules 1, 2, 7); P2's 6,740 scripts are found only by search (research
  2026-10-20-scale-real-repos).

### V2-D22 — Selection
- **Question (split from D13, 2026-10-21):** how do the entries that bind a task reach Claude, without a hand-made
  list and within 8 KB per task (D13's budget)? It covers the work with a write (a build) and the work without one
  (a plan, a review).
- **What carries over from D13:**
  - Lexical ranking at prompt time failed twice: over the sources' own blocks, and over blind-converted entries with
    applies-when terms. It held 6 and 7 of D20's 27 rules at 8 KB under the corrected held rule, against native's
    0.60 of rule-runs.
  - In R0 it delivered 5 binding entries out of 26. The keys do not separate rules inside a repo's own topic.
  - Recall is bounded by onboarding's: the converter's cited sources hold 21 of the 26 holdable rules (corrected held
    rule; 15 of 21 at the registered bar). So this decision waits for D15.
  - The converter's applies-when terms carry paths and file types in all three repos. So routing at the first
    write by the written path (option (e), D20's first-write moment) is no longer limited to P1, whose sources alone
    declare scopes.
- **Options still open:** (d) a model picks entries from candidates; (e) routing by the written path at the first
  write in an area, with prompt-time delivery for work that never writes; combinations of the two.
- **From D15 (2026-10-21):**
  - whether selection needs a project's areas, and if so how they are found (the converter's labels are per-entry
    topics);
  - the map under the user's scope is about as large as the documents;
  - a full conversion of the test bed costs about 78 USD.
- **Inputs (user, 2026-10-21):**
  - Six tasks the user wrote, two per repo, which no design step has seen. The text of P1's and P2's tasks stays
    private. All six are investigations ("find why", "check whether"), not builds.
  - Approval of the full conversion (about 78 USD).
- **Check (pre-registered 2026-10-21, before any arm runs on the six tasks;
  probe [probes/V2-D22-selection](probes/V2-D22-selection/)):**
  - *Corpus.* The three repos' full maps from D15's locked converter (sha256 `a833629588b0`, two passes, context).
    Their sizes are reported as the first real map numbers.
  - *Arms,* all at prompt time, each delivering at most 8 KB (D13). An entry costs its source line, context and
    quote.
    - (b) D13's BM25 scorer, unchanged, over each entry's file, heading path, area, applies-when terms, context and
      quote; delivered in score order.
    - (d1) BM25's top 300 entries as compact lines, then one Sonnet call (no tools) that picks the entries someone
      doing the task must follow or know, ordered by importance; delivered in that order.
    - (d2) A section index (file › h1 › h2, one line each), then one Sonnet call that picks up to 20 sections, then
      their entries, then a second call that picks and orders entries. This arm does not depend on shared words,
      and its result answers D15's carried question: whether sections serve as a project's areas.

    Prompt hashes: pick `cf6d5633de72`, sections `b6737ed2712c` (sha256, 12 characters). Nothing is tuned on the
    six tasks.
    *(e)*, routing at the first write, is not an arm: these tasks have no write to gate, and it stays D18's net.
  - *Judge.* For each task, a fresh Opus subagent, local, in two steps:
    - First, from the section index alone, it names up to 25 sections a competent person would read for the task.
      This is the deep pool, independent of the arms, and is written before step 2.
    - Then it grades every pooled entry: the union of the three arms' deliveries and every entry of its step 1
      sections, shuffled, with no provenance. Grades: *essential* (needed to do this task right), *useful*, or
      *no*. "Binds this task" means what someone doing it must follow or must know to do it right.
  - *Native.* The repo as it is run today, in D20's harness (Bash and the web off, Sonnet 5.5): two runs per task.
    Native coverage is the share of essential entries whose source file the session opened with Read.
  - *Pass, per arm, on every task:*
    - the 8 KB delivery holds at least 80% of the judge's essential entries; where the essential entries exceed
      8 KB, at least 80% of the delivered bytes are essential instead;
    - at least 60% of the delivered bytes are essential or useful.

    D22 locks the passing arm with the fewest model calls per prompt, in the order (b), (d1), (d2). A task whose
    essential set exceeds 8 KB is a finding about D13's budget, not an arm's failure.
  - *Reported:*
    - recall of the essential entries against the deep pool alone (the honest number);
    - essential and useful set sizes in KB per task;
    - native coverage;
    - per arm: time per prompt, model calls, tokens and cost;
    - index build time;
    - the full map sizes.
  - *Smoke first* on one of D20's four tasks, already burned, counting entries only.
  - *Attempts, planned now:*
    - attempt 2 is (d1) with 600 candidates, drawn from BM25 together with (d2)'s sections;
    - attempt 3 is (d2) with up to 40 sections.

    The judge's grades do not feed back into any selector.
  - *Cost:* the conversion about 78 USD (approved); the arms 1 to 2 USD; native 10 to 20 USD.
- **Run notes (2026-10-21):**
  - *The first full maps,* from D15's converter:

    | Repo | Windows | Entries | Quote text | Verify-pass share | With context | Cost |
    | --- | --- | --- | --- | --- | --- | --- |
    | P1 | 635 | 7,140 | 1.3 MB | 14% | 3,044 | 25.52 USD |
    | P2 | 1,615 | 14,119 | 1.8 MB | 8% | 4,389 | 48.39 USD |
    | R0 | 717 | 5,956 | 1.0 MB | 10% | 2,186 | 22.15 USD |

    No window failed. The total, **96.06 USD, overran the 78 USD estimate the user approved by 18 USD**, because the
    estimate was low. The user is told.
  - *Native:* 12 runs, all valid, 7.73 USD. The R0 sessions opened code files only, no documents, and searched the
    documents with Grep, which a coverage counted by Read does not credit.
  - *Harness fix, disclosed.* On P2-crafting, arm (d2)'s section pick failed to parse, because a note followed the
    JSON array. The parser now takes the first array, bracket by bracket. Only (d2) was rerun for that task, before
    its judge saw any pool. The other arms' saved results stand, and no other run had an error.
  - *Smoke* on D20's P1 task (burned): (b) 21 entries, (d1) 22, (d2) 28; no errors.
- **Attempt 1 result (2026-10-21): fail. No arm passes on all six tasks**
  ([results/summary.json](probes/V2-D22-selection/results/summary.json)). One fresh Opus judge per task graded pools
  of 352 to 756 entries. The tasks below are named by repo and number. "Essential" is the share of the judge's
  essential entries delivered; "relevant" is the share of delivered bytes graded essential or useful.

  | Task | Essential set | (b) essential / relevant | (d1) essential / relevant | (d2) essential / relevant | Native (Read) |
  | --- | --- | --- | --- | --- | --- |
  | R0 task 1 | 25, 8.8 KB | 0.04 / 0.12 | 0.08 / 0.87 | 0.48 / 1.00 | 0 |
  | R0 task 2 | 32, 10.9 KB | 0.38 / 0.87 | 0.63 / 1.00 **pass** | 0.53 / 1.00 | 0 |
  | P1 task 1 | 28, 10.0 KB | 0.00 / 0.15 | 0.11 / 0.80 | 0.29 / 0.82 | 0.39 |
  | P1 task 2 | 30, 11.0 KB | 0.07 / 0.47 | 0.20 / 0.97 | 0.27 / 1.00 | 0.33 |
  | P2 task 1 | 45, 17.9 KB | 0.13 / 0.40 | 0.36 / 1.00 **pass** | 0.38 / 1.00 **pass** | 0 |
  | P2 task 2 | 26, 8.2 KB | 0.15 / 0.84 | 0.42 / 1.00 | 0.23 / 0.88 | 0.27 |

  - *What it shows:*
    - The model arms deliver almost only relevant entries: 0.80 to 1.00 of their bytes.
    - They deliver only 8% to 63% of the essential entries.
    - Every essential set but one exceeds 8 KB: 8.2 to 17.9 KB, 25 to 45 entries per task. That is the
      pre-declared D13 budget finding.
    - Plain BM25 fails everywhere.
    - Native sessions opened, with Read, the files of 0 to 39% of the essential entries. The R0 sessions read only
      code, so Grep-based reading is not credited.
  - *Runtime:* (b) 6 to 20 ms per prompt after a 0.1 to 0.3 s index build; (d1) 4 to 10 s and about 0.21 USD;
    (d2) 10 to 18 s and 0.25 to 0.71 USD.
  - *Native, both bounds.* Counting files the sessions also met in search results (Grep), native sessions touched the
    files of 39% to 100% of the essential entries, against 0% to 39% by Read. Read understates exposure; a search hit
    on another line of the same file overstates it. R0 task 1's two runs scored 1.00 and 0.00, so single native runs
    vary as much as the arms do.
  - *Limits.* Each arm picked once per task, so pick variance is unmeasured, and "pass on all six" with single shots
    is stricter than it reads. One judge per task graded 350 to 750 entries in one pass, so the line between
    essential and useful is one reading.
- **The bar, corrected (2026-10-21, disclosed; the registered scores stand).** Where the essential set exceeds 8 KB,
  the registered condition, "80% of the delivered bytes are essential", rewards a tiny delivery that is all
  essential. The correction: such an arm must deliver at least 6.4 KB of essential entries, 0.8 of the budget. It
  flips no attempt 1 verdict: the three passes were 7.9 KB deliveries at 0.83 to 0.92, and a stricter bar cannot turn
  a fail into a pass. The stage count below ran before this rule was written into the ledger. The rule came from the
  review; the count is descriptive, and nothing was tuned.
- **Attempts 2 and 3 are ruled out by count, not run (2026-10-21).** Essentials outside the pool are ungraded, so
  these counts are lower bounds.
  - *Attempt 2* (600 candidates together with (d2)'s sections): P2's task 2 candidate set holds 5.9 KB of graded
    essentials, under the 6.4 KB needed. R0's task 1 holds exactly 6.4 KB, so it would need a pick that takes every
    essential and nothing else. No arm did that on any task: essentials delivered of those among the candidates were
    2/4, 3/3, 6/12, 11/16, 20/31 and 16/19.
  - *Attempt 3* (40 sections): on P1's two tasks, (d2)'s 20 sections already held 25 and 27 of the 28 and 30
    essentials, and the pick delivered 8 of each. The loss is the pick, not the candidates, so more sections do not
    reach it.
- **Status: BLOCKED (2026-10-21) on an assumption; rule 4 sends it up.** The assumption: *a single push of at most
  8 KB at prompt time, chosen by one model pick, holds a task's essential knowledge.* Two measured breaks:
  - the essential set is 8.2 to 17.9 KB on five of six tasks;
  - the pick separates relevant from irrelevant (0.80 to 1.00 of its bytes) but not essential from useful (an
    essential share of 0.17 to 0.37 on the failed tasks).

  Both passes came where BM25's candidates were already rich in essentials (R0's task 2: 31 of 32 in the top 300;
  P2's task 1: 19), so shared words between the task and the rules predicted success. How much context a task gets,
  and by what route, is a product question with a cost. It goes to the user with these numbers.
- *Spend on D22:* about 108.50 USD. That is the conversion 96.06, native 7.73, the arms 4.15 and the smoke 0.47,
  against the approved 78 USD conversion and the 10 to 20 USD native estimate.
- **User answer (2026-10-21): route.** "Pick + pointers, then on read", the recommended option.
  - At a task's first prompt, one model pick pushes the top essential entries, at most 8 KB, together with a list of
    the relevant sections.
  - Whenever Claude then opens a file, that file's map entries are added, with no model call.

  The other options shown were: raise the push to the platform's limit; pointers and on-read delivery with no model;
  or a lookup Claude calls itself. D22 re-checks under this route.
- **Run 2 check (pre-registered 2026-10-21, before the smoke; run 2 overall, after the block):**
  - *The push* is (d2)'s saved output: its picked entries (at most 8 KB) and its picked sections as pointers (file ›
    heading lines). (d1) is not used, because it yields no section list without a third call; that reason is
    structural, not attempt 1's scores. The saved picks were made before any grade existed. The pick runs offline
    here; running it inside a `UserPromptSubmit` hook (4 to 18 s against the hook timeout, and a nested `claude`) is
    D18's test.
  - *On read:* a `PostToolUse` hook matched to Read ([onread.mjs](probes/V2-D22-selection/onread.mjs)). For a Read
    of a repo file, it delivers the map entries of that file in source order, with these limits:
    - at most 8 KB per file, once per file per session;
    - entries already pushed are not repeated;
    - nothing for a file with no entries (code files).

    No ranking inside the file, because that would be a selector, and selectors are what failed. Every delivery is
    logged.
  - *Arrival first* (D12's rule). The docs support `additionalContext` on `PostToolUse` (capped at 10,000
    characters); a Read matcher is not documented. Three Haiku runs give the channel a nonce from the environment
    ([arrival.mjs](probes/V2-D22-selection/arrival.mjs)), counting only runs where the hook fired. 3 of 3 is
    required; otherwise the route needs another second channel, and that question goes to the user.
  - *Sessions:* D20's harness, arm `r`, two Sonnet runs per task, Bash and the web off, at the same commits.
  - *Measure:* reach, the share of the judge's essential entries (attempt 1's graded set) that reached Claude by
    either channel. **Pass: the mean over the two runs is at least 0.8 on every task.**
  - *Reported, with no bar:*
    - KB delivered per session, split between push and on-read;
    - files read and files delivered;
    - hook time;
    - cost per session;
    - the graded share of delivered bytes, and the relevant share among them;
    - native's coverage alongside.

    The on-read channel is scoped by file, so its relevance will be lower than the push's; that is said before
    the run.
  - *Fresh and not fresh.* The push half is not fresh, because the tasks have been seen next to their grades.
    The on-read half depends on what Claude reads in live sessions, which nobody has seen.
  - *Cost:* about 10 to 20 USD for 12 Sonnet sessions, plus the Haiku smoke. *If run 2 fails,* the question goes
    back to the user; no run 3 is planned.
- **Run 2 result (2026-10-21): fail.** ([results/reach.json](probes/V2-D22-selection/results/reach.json),
  [results/arrival.json](probes/V2-D22-selection/results/arrival.json))
  - *Arrival:* `PostToolUse` `additionalContext` after a Read reached Haiku in 3 of 3 runs, so the channel carries
    content.
  - *Plumbing fix found by the Haiku smoke, before any Sonnet run (disclosed).* The push with its pointers came to
    10.5 KB, over the platform's 10,000-character cap, above which Claude gets only a 2,000-character preview. The
    push now fills what the pointers leave of 9,500 bytes.
  - *Reach:* the mean of two Sonnet sessions was 0.40 and 0.50 on R0's tasks, 0.32 and 0.27 on P1's, and 0.31 and
    0.29 on P2's. All 12 sessions were valid; they cost 4.97 USD.
  - *Why.* The on-read channel delivered in 2 of 12 sessions. On these investigation tasks Claude read code files
    (up to 16 reads per session) and opened almost none of the documents the map's entries come from, and it did
    not follow the pointers. So reach came from the push alone: 4.2 to 6.5 KB of entries once the pointers took
    their share, which is 23% to 50% of the essentials. Where a document was read, its delivery added 4 to 8 KB at
    a relevant share of 0.66 to 0.90.
  - *The assumption that failed this time:* that Claude opens the documents a task's knowledge lives in. In
    investigation tasks it reads the code. Delivery keyed to a document read misses; delivery keyed to the code file
    being read is not tested. The converter's applies-when terms name code paths, as D13 found.
  - *Spend on D22:* about 113.50 USD.

  Attempts: 1 (attempts 2 and 3 ruled out by count), then run 2 under the user's route: fail. Per the
  pre-registration, the question goes back to the user.

  Attempts: 1 (attempts 2 and 3 ruled out by count).
- **Constraint for its check:** everything seen so far was diagnosed per card against D20's 27 rules, so a key
  designed now is fitted to them. The check needs tasks, or binding rules, that no design step has inspected (new
  tasks in the same repos), with D13's corrected held rule.
