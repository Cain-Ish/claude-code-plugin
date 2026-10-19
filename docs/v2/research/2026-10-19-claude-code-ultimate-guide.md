# Research: what the Claude Code Ultimate Guide teaches a v2 "second brain" plugin

Source: `FlorianBruniaux/claude-code-ultimate-guide`, shallow clone of `main` at commit `e784ef1` (2026-10-19), `VERSION` 3.44.1.
All paths below are relative to that repository. The guide was read as data: no scripts, installers or package managers from it were run.

Question this note answers: how far can built-in Claude Code features take a per-repo "mindmap" of senior-team knowledge (structure, conventions, past decisions, role perspectives), and what is left for a plugin to do?

---

## 1. Overview of the guide

1. **Scope.** A community guide to Claude Code: 150 files under `guide/`, 116 of them Markdown (the rest are images). The main file is `guide/ultimate-guide.md` (25.9K lines). There are focused deep dives: `guide/core/memory-systems.md`, `guide/core/context-engineering.md` and `guide/core/hooks-events-reference.md`. Ecosystem surveys sit in `guide/ecosystem/` and workflows in `guide/workflows/`. Runnable templates are in `examples/` and source evaluations in `docs/resource-evaluations/`.
2. **Version and freshness.** Guide v3.44.1, README dated 2026-10-17. The hooks reference says it was checked against Claude Code v2.1.284, and pricing was checked on 2026-10-06. `CHANGELOG.md` is about 1 MB, which points to high churn and frequent re-verification.
3. **Author.** Florian Bruniaux, a single author: AI Founding Engineer at Méthode Aristote and former CTO/VP Eng. Several "measured results" come from his own team (5 developers, TypeScript), which is one team.
4. **Credibility signals (positive).**
   - Each section carries an explicit confidence tier (`guide/core/memory-systems.md` header; `guide/core/architecture.md` "Source category" lines).
   - Unconfirmed tools and numbers are tagged `[UNVERIFIED]`.
   - The guide publishes retractions. `docs/resource-evaluations/agents-md-empirical-study-2602-11988.md` withdraws earlier cost, success and file-length claims, and `guide/core/context-engineering.md` §2 withdraws the "150-instruction ceiling" and the "adherence by file size" numbers.
   - Machine-readable indexes have validators (`guide/ultimate-guide.md` §9.18.4).
5. **Credibility signals (negative).**
   - Some withdrawn claims survive in other sections (details in §6 below).
   - A few hook samples contradict the guide's own hooks reference.
   - Self-description drift: `guide/core/memory-systems.md` §3.7 says the repo runs `.claude/rules/retex-review.md`, but `.claude/rules/` in this commit holds only `index-sync.md`.
   - Several adoption numbers ("60% fewer hallucinations at Anthropic", "3x API adoption") are not sourced.
6. **Stance.** "Native first, measure before adding infrastructure." The guide repeatedly says to start with versioned Markdown and add retrieval only when the agent demonstrably misses known documents.
7. **Relevance to v2.** Very high. The guide surveys about 20 memory tools, defines the native memory stack precisely, and names the open problems (provenance, staleness, team conflicts, token-budgeted retrieval) that v2 could target.

---

## 2. Findings

**Confidence key**
- **Doc**: documented product behaviour (the guide cites official docs or release notes).
- **Measured**: a number backed by a named benchmark, with its sample noted.
- **Vendor**: a number reported by the tool's own author.
- **Opinion**: the author's recommendation or synthesis.
- **Inconsistent**: the guide contradicts itself on this point.

**Design question key**
- **home**: where knowledge lives.
- **channel**: how it reaches the model.
- **map**: the structure of the mindmap.
- **capture**: how knowledge gets written.
- **fresh**: how it stays current.
- **budget**: token budget.
- **team**: team sharing.
- **sec**: security.

