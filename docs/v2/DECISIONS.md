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
| V2-D13 | What does an entry hold, and how do a task's entries reach Claude without a hand list, within what budget? (narrowed 2026-10-21) | CHECKING | evidence | D10, D11, D12, D20 |
| V2-D14 | How does knowledge enter the map, and who may write it? | OPEN | user + evidence | D11, D13 |
| V2-D15 | Onboarding: how does the plugin turn a repo's existing rules into the map, or map a repo that has none? | OPEN | evidence | D13 |
| V2-D16 | How does the map stay fresh? | OPEN | evidence | D13 |
| V2-D17 | How is value measured (eval tasks, arms, thresholds)? | LOCKED 2026-10-20 | evidence + user | D10 |
| V2-D18 | What runs where (runtime, hooks, MCP) and what is the surface budget? | OPEN | evidence | D12, D13, 02-v1-postmortem.md |
| V2-D19 | How is value measured at scale: a large repo with big documents, where context fills quickly? | OPEN | user + evidence | D10, D17 |
| V2-D20 | By what mechanism does v2 make Claude follow the knowledge that binds a task, once delivered? (Finding it: D13, D18) | LOCKED 2026-10-21 | evidence | D12, D17 |
| V2-D21 | How does v2 know what exists in a repo (its inventory) without a per-language parser? | OPEN | evidence | D10, D13 |

Frontier (rule 6): **D13**. D20 is locked for following (2026-10-21). D13's check now includes selection: its index
or router has to bring the same 27 rules D20 delivered by hand. Then **D15**: the pipeline is convert, then format,
then enforce. D14, D16 and D18 wait for D13. D19's v2 arm (map item 6b) also waits for D13.

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

  Attempts: 1.

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
  D18 (what runs where, and its surface budget), measured against the same 27 rules.
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
