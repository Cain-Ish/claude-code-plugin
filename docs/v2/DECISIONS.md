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
| V2-D10 | Scope: which knowledge does v2 hold, and what is out of scope? | LOCKED 2026-10-20 | user | — |
| V2-D11 | Where does a repo's knowledge live? | LOCKED 2026-10-20 | user + evidence | D10, D12 |
| V2-D12 | Which delivery channels actually arrive, and where? | LOCKED 2026-10-20 | evidence | — |
| V2-D13 | What is the shape of the project map, and its token budget? | OPEN | evidence | D10, D11, D12 |
| V2-D14 | How does knowledge enter the map, and who may write it? | OPEN | user + evidence | D11, D13 |
| V2-D15 | How is a map bootstrapped for an existing repo? | OPEN | evidence | D13 |
| V2-D16 | How does the map stay fresh? | OPEN | evidence | D13 |
| V2-D17 | How is value measured (eval tasks, arms, thresholds)? | CHECKING | evidence + user | D10 |
| V2-D18 | What runs where (runtime, hooks, MCP) and what is the surface budget? | OPEN | evidence | D12, D13, 02-v1-postmortem.md |

Frontier (rule 6): **D17** (needs only D10; checking, its tasks wait for the user) and **D13** (needs D10, D11, D12).
The map runs D17 first.

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

### V2-D10 — Scope and role knowledge
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
- **Choice:**
  - v2 holds, or derives from the repo (D13 decides which), the knowledge of three roles: lead developer
    (structure, conventions, decisions with their rejected options), PM (goals, scope, priorities, what is in
    flight) and designer (design system, component inventory, UX rules).
  - A role is an attribute of a piece of knowledge (who asserted it, in which role) within the one map of a repo.
    It is not a persona agent and not a separate store. How the attribute is written down (tags or otherwise) is
    D13's.
  - QA and ops knowledge is DEFERRED (trigger below).
  - Out of scope: the charter's non-goals ([00-charter.md](00-charter.md#what-v2-is-not-confirmed-by-v2-d10)),
    confirmed as written; a personal-preference layer (Claude Code's auto memory holds it, and v2 builds none); any
    automatic import of v1's `~/knowledge` store.
  - v1's `~/knowledge` data may seed a map at most once, as proposals the user reviews entry by entry (PM5). How a
    map is seeded is D15's.
- **Rejected:** persona agents per role (agents control context, they are not job titles: Ultimate Guide finding
  30; v1's role card, keyed on agent type, delivered a test-first card to a research dispatch: prior-and-SOTA A33);
  all five roles from the start (D17's question has acceptance tasks for lead, PM and design only, so QA and ops
  would add surface no eval measures, PM6); a v2 personal layer (it duplicates auto memory, which D12 found
  reaching the main session, general-purpose and plugin agents); an automatic v1 import (v1's store came from
  unreviewed LLM extraction over transcripts, PM5, and had one author, PM4).
- **Reopen if:** the user adds or drops a role or a non-goal; the first slice's eval shows a role's knowledge
  changes no acceptance outcome; Claude Code removes or restricts auto memory. **QA and ops trigger:** the
  three-role first slice meets its D17 thresholds and a repo in use holds QA or ops knowledge worth delivering.
  Attempts: 0.
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
- **Choice:** (a). A repo's team knowledge (the D10 roles) lives in plain files committed to that repo and changes
  through reviewed commits. Anything machine-local (an index, a cache) is rebuilt from those files by one command
  (PM4). One person's preferences stay in auto memory (D10). Where in the repo, and in which files, is D13's.
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
  and correcting one entry with the plugin disabled (PM4's format half, moved here from D11).
- **Evidence so far:** store only what the code cannot say, and no generated overviews (arXiv 2602.11988: −0.5 to
  −2 points, +20-23% cost); the always-on layer is a routing index under ~3,000 chars (arXiv 2606.20512: +4.7 points,
  all from reaching the right file); compute structure such as the component inventory from code on demand
  instead of storing it (prior-and-SOTA rules 1, 2, 7).

### V2-D14 — Capture and trust
- **Question:** how knowledge enters (explicit command or skill; Claude proposes a map edit as part of the diff;
  end-of-session suggestion; never raw transcript mining?), who may write it, and how untrusted text is kept out.
- **Draft check:** user answer on the review model; a probe that a poisoned tool output cannot reach the map without
  appearing in a reviewable diff.
- **Evidence so far:** capture explicitly at decision points; background extraction only proposes (prior-and-SOTA
  rule 9: 43 of 44 kept learnings were explicit); treat every memory write as untrusted (rule 10: MINJA 98.2%
  injection success). v1's unreviewed LLM extraction became a persistent prompt injection (post-mortem cause 5).
  Contested: the Ultimate Guide prefers capture in hooks (zero model tokens).

### V2-D15 — Bootstrap
- **Draft check:** a prototype bootstrap on two repos; a human reviewer accepts at least 80% of the generated
  entries as correct and useful, and the generated index stays under the D13 cap.

### V2-D16 — Freshness
- **Question:** claims carry anchors (path, symbol, test); a deterministic check (git and regex, no model) flags
  drift; flagged claims are never delivered as current.
- **Draft check:** seeded drift (rename, delete, edit) on a sample map; the check flags 100% of seeded cases and
  0 false alarms on an unchanged tree.
- **Evidence so far:** every record carries code anchors, provenance and a verified-at commit, checked before
  delivery (prior-and-SOTA rule 6: GitHub Copilot Memory). v1 delivered a lesson citing line numbers that had moved
  (concept §2).

### V2-D17 — Measurement
- **Question:** acceptance tasks (A1 plus lead, PM and design scenarios), arms (no plugin; native `CLAUDE.md` only;
  v2), metrics (charter table), and pre-registered thresholds.
- **Check (proposed 2026-10-20; pre-registered once the user confirms the tasks):** the tasks, arms, metrics and
  protocol are in [05-eval-plan.md](05-eval-plan.md). The check passes when (1) the user confirms the tasks, the
  no-plugin arm's contents, the model and the run count; (2) the harness in `probes/V2-D17-eval/` (Node, no npm
  packages, at most 400 lines without fixture and tasks) passes the smoke check: every gold answer passes all its
  items, each planted wrong answer fails exactly its own item, and no task prompt contains an answer token; (3) B0
  (no plugin) and B1 (native `CLAUDE.md`) run 5 times on every task, all runs valid; (4) the thresholds are written
  into 05-eval-plan.md from those runs by its rule (a margin larger than B1's run-to-run spread), never guessed in
  advance (Gemini review). If B0 passes every item in every run, the fixture measures nothing: a failed attempt, and
  the fixture changes. If B1 passes every item in every run, D17 records that v2's case rests on orientation and
  cost, and the user sees it before any threshold is set. The harness stays small; v1's had 2,710 lines and never
  ran.

### V2-D18 — Runtime and surface budget
- **Question:** which code runs where, which hook events (if any) v2 uses, the latency budget per hook, whether an
  MCP server is needed, and the maximum count of skills, agents, hooks and scripts.
- **Draft check:** derived from D12 and the post-mortem's rules; every hook named with a measured p95 under load
  below its budget on Windows.
- **Evidence so far:** one v1 Edit ran 8 hooks and at least 52 processes; under load a spawn cost 314 ms and about
  217 guard runs failed open (post-mortem cause 3, proposing at most one non-shell hook per event, p95 ≤ 100 ms at 8
  concurrent sessions). A PreToolUse timeout fails open unless the hook sets `"onFailure": "block"` (CLI ≥ 2.1.295;
  platform note §7).