| # | Finding | Source (guide path, section) | Informs | Confidence |
|---|---|---|---|---|
| 1 | Memory splits into three tracks: the native stack (CLAUDE.md, MEMORY.md, Auto Memory, Auto Dream), single-user cross-session tools, and team or multi-agent memory. The native stack is said to cover "80% of solo needs". Team dynamic memory "has no dominant solution", and the gap is "structural": every leading tool is single-tenant by design. The guide's "correct bet today", which is what v2 competes against: CLAUDE.md + `.mcp.json` for static team knowledge, plus Notion MCP or Mem0 cloud for dynamic knowledge. | `guide/core/memory-systems.md` §1, §4.7 | home, team | Opinion (well argued) |
| 2 | Hook-driven writes beat MCP-driven writes. Extraction in a hook costs no model tokens and does not depend on the agent deciding to remember. A voluntary MCP store call costs 20–50 tokens per call. Tools that "won" in 2026 did so through lifecycle hooks, not better storage. | `guide/core/memory-systems.md` §1, §3.3, §6.1, §6.6 | capture | Opinion + Vendor (ICM per-call tokens) |
| 3 | Auto Memory limits are applied at read time: `MEMORY.md` is truncated at 200 lines, then at 25 KB, and the memory directory is capped at 200 files (oldest pruned). It is per-user and gitignored, and shared across worktrees since v2.1.63. `autoMemoryDirectory` is refused in project settings, so a repo cannot redirect memory writes. | `guide/core/memory-systems.md` §2.2; `guide/core/settings-reference.md` "Plans and memory" | home, budget, sec | Doc. The guide also lists a project path `.claude/memory/MEMORY.md`; verify that path against the official docs. |
| 4 | Auto Dream is a background consolidation subagent. It was found by reverse-engineering and sits behind a server-side flag. It runs only when both conditions hold: ≥24 h and ≥5 sessions since the last run. Its four phases are orient, gather signal (targeted grep of transcripts), consolidate (absolute dates, drop contradicted facts, dedupe) and prune to under 200 lines. Known gaps: it writes facts it has not checked, keeps no audit trail, and leaves files orphaned when a project is renamed. Fresh projects get no benefit. | `guide/core/memory-systems.md` §2.3, §2.6 | fresh, capture | Opinion (community reverse-engineering) |
| 5 | Agent memory frontmatter `memory: user\|project\|local` (v2.1.33). On start, the first 200 lines of the agent's `MEMORY.md` go into its system prompt, and topic files are read on demand. `project` scope is committed under `.claude/agent-memory/<name>/`. This is the only native layer that the agent writes and the team shares through git. | `guide/ultimate-guide.md` §4.5; `guide/core/memory-systems.md` §2.4 | home, team | Doc |
| 6 | Discoverability filter: before adding a line to CLAUDE.md, ask "can the agent find this by reading the code?" If yes, leave it out. Anchoring risk: every line loads every session, so a stale entry biases every prompt. Prefer the strongest enforceable control (lint, type, test, hook) over a CLAUDE.md line. | `guide/core/memory-systems.md` §2.1 | home, fresh | Opinion |
| 7 | Recommended layout: CLAUDE.md as a routing index under 100 lines; domain rules in `.claude/rules/*.md`, scoped with `paths:` frontmatter; procedures in skills. Size target for all CLAUDE.md levels combined is 4–8 KB. One team (Avo) moved a 600-line CLAUDE.md into about 15 path-scoped files. | `guide/ultimate-guide.md` §3.1 "Modular context architecture", §3.4 "Path-Specific rules"; `guide/core/context-engineering.md` §4 | channel, budget | Doc (mechanism) + Opinion (sizes) |
| 8 | Loading semantics that matter for v2: (a) a `paths:` rule loads when a matching **Read/Write/Edit** happens, not when the user states an intent; (b) `@path` imports load together with the file that imports them, so they are never conditional; (c) a `globs:` field is not recognised and leaves the rule silently unscoped; (d) a nested `CLAUDE.md` loads when Claude works in that subtree; (e) loaded content does not unload when the task changes. Check with `/context`. | `guide/core/context-engineering.md` §3 "Import chain", §4 "Path-scoping pattern"; `guide/ultimate-guide.md` §3.4 | channel, budget | Doc |
| 9 | Skills were auto-invoked in only 56% of cases in Vercel's eval. Pass rates: an 8 KB static docs index reached 100%; skills reached 53% (same as baseline) or 79% with explicit instructions. Compressing the docs from about 40 KB to 8 KB lost nothing. The sample was 19 tasks. The guide's conclusion: critical knowledge should be loaded up front, and supplementary knowledge can be on demand. | `docs/resource-evaluations/025-vercel-agents-md-vs-skills-eval.md`; `guide/ultimate-guide.md` §3.4 "Memory loading comparison" | channel | Measured (small sample, third party) |
| 10 | Skill descriptions have a budget: `SLASH_COMMAND_TOOL_CHAR_BUDGET`, which scales at 1% of the context window. `/skill-doctor` (v2.1.252+) reports the visible context cost of skills and lists skills never invoked. Subagents do not inherit skills: each must be listed in the agent's `skills:` field, and listed skills load up front. Built-in Explore and Plan agents cannot use skills. | `guide/core/settings-reference.md`; `guide/core/context-engineering.md` §12; `guide/ultimate-guide.md` §5.1 "Skills and subagents" | channel, budget | Doc |
| 11 | Structure and rules are different kinds of context. Proposed pattern: an auto-generated `code-map.yaml` under 1K tokens with five sections: `layers` (root + file count), `component_domains`, `nested_contexts`, `stats`, `key_paths`. It is registered in a CLAUDE.md "Context Indexes (load on demand)" pointer table, never `@imported`, and never hand-edited ("auto-generated files cannot lie"). Template: `examples/context-engineering/code-map-template.yaml`. | `guide/core/context-engineering.md` §4 "Structural metadata files" | map, fresh, budget | Opinion (one production team) |
| 12 | Keep document types separate: CLAUDE.md holds rules; `docs/solutions/` holds solved problems; `docs/brainstorms/` holds thinking; `docs/plans/` holds active plans. Reason given: "an AI reading CLAUDE.md expects constraints … when these get mixed, the AI treats old decisions as current rules." | `guide/ultimate-guide.md` §3.1 "The documentation hierarchy as project memory" | map, home | Opinion (Every.to pattern) |
| 13 | ADRs go in `docs/decisions/` and are referenced from code comments ("Soft delete per ADR-007") so a grep on code reaches the decision. Other discoverability aids: a README per major directory stating its conventions and forbidden dependencies; full names plus synonyms in comments; JSDoc facets (`@domain`, `@related`, `@external`). | `guide/ultimate-guide.md` §9.18.2, §9.18.3 | map, channel | Opinion. The impact numbers in §9.18.1 are unsourced. |
| 14 | OKF (Open Knowledge Format v0.1, Google Cloud, 2026-06-12) formalises Karpathy's "LLM wiki". A bundle is a directory of Markdown files with YAML frontmatter where `type` is required; the file path is the identity; links act as untyped graph edges; `index.md` and `log.md` are reserved; consumers must tolerate broken links and unknown fields. The bundle is referenced from CLAUDE.md. | `guide/ultimate-guide.md` §9.18.5 | map | Doc (early external spec; Google-only adoption) |
| 15 | The OpenAI Codex team's pattern (as the guide reports it): AGENTS.md of about 100 lines as a table of contents; a `docs/` knowledge base (`design-docs/core-beliefs.md`, `exec-plans/active\|completed`, `generated/` that is never hand-edited, `product-specs/`, `references/*-llms.txt`); CI linters that fail on broken links; a recurring doc-gardening agent that opens PRs when docs drift from code. | `guide/ultimate-guide.md` §9.25.1, §9.25.3 | map, fresh | Opinion (as reported from the OpenAI blog) |
| 16 | "Keep each kind of truth with its owner": architecture in repo ADRs, requirements in the issue, organisational context in the knowledge base, live state in the operational system. Do not copy live state into a Markdown snapshot. Company knowledge comes in three shapes: static docs (git vault), live systems (MCP connector) and workflows (plugin). "Content in the vault, behaviour in the plugin." | `guide/ultimate-guide.md` §9.25.2; `guide/ecosystem/team-knowledge-base.md` "One Tool for Three Needs", "The plugin pattern" | home, team | Opinion |
| 17 | Add RAG only when needed. Direct file reads are more accurate. The guide puts the crossover at about 100–1,000 documents; the signal to cross it is "the agent repeatedly misses documents you know exist". RAG over rules earns its cost only past about 50 rule files. A first cleanup pass typically removes 30–50% of fixed context with no infrastructure. | `guide/ecosystem/team-knowledge-base.md` Tier 3; `guide/core/context-engineering.md` §15 "The RAG question" | home, budget | Opinion (thresholds are heuristics) |
| 18 | Match retrieval to query shape. Coding queries (error strings, symbols) suit BM25; DiffMem dropped BM25 because its queries were natural-language questions about people. Hybrid BM25 + vector + graph fused with RRF scored +9 pp R@5 over BM25 alone (95.2% vs 86.2%) on agentmemory's own published harness. Pure vector search "smears exact-match signal". | `guide/core/memory-systems.md` §3.7 "The lesson", §6.5, §9 | map, channel | Vendor (reproducible corpus published) |
| 19 | A tested prompt-time router (BM25 skill hints on `UserPromptSubmit`). Output: at most 3 candidates in at most 500 characters, no confidence %, silent on a miss. Contrastive negatives veto a candidate. Calibration: per-skill F1 ≥ 0.60 and global F1 ≥ 0.70. Acceptance: precision ≥ 0.80 and zero forbidden hits. Warm latency p95 < 75 ms. Cache keyed by repo + cwd. Logs never contain prompt text. Training examples are not used as acceptance evidence. | `guide/workflows/smart-suggest-routing.md`; `examples/hooks/bm25-routing/` | channel, budget | Doc (implementation with tests) |
| 20 | Hook limits: `additionalContext` is capped at 10,000 characters; `UserPromptSubmit` times out at 30 s by default (a stuck hook blocks input); `SessionEnd` gets a 1.5 s budget, and plugin timeouts do not raise it. `SessionStart` can return `additionalContext`, `watchPaths` and `reloadSkills`. `InstructionsLoaded` reports `load_reason` (session_start / nested_traversal / path_glob_match / include / compact), which makes rule loading auditable. | `guide/ultimate-guide.md` §7.2 "Per-Event Input/Output Reference"; `guide/core/hooks-events-reference.md` | channel, budget | Doc (checked against v2.1.284) |
| 21 | "Silent success" hooks: emit nothing on success and output only on failure. The guide's arithmetic: 500 characters per call × 150 calls is about 19K tokens per session. Flag any hook that injects more than 200 characters per Pre/PostToolUse call. | `guide/ultimate-guide.md` §7.2 "Silent Success Pattern"; `guide/core/context-engineering.md` §15 step 4 | budget | Opinion. "All stdout enters context" is overbroad; `additionalContext` is the injection path. |
| 22 | Cache mechanics: CLAUDE.md is sent as message content (a system-reminder), not in the system prompt. Editing CLAUDE.md or other stable content invalidates the cache once. Dynamic values (dates, branch, timestamps) should go late in the request. The tool list is locked at session start. Every injected token is re-read on later turns at 0.1× price. Blocks below a per-model minimum (512–4,096 tokens) are never cached. | `guide/ecosystem/context-engineering-tools.md` §8; `guide/ultimate-guide.md` §2.2 "How Claude Code handles caching automatically" | budget | Opinion (analysis) + Doc (pricing) |
| 23 | Cache bug: `--resume` rebuilt 87–118K tokens as cache writes when there were 10+ skills or deferred tools. The impact scales with the number of skills and tools, so a plugin that adds many of either makes resumes more expensive. | `guide/core/known-issues.md` §0 | budget | Measured (community; status last noted as of v2.1.88, may be stale) |
| 24 | MCP tool search (lazy loading, v2.1.7+): about 55K → 8.7K tokens on a 5-server setup. Unused tools cost only their names; each loaded schema costs about 600 tokens. A minimal tool surface (OpenMemory's 4 tools) is recommended over "53-tool memory MCPs". Layering: skills decide what to do and when; MCP handles connectivity and OAuth; CLI handles deterministic local operations. | `guide/core/architecture.md` §6 "MCP tool search"; `guide/ecosystem/mcp-vs-cli.md`; `guide/core/memory-systems.md` §3.6 | channel, budget | Doc (Anthropic benchmark) + Opinion |
| 25 | Auto-compact can discard history before a `PostToolUse` capture pipeline saves it. Fixes: disable auto-compact, or capture well below the compaction threshold. Native 1M sessions auto-compact at about 967K tokens; micro-compaction first compresses old tool results. `/compact focus on X` steers the summary. A `UserPromptSubmit` "identity re-injection" can restore lost context after compaction. | `guide/ultimate-guide.md` §2.2 "Session vs. persistent memory", "Context recovery strategies", §7.5 "Identity Re-injection" | capture, channel | Opinion + Doc |
| 26 | Memory poisoning. Shared memory is "an unguarded write surface"; agents do not tell retrieved memory apart from instructions. Single-user variant: a compiled wiki that ingests untrusted sources. Controls: stage untrusted writes for review; record provenance (`sources`) on every page; add an agent-authorship trailer to commits; run a deterministic secret scanner in the write path; never ingest with `--dangerously-skip-permissions`. | `guide/core/memory-systems.md` §7.1 | sec, capture | Opinion (the pattern was observed in one repo) |
| 27 | Staleness: no surveyed tool detects stale memory. ICM has a manual `superseded_by` relation; Zep/Graphiti keeps bitemporal edges ("what did we believe before the April pivot?"); Kairn uses decay (solutions about 200 days, workarounds about 50). Open problems named: provenance, memory versioning, conflict resolution, token-budgeted retrieval ("no tool exposes a token budget as a first-class parameter"), per-feature cost attribution. | `guide/core/memory-systems.md` §6.4, §6.6, §7.2, §7.3, §10 | fresh, budget | Opinion (survey) |
| 28 | Promotion discipline. Keep the source event, the interpretation, the candidate lesson and the active rule separate. Attach provenance, an owner and an expiry. Self-reported agent observations (MLD) are telemetry for whoever improves the harness, not memory. A curator proposes changes as PRs with evidence and A/B canary results and never writes rules directly. A suggestion repeated in 3 reports with no action must be decided or closed. | `guide/core/memory-systems.md` "Qualify learned rules before promotion", §3.7 MLD; `guide/core/context-engineering.md` §6 "The update loop", §11 | capture, fresh | Opinion |
| 29 | Capture channels the guide recommends: an "instinct" pipeline (confidence 0.1–0.4 → 0.5–0.7 → 0.8+, with decay, promoted by hand); review-driven capture (a pattern recurring in 2+ inline review comments becomes a rule; a round-to-round diff checks whether a rule is needed at all); a session retrospective prompt; sprint "knowledge feeding" (new patterns, anti-patterns, ADRs, deprecations). | `guide/ultimate-guide.md` §9.24, §9.26; `guide/core/context-engineering.md` §6 | capture | Opinion. §9.24 also contains a factual error; see §6. |
| 30 | Persona anti-pattern: "Subagents are not for anthropomorphizing roles, they are for controlling context." Frontend, backend and QA "team" agents are listed as wrong. Named-perspective agents work only for well-known engineers whose views the model was trained on (DHH, Kent Beck). | `guide/ultimate-guide.md` §2.13 "Agent anti-patterns: Roles vs context control", §4.7 "Named perspective agents" | map (role views) | Opinion (quoted practitioners) |
| 31 | Skill design patterns that save tokens: "shared ground truth injection" (the orchestrator compiles a baseline once and pastes the same string into every subagent prompt); review agents receive only rules whose `paths:` match the changed files ("with 50 rule files a PR may match 3"; the example's `alwaysApply` field is read by Packmind's orchestrator, not by Claude Code); two-tier standards (a 200-word summary with `paths:` in `.claude/rules/`, the full standard outside auto-load); plans and specs committed under `.claude/plans/` and `.claude/specs/`. | `guide/core/skill-design-patterns.md` | channel, budget, map | Opinion (patterns observed in Packmind) |
| 32 | What a plugin ships: skills, agents, commands, `hooks/hooks.json`, `.mcp.json`, `.lsp.json`, monitors and settings. `${CLAUDE_PLUGIN_DATA}` survives updates. Skills are namespaced `plugin:skill`. A repo-level `enabledPlugins` / `extraKnownMarketplaces` setting gives every teammate the same plugins. The guide does **not** document shipping CLAUDE.md or `.claude/rules` through a plugin; verify against the official plugins reference. | `guide/ultimate-guide.md` §8.5; `guide/ecosystem/plugin-distribution.md` | channel, team | Doc (the CLAUDE.md/rules question is undocumented) |
| 33 | Startup hooks are an attack path. `SessionStart`, `Setup`, `InstructionsLoaded` and `DirectoryAdded` run before any user action. The Shai-Hulud npm worm (2026-08-04) planted a `.claude/settings.json` `SessionStart` hook: cloning the repo and opening the folder ran attacker code. A plugin's startup hooks sit on the same path and need the same review. Also: inspect the CLAUDE.md of any unfamiliar repo before use. | `guide/security/security-hardening.md` §1.6; `guide/ultimate-guide.md` §3.1 "Security warning: CLAUDE.md injection" | sec | Doc (incident) |
| 34 | Profile-based module assembly: per-developer CLAUDE.md built from shared modules, with CI drift detection. Measured on one 5-developer team: about 8,400 → 3,450 tokens (−59%). Break-even is about 3+ developers using 2+ tools. At 10+ developers and 5+ repos, central distribution tools such as Packmind can also ingest PR review comments and Slack discussions. | `guide/ultimate-guide.md` §3.5; `guide/workflows/team-ai-instructions.md` | team, budget | Measured (one team, the author's) |
| 35 | Lifecycle hygiene: instruction debt; a quarterly KEEP/UPDATE/ARCHIVE/DELETE audit; a not-loaded `CLAUDE-archive.md` that records why rules were retired; canary prompts before and after config changes; a `constitution.md` invariant check on proposed rules; a weekly self-consistency check ("docs claimed 100% versioned, measured 17%"). | `guide/core/context-engineering.md` §6, §7, §8 "archive pattern", §13 | fresh | Opinion |
| 36 | Built-in capture and onboarding commands: `/init` (`CLAUDE_CODE_NEW_INIT=1` adds an interactive flow covering skills, hooks and memory); `/memory`; `/insights` (proposes 6+ CLAUDE.md additions from usage history); `/team-onboarding` (a ramp-up guide from 30 days of sessions); `/recap`; `/context`. | `guide/ultimate-guide.md` §6.1 "Built-in Commands", §10.1 | capture, team | Doc |
| 37 | Code-structure layer (separate from memory of what was discussed): "Claude Code has no built-in indexation". Native LSP (`ENABLE_LSP_TOOL=1`) finds call sites in about 50 ms versus about 45 s by text search. Graphify pre-builds a graph, injects `GRAPH_REPORT.md`, rebuilds from a post-commit hook (local AST, no API cost) and tags edges `EXTRACTED/INFERRED/AMBIGUOUS`. Its 71–120× token savings are self-reported. | `guide/ultimate-guide.md` §8.2 "Serena", "Graphify", §8.5 "LSP Native Support" | map, fresh | Mixed (Doc for LSP; Vendor for Graphify) |
| 38 | Measured memory-tool costs: agentmemory about 170K tokens/yr; claude-mem $5–15/month, with 3-layer progressive disclosure (search 50–100 tokens → timeline → details) giving about 10× fewer tokens; Mem0 about 10–15% overhead per turn; ORF's file index read in three tiers (about 200 / 500 / 800 tokens). A field audit of one claude-mem install over 4.5 months found six silent failures, including an empty semantic index. Installing claude-mem overwrites existing `settings.json` hook arrays. | `guide/core/memory-systems.md` §3.1, §3.2, §3.7, §10 | budget, capture | Vendor (plus one field audit) |

---

## 3. The native-first toolkit: senior-team knowledge with built-in features only

**What the guide recommends, mapped to the v2 need.** The test case is: "create a component" should make Claude aware of existing components, the agreed structure and relevant past decisions.

| v2 need | Native mechanism (guide's recommendation) | Cost when it loads |
|---|---|---|
| Agreed structure and conventions | Root `CLAUDE.md` as an index (≤100 lines, 4–8 KB across all levels; #7). `.claude/rules/components.md` with `paths: ["src/components/**"]` (#8). A nested `src/components/CLAUDE.md` or a directory `README.md` stating what belongs there (#13). | Root: every session. Path rule: only after a matching Read/Write/Edit. |
| Existing components (inventory) | Auto-generated `code-map.yaml` (≤1K tokens, `component_domains` with counts and roots), registered in a "Context Indexes (load on demand)" table, never `@imported` (#11). Graphify / LSP for deeper structure (#37). | One tool call when needed. |
| Past decisions that affect the request | ADRs in `docs/decisions/`, cited from code comments and from the scoped rule ("see ADR-007") (#13). Keep `docs/solutions/` and `docs/plans/` separate from rules (#12). | On demand (a grep or a pointer). |
| How we create a component (procedure) | Skill `create-component`. Because auto-invocation is only about 56%, name it in the eager index or the scoped rule (#9). | Description always; body when invoked. |
| Learned team knowledge written by the agent | Agent `memory: project`, committed under `.claude/agent-memory/<agent>/`, first 200 lines injected (#5). | Every run of that agent. |
| Personal learned knowledge | Auto Memory (200 lines / 25 KB) plus Auto Dream consolidation (#3, #4). | Every session. |
| Capture | `/insights` proposals, `/memory`, session-retrospective prompt, sprint knowledge feeding, `/team-onboarding` (#29, #36). | Manual. |
| Audit what loaded | `/context`, the `InstructionsLoaded` hook (`load_reason`), `/skill-doctor` (#10, #20). | None. |
| Distribution | Commit `.claude/`. Ship behaviour (skills, agents, hooks, MCP) as a plugin; set `enabledPlugins` in shared settings (#16, #32). | — |

**Limits the guide states for this stack** (`guide/core/memory-systems.md` §2.6, §7, §10):

- Auto Memory and `MEMORY.md` are local to one machine and one user, not shared across devices or people.
- There is no semantic retrieval: memory loads linearly from the top of the file, and the 200-line cap is "a UX heuristic, not a memory model".
- Nothing carries across projects.
- Auto Dream needs ≥5 sessions and ≥24 h, writes facts it has not checked, and keeps no audit trail.
- Agent teams share nothing beyond CLAUDE.md.
- No layer tracks provenance, detects staleness or does token-budgeted retrieval.

**Limits that follow from the documented loading rules** (my inference from #8 and #9; the guide does not state these):

1. **Intent-time blind spot.** Path-scoped rules and nested CLAUDE.md load on **file access**, not on the user's intent. For "create a component" in a fresh session, the component rule and the ADR pointer are absent while Claude plans; they arrive only after Claude happens to read a matching file. A new file under a scoped directory may trigger the rule only when written.
2. **Skills are unreliable triggers.** At about 56% auto-invocation, a "create-component" skill alone does not guarantee the knowledge is used.
3. **Committed knowledge is maintained by hand.** Nothing native keeps ADRs, rules or the code map consistent with the code. The code map stays honest only because a script generates it.

**The guide's own minimal recipe** (my synthesis of #6, #7, #11, #13, #17, #19):

- Keep a short eager index.
- Keep path-scoped rules that point to ADRs.
- Keep an auto-generated structure file.
- Commit agent memory for knowledge agents learn.
- Add retrieval (BM25 first) only when measurement shows misses.
- v2 should build on this layout (CLAUDE.md, `.claude/rules`, ADRs, agent memory), not replace it.

---

## 4. Gaps the guide does not solve, which a plugin could

1. **Intent-time routing of knowledge (not just skills).** The guide's BM25 router (#19) routes prompts to *skills*. No mechanism routes a prompt to the *relevant decisions, conventions and inventory slices* before the first file access. v2 could do this on `UserPromptSubmit` under the guide's contract: at most 3 items, at most 500 characters, silent on a miss, p95 under 75 ms, calibrated precision, contrastive negatives.
2. **Freshness of committed knowledge.**
   - What the guide offers: a doc-gardening agent (a pattern with no implementation; #15), `generated/` files for code-derived facts (#11), and manual `superseded_by` links (#27).
   - What is missing: nothing ties a decision or convention to the code it governs, so nothing notices when that code changes (`FileChanged` / post-commit, then re-validate or mark stale).
   - What v2 could do: carry each decision's validity (supersedes / superseded-by, scope, date) and evict superseded decisions from injection.
3. **Automatic decision capture with provenance.**
   - What the guide offers: every capture pattern ends in a manual promotion (#28, #29), which is right for safety, but no tool records "which session, which evidence, who approved" (#27).
   - What is missing: no tool turns the decisions made in a session into proposals automatically.
   - What v2 could do: extract decision candidates through hooks (zero model tokens per #2), stage them, and promote them through a PR or a review step with provenance attached.
4. **Team dynamic memory without a server.** The guide calls the team gap structural (#1) and notes that git-based files solve *distribution* but not *consolidation or conflict* (`guide/core/memory-systems.md` §4.7). v2 could use git as the transport and add semantic dedupe and contradiction detection at write time (the guide suggests a lexical pre-filter plus an LLM pass that "no tool ships today", §10).
5. **Role perspectives done right.** The guide only warns against personas (#30). It has no model for "what the lead, the PM and the designer know". v2 could expose role-*scoped knowledge views*: decisions and conventions tagged by owner, role or domain and filtered at retrieval time. No role-played agents.
6. **A unified repo mindmap.** The pieces exist separately: OKF (untyped links, #14), ICM memoirs (typed relations), Graphify (code graph, #37), code map (counts, #11). None joins code structure, conventions and decisions with typed edges (`governs`, `supersedes`, `implements`, `owned-by`) that a router can walk cheaply.
7. **Token-budgeted retrieval as a first-class parameter** (#27): return the best knowledge that fits N tokens, instead of top-k.
8. **Measuring whether injected knowledge was used.** The guide asks for this ("present / loaded / used / effect verified", `guide/core/context-engineering.md` §1) but no tool provides per-feature cost attribution (#27). v2 could log injected bytes per turn and whether the model then cited or applied them.
9. **Cross-project lessons** (`guide/core/memory-systems.md` §10): what was learned in repo A that applies to repo B.

---

## 5. Anti-patterns relevant to v2

1. **Persona agents** ("Lead Dev agent", "PM agent"). Agents control context; they are not job titles (#30). Model roles as knowledge facets.
2. **A monolithic, always-loaded knowledge file.** It dilutes attention, costs tokens every session and anchors on stale entries (#6, #7). `guide/core/context-engineering.md` §4 "Anti-pattern: The monolithic CLAUDE.md".
3. **Mixing decisions into rules.** The AI then treats old decisions as current constraints (#12). Keep "rules" and "history of decisions" in separate stores with separate loading.
4. **Using `@import` to "lazy load".** Imports load with the file that imports them (#8). Use pointer tables or path-scoped rules instead.
5. **Relying on skill auto-invocation for critical knowledge** (about 56%, #9).
6. **Injecting on every tool call, or injecting chatty output.** It accumulates for the rest of the session and is re-read each turn (#21, #22). Be silent on success and stay well under the 10K-character `additionalContext` cap.
7. **Dynamic content in stable prefixes, and frequent edits to CLAUDE.md.** Both break the prompt cache (#22). Many skills or MCP tools also make the resume cache bug more expensive (#23).
8. **A large MCP tool surface for memory** ("53-tool memory MCP"). Prefer a few tools or no MCP at all (#24).
9. **Capture that depends on the agent choosing to call a store tool** (#2). Also: capture that races auto-compact (#25).
10. **Auto-writing into the trusted knowledge base without staging, provenance or a secret scan.** This is the memory-poisoning path, including ingestion of web or third-party text (#26).
11. **Startup hooks with side effects.** `SessionStart`, `InstructionsLoaded` and similar are a known worm persistence vector (#33). Keep them read-only, fast and auditable.
12. **Fail-open memory that fails silently.** claude-mem's field audit found six failures that raised no error (#38). Memory health must be observable.
13. **Adding RAG or vector infrastructure before measuring misses** (#17). Pure vector retrieval for code-shaped queries (#18).
14. **Curator output that is never merged** (the open loop). Two reports ten weeks apart proposed the same rules and neither was merged (`guide/core/context-engineering.md` §11). Proposals must be easy to accept and must expire.
15. **Treating counts as quality.** A 100/100 structural score while verification failed (`guide/ultimate-guide.md` §9.25 intro). Prefer behavioural canaries (#35).

---

## 6. Reliability notes on the guide

These points are inconsistent or likely wrong. Do not import them as facts.

- `guide/core/context-engineering.md` §2 withdraws the 150-instruction ceiling and the "adherence by file size" curve. §7 still divides a "context debt score" by 150, §8 still claims "negative constraints" improve adherence by 15–25%, and `guide/ecosystem/context-engineering-tools.md` §2 still says "over 400 lines drops adherence to ~60%". Treat all three as unverified.
- **Hook JSON handling is contradictory.** `guide/ultimate-guide.md` §7.2 says JSON is processed only on exit 0. `guide/core/hooks-events-reference.md` says JSON is read on every exit code.
- **Stop vs. session end.** `guide/ultimate-guide.md` §9.24 says a `Stop` hook "runs once when the session ends". The guide's own reference says `Stop` fires whenever Claude finishes responding, which is every turn. The sample runs `claude --print` inside that hook, so it runs a nested model call every turn and may trigger itself recursively.
- **Hook samples that use undocumented fields.**
  - `guide/core/architecture.md` §3 reads `$CLAUDE_TOOL_EXIT_CODE` from the environment, but hooks receive JSON on stdin.
  - `guide/core/context-engineering.md` §8 returns a `tool_result` object; the documented field is `hookSpecificOutput.updatedToolOutput`.
- `guide/core/context-engineering.md` §15 says `.claude/rules/` loads "every .md at session start regardless of relevance". That holds only for unscoped rules; §3–§4 of the same file describe `paths:` scoping.
- **Skill `paths:` frontmatter** appears only in a release note (`guide/core/claude-code-releases.md`), not in the §5.2 frontmatter table. Confirm it in the official skills docs before relying on it.
- **Unsupported numbers.** The success-rate figures by file scope (85% / 60% / 40%) and the "15–25 turn" degradation in `guide/core/architecture.md` §3 are practitioner anecdotes.
