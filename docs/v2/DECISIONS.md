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
| V2-D13 | What is the shape of the project map, and its token budget? | OPEN | evidence | D10, D11, D12, D20 |
| V2-D14 | How does knowledge enter the map, and who may write it? | OPEN | user + evidence | D11, D13 |
| V2-D15 | Onboarding: how does the plugin turn a repo's existing rules into the map, or map a repo that has none? | OPEN | evidence | D13 |
| V2-D16 | How does the map stay fresh? | OPEN | evidence | D13 |
| V2-D17 | How is value measured (eval tasks, arms, thresholds)? | LOCKED 2026-10-20 | evidence + user | D10 |
| V2-D18 | What runs where (runtime, hooks, MCP) and what is the surface budget? | OPEN | evidence | D12, D13, 02-v1-postmortem.md |
| V2-D19 | How is value measured at scale: a large repo with big documents, where context fills quickly? | OPEN | user + evidence | D10, D17 |
| V2-D20 | By what mechanism does v2 make Claude look for and follow the knowledge that binds a task? | OPEN | evidence | D12, D17 |

Frontier (rule 6): **D20 stage 1** first: Claude in the three test-bed repos as they are run today, which checks the
premise that it misses their rules there and finds out how (research 2026-10-21-rethink); the same runs are D19's
native baseline. Then **D20 stage 2** (mechanism arms only for the failures stage 1 shows), **D13**, **D15** (the
pipeline is convert, then format, then enforce). D14, D16 and D18 wait for D13.

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
- **Evidence so far:** store only what the code cannot say, and no generated overviews (arXiv 2602.11988: −0.5 to
  −2 points, +20-23% cost); the always-on layer is a routing index under ~3,000 chars (arXiv 2606.20512: +4.7 points,
  all from reaching the right file); compute structure such as the component inventory from code on demand
  instead of storing it (prior-and-SOTA rules 1, 2, 7).

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
- **Reopen if (to carry into the lock):** D13's format changes what can be delivered verbatim.
- **Evidence so far:** both failures are measured and differ: agents opened a repo's policy file in 3.5% of runs and
  ignored 25-36% of policies they had read; v1's pointers were opened in 0-4% of cases and a protocol loaded every
  session was followed 0 times in 46-78; a deterministic check fed back raised compliance to 70.1% from 55.0% for the
  same rules as text, and verification to 90-100%; the docs call `CLAUDE.md` "context, not enforced configuration"
  and only hooks apply "regardless of what Claude decides"; no study measures delivery at tool time
  ([research/2026-10-20-adherence.md](research/2026-10-20-adherence.md)).
