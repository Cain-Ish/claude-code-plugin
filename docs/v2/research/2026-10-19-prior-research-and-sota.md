# Project memory for coding agents: prior research and state of the art

Date: 2026-10-19. Purpose: the evidence base for second-brain v2, a Claude Code plugin that keeps a per-project
"mindmap" so every session in a repo knows what the team knows: the current structure, the agreed conventions,
the decisions that bind the current request, and what the lead developer, PM and designer would tell a new
teammate. Worked example: "create a component" should arrive knowing the existing components, the agreed structure
and the past decisions that apply.

Part A distils the project's earlier research rounds (September 2026), keeping only findings that should shape v2.
Part B is a fresh scan of primary sources (2025-2026). The core of the report is the eight design questions, and
it ends with twelve rules. Sources are cited by key, for example [ETH-AGENTSMD], and listed at the end.

## How to read the evidence

| Label | Meaning |
|---|---|
| **Independent** | Measured by a third party or by academics evaluating a method that is not their product |
| **Academic-own** | Authors measuring their own method |
| **Vendor** | A company measuring its own product (or a competitor's) |
| **Docs** | A documented product behaviour or limit, not a measurement |
| **Practitioner** | A design or claim from a working practitioner, with no outcome data |
| **Internal** | second-brain v1's own telemetry or probes: unpublished, small samples |

Confidence: **High** = full-text read, significance reported, or several sources agree. **Medium** = a single
vendor-run eval, or a paper read at abstract level. **Low** = practitioner claim, anecdote, or inference.

---

## Summary

1. **Always-on overviews don't help.** Context files with repository overviews do not raise task success and cost
   20-23% more. Overviews did not shorten the path to the first relevant file [ETH-AGENTSMD]. At most 3,000
   characters (~750 tokens) of task-tested procedures and file pointers did help: +4.7 points over a static
   knowledge base, and the gain came from localization [PROBE-REFINE].
2. **Passive beats must-choose, but only for a small index.** A compressed 8 KB docs index in AGENTS.md scored 100%.
   A skill the model had to invoke scored 53%, and 79% with explicit instructions [VERCEL]. An on-demand graph tool
   went uncalled in 58% of trials [CODECOMPASS]. v1 of this plugin pushed 83 items over 13 sessions and saw 0 reads
   [V1-TELEMETRY].
3. **Vendors retreated from unanchored, per-user auto-memory.** The field moved to versioned, git-tracked files
   loaded by trigger: Cursor removed Memories, Windsurf kept them for its legacy agent only, and Devin moved
   Knowledge to in-repo Skills [CURSOR-FORUM][DEVIN-DESKTOP][DEVIN-KNOWLEDGE]. The one auto-memory that grew,
   GitHub Copilot Memory, stores facts with code citations and verifies them before use. It reports merge rate up
   from 83% to 90% [COPILOT-BLOG].
4. **Structure is a commodity; rationale is the gap.** Code-graph MCP tools with 47k-75k GitHub stars cut tokens by
   30-60% at flat or lower answer quality [CODEGRAPH][CBM-PAPER]. No system keeps *decisions and rationale*
   anchored to code, fresh and attributed, except Copilot's citation check.
5. **No product models team roles.** The nearest things are BMAD personas with persistent facts, MADR's
   decision-makers/consulted fields, Kiro's product/tech/structure split, and Figma Code Connect for design facts
   [BMAD][MADR][KIRO][FIGMA-MCP]. Whether role-attributed knowledge helps an agent is unmeasured anywhere.
6. **Auto-captured memory is an attack surface.** Query-only memory injection succeeded 98.2% of the time [MINJA].
   Hidden Unicode in rules files is invisible in review [PILLAR]. One agent wrote persistent memories from injected
   comments with no approval step [SPAIWARE].

---

## Part A. Evidence ledger distilled from prior research

The earlier rounds read primary sources (papers in full text where noted, vendor docs, source code). Only findings
relevant to v2 are kept. Q-numbers refer to the design questions below.

### A.1 What belongs in always-on context

| # | Claim | Source | Number | Conf. | Informs |
|---|---|---|---|---|---|
| A1 | Context files with LLM-generated overviews slightly hurt success and raise cost. Developer-written files help a little, not significantly, and did not help Claude Code. Overviews did not reduce steps to the first gold-patch file. Generated files helped only when all other docs were deleted, so the null result is redundancy. Agents follow files literally: a tool named in the file was used ~1.6x per task vs <0.01x when not named. | [ETH-AGENTSMD] (v1 2026-02, v3 2026-09) | Generated: -0.5 pts (SWE-bench Lite), -2 pts (138-task CTXbench), cost +20% / +23%, +2.45 / +3.92 steps. Developer: +2.4 pts (p=0.21), cost up to +19%. Docs removed: generated +2.7 pts | High (Independent) | Q3, Q6, Q7 |
| A2 | Task-tested guidance under a hard cap beats a static knowledge base. The gain is coverage (reaching the right file); per-patch precision is flat. Added lines: 47% procedural, 30% structural (which file, function, relation), 23% quality gates. The method degraded on a second model. | [PROBE-REFINE] (2026-06) | 33.0% vs 28.3% static vs 25.5% none, SWE-bench Verified (p<0.001); +14.5 pp evaluable patches; cap 3,000 chars | High (one small open model) | Q3, Q6, Q7 |
| A3 | A passive compressed docs index beat a skill the model had to invoke. | [VERCEL] (2026-01-27) | 100% index vs 53% skill (= no-docs baseline; uninvoked in 56%) vs 79% skill + instruction; index 40 KB to 8 KB with no loss | Medium (Vendor; model and n not stated) | Q2, Q6 |
| A4 | In a small controlled study, context strategy did not measurably move correctness. | [KHATRI] (2026-07) | 17 tasks, 288 runs; effect bounded at 10-15 pp | Medium (abstract) | Q7 |
| A5 | Instruction-file size, position, layout and contradictions had no detectable effect on adherence. Adherence decays within a session. | [ADHERENCE] | 1,650 Claude Code sessions; odds of following a convention fell ~5.6% per generated function (OR 0.944) | Medium (abstract) | Q2, Q6 |
| A6 | Long inputs degrade models even on trivial tasks; focused prompts beat full history. | [CONTEXT-ROT] (2025-07) | 18 models; LongMemEval ~300-token focused prompt far above ~113K full | High | Q6 |
| A7 | A larger memory window made an agent derail more. | [VENDING-BENCH] | 60K memory worse than 10K/30K | Medium | Q6 |

### A.2 Delivery on the Claude Code platform

| # | Claim | Source | Number | Conf. | Informs |
|---|---|---|---|---|---|
| A8 | Native files survive compaction and hook text does not. Project-root CLAUDE.md, unscoped rules and auto memory are re-read from disk. Invoked skill bodies are re-attached. Earlier hook context is only summarized; a SessionStart hook on the `compact` source re-runs. Path-scoped rules reload only when a matching file is touched again. | [CC-CONTEXT]; v1 headless probe | Skill bodies 5,000 tokens each, 25,000 total | High (Docs + Internal probe) | Q2 |
| A9 | Hook text over 10,000 chars is spilled to a file with a 2,000-char preview, which Claude is not asked to read. Hook text should be written as facts, because imperative "system command" phrasing can trip prompt-injection defenses. | [CC-HOOKS] | 10,000-char cap per field | High (Docs) | Q2, Q6 |
| A10 | Subagents are memory-starved. They do not get the main session's auto memory, and Explore/Plan skip CLAUDE.md. SubagentStart is the only push channel into them. A subagent with `memory: project` gets its own git-tracked MEMORY.md. | [CC-SUBAGENTS] | First 200 lines / 25 KB of agent memory | High (Docs) | Q2, Q8 |
| A11 | Plugin hook output has regressed upstream: plugin SessionStart context was discarded in one release. | [CC-ISSUE-12151] | n/a | Medium | Q2 |
| A12 | v1 pushed memory into sessions and it was almost never read. | [V1-TELEMETRY] | 83 injected / 0 read over 13 sessions; later 2 reads per 117; latest 15 / 0 | Internal ("read" undercounts silent use) | Q2, Q6, Q7 |
| A13 | Compaction is rare on 1M-context models. Heavy sessions run ~42 tool calls per human prompt, so per-prompt injection fires seldom relative to the work done. | [V1-TELEMETRY] | 0 compactions in 69 sessions; 1,728 calls for 41 prompts | Internal | Q2 |
| A14 | A plugin can steer what the compaction summary keeps through a `## Compact Instructions` block in hook context. A stock summary drops counters and the rationale for rejected options. | v1 probe (CLI 2.1.284); [COMPACT-CANON] | 6/6 with block vs 0/2 without; stock kept 6/15 seeded facts, explicit block 15/15 | Internal + Low (third party, version-sensitive) | Q2, Q5 |

### A.3 Capture, freshness and trust

| # | Claim | Source | Number | Conf. | Informs |
|---|---|---|---|---|---|
| A15 | Facts stored with code citations, verified against the current branch before use and expired when unused raised outcomes. Adversarially seeded memories were corrected. Verification is prompt-induced, not deterministic. | [COPILOT-BLOG] (2026-01-15) | Merge rate 83% to 90%; review feedback 75% to 77% (p<0.00001); review precision +3%, recall +4%; unused deleted after 28 days | Medium (Vendor A/B, no n) | Q4, Q5, Q7 |
| A16 | Vendors retreated from unanchored auto-memory toward versioned, trigger-loaded files. | [CURSOR-FORUM][DEVIN-DESKTOP][DEVIN-KNOWLEDGE] | n/a | High (primary docs) | Q1, Q4 |
| A17 | BMAD replaced its generated `document-project` with a tiny verified block. Admission test: "would removing this line change agent behavior?" It excludes overviews, trees, stack lists, history and aspirational state, admits pitfalls only from observed failures, stamps `Verified <date> against <sha>`, and refreshes via `git log --diff-filter=DR` since that SHA. Its rule: "an index the agent must choose to fetch gets skipped." | [BMAD] | n/a | Low (Practitioner) | Q3, Q4, Q5 |
| A18 | Explicit capture dominates implicit capture. In gstack, 43 of 44 learnings came from an explicit `/learn`, because "if you discovered" read as optional. Learnings carry confidence 1-10, decay if observed or inferred, and count as trusted only when user-stated. | [GSTACK] | 43/44 explicit; -1 point per 30 days | Medium (code-verified) | Q4, Q5 |
| A19 | Cursor's own memory plugin writes only two AGENTS.md sections, caps each at 12 bullets and runs on a cadence gate (>=10 turns and >=120 min). It replies "No high-signal memory updates." when nothing qualifies. | [CURSOR-CL] | 12 bullets per section | Low (code read) | Q4, Q6 |
| A20 | Learned rules need promotion and demotion. Bugbot turns feedback into candidate rules, promotes them as signal builds and disables them on negative signal. | [BUGBOT-LEARNING] (2026-04-08) | Resolution rate 52% to ~80% (Jan-May 2026) | Medium (Vendor) | Q4, Q7 |
| A21 | Learning filters: still true in 6 months, confirmed by 2+ reviewers, changes a future decision, "a lint could enforce it, so route it there", not already covered. Encode lessons in the strongest structure available (type, then lint/CI, then helper, then runtime check), because "agents just love to copy existing patterns". | [PSTACK] | n/a | Low (Practitioner) | Q4 |
| A22 | Cursor's rules guidance: "use a linter instead" of copying style guides, add a rule only "when you notice Agent making the same mistake repeatedly", and reference files instead of copying them. | [CURSOR-RULES] | Rules under 500 lines | High (Docs, as guidance) | Q3, Q4 |
| A23 | Retirement should depend on provenance. Copilot expires unused facts; BMAD refuses to retire a rule for disuse ("a working rule erases its own evidence"). | [COPILOT-DOCS][BMAD] | 28 days | Low (inference across two sources) | Q5 |
| A24 | Existing freshness mechanisms: citation verify-at-read (Copilot), SHA provenance plus rename/delete diff (BMAD), code-coupled snippets checked per PR (Swimm), recompute per request from an mtime cache (Aider), reference-integrity check and rename rewrite (Serena). Only Copilot's has outcome numbers. | [COPILOT-BLOG][BMAD][SWIMM][AIDER][SERENA] | n/a | High (mechanisms) | Q5 |
| A25 | Sourcegraph dropped embeddings from Cody Enterprise for Sourcegraph Search, because keeping embeddings current added complexity and cost. | [CODY-FAQ] | n/a | Medium | Q1, Q5 |

### A.4 Structure, roles and multi-agent context

| # | Claim | Source | Number | Conf. | Informs |
|---|---|---|---|---|---|
| A26 | Graph ranking boosts did not help at small scale. v1's capped graph boost over a real 96-page wiki was a wash; an earlier uncapped boost compounded through hub pages. GraphRAG-Bench found graphs often underperform plain RAG except on genuine multi-hop questions. | [V1-TELEMETRY][GRAPHRAG-BENCH] | 6 better, 6 worse, 80 unchanged of 92; ~10,000x compounding incident | Internal + Medium | Q3 |
| A27 | A feature map as "materialized memory": one small file per feature (user path, how to drive it, gotchas), because "agents pay for every token they reread". | [PSTACK] | n/a | Low (Practitioner) | Q3 |
| A28 | A map-only boot that "knows everything exists without reading any of it" scales better than read-everything boots like Cline's Memory Bank ("MUST read ALL memory bank files at the start of EVERY task"). | [MEMORY-VAULT][CLINE-MB] | ~500 notes claimed | Low | Q3, Q6 |
| A29 | Models over-edit Markdown lists. Anthropic moved progress state to JSON where the model only flips a status field. | [ANTHROPIC-HARNESS] | n/a | Medium (Vendor practice) | Q4 |
| A30 | Externalized memory plus context clearing improved an internal agentic-search eval and cut tokens. | [ANTHROPIC-CTXMGMT] (2025-09-29) | +39% memory + editing; +29% editing alone; -84% tokens (100-turn eval) | Medium (Vendor, no method) | Q6 |
| A31 | Role-separated agents exchanging structured documents, with role-based subscription to avoid overload, outperform free dialogue. | [METAGPT] (ICLR 2024) | HumanEval 85.9%, MBPP 87.7% Pass@1; "sharing all information with every agent can lead to information overload" | High (Academic-own) | Q8 |
| A32 | Conflicting implicit decisions, not missing data, are the dominant multi-agent failure. Independent agents amplify errors far more than agents with central validation. | [COGNITION][SCALING-AGENTS] | 17.2x error amplification (independent) vs 4.4x (centralized) | Medium | Q3, Q8 |
| A33 | v1 keyed its role card on agent type instead of task shape and created a context clash: a test-first "DO" card arrived on a research dispatch. | [V1-TELEMETRY] | n/a | Internal | Q8 |
| A34 | Tagging the source alone barely stops agent-to-agent injection. Tagging plus marking stopped all attacks in one study. A memory-importance manipulation raised injected memories' scores from ~1.9 to 10. | [PROMPT-INFECTION] | Tagging cuts attack success only 5%; marking + tagging 0 successes; marking alone later bypassed 76% | Medium | Q4 |
| A35 | Consolidating memory is a delayed-trigger poisoning substrate: text read today is distilled into pages injected into every future session. Detectors are telemetry, not a boundary; break the "lethal trifecta" by construction. | [TRIFECTA][CAMEL] | CaMeL: 77% of tasks with provable security vs 84% undefended | Medium | Q4 |

---

## Part B. State of the art (fresh scan, 2025-2026)

### B.1 System matrix

Storage: **Repo** = git-tracked in the project. **Local** = per user, per machine. **Service** = vendor or self-hosted
server. "None found" = this scan found no published number.

| System | Storage | Team sharing | Freshness | Delivery | Measured | Roles |
|---|---|---|---|---|---|---|
| Claude Code CLAUDE.md / AGENTS.md [CC-MEMORY] | Repo (+ user, managed, `CLAUDE.local.md`) | git; managed org policy | none; `/doctor prompt-audit` flags stale or conflicting rules | Always on; nested files on read; @imports load at launch (no saving) | none found | No |
| Claude Code `.claude/rules` [CC-MEMORY] | Repo / user | git | none | `paths:` globs load on read/write/edit of a matching file; unscoped at launch | none found | No |
| Claude Code auto memory [CC-MEMORY] | Local (not git, not synced) | none | none | MEMORY.md first 200 lines / 25 KB at start; topic files on demand; not in subagents | none found | No |
| Claude Code skills [CC-SKILLS] | Repo / user / plugin | git | none | Name + description listing always (1,536-char cap; listing 1% of context, least-invoked dropped first); body on invocation | none found | No |
| Claude Code subagent `memory:` [CC-SUBAGENTS] | Repo (`project`, recommended), user, local | git (project scope) | agent curates its own file | Agent's MEMORY.md in its system prompt | none found | Per-agent memory (closest native "role" store) |
| GitHub Copilot Memory [COPILOT-BLOG][COPILOT-DOCS] | Service, repo-scoped | Created only by users with write access; used by readers of the repo | Citations re-checked on current branch at use; unused deleted after 28 days, reset on validated use | Recent memories at session start | Vendor: merge rate 83%→90%; review feedback 75%→77% | No |
| Copilot instructions [COPILOT-INSTR] | Repo (`.github/copilot-instructions.md`, `*.instructions.md` with `applyTo`) | git | none | Always on + glob-attached | none found | No |
| Cursor Rules / Memories [CURSOR-RULES][CURSOR-FORUM] | Repo `.cursor/rules`, dashboard Team Rules; Memories per user (removed 2.1.x, Nov 2025) | git; admin-enforced Team Rules | none | Always / glob / agent-decided by description / manual | none found | No |
| Windsurf, now Devin Desktop [DEVIN-DESKTOP] | Memories local (legacy agent only); rules in repo (12,000 chars/file; global 6,000) | Rules via git | none | Always / model decision / glob / manual | none found | No |
| Devin Knowledge → Skills, DeepWiki [DEVIN-KNOWLEDGE][DEVIN-SKILLS][DEEPWIKI] | Knowledge: service (deprecated); Skills: repo; wiki: service | Org / enterprise | Knowledge: none; wiki re-index (cadence undocumented) | Trigger-matched, repo-pinned, or invoked; wiki via MCP structure → contents → ask | none found | No (`author` on repo notes) |
| AGENTS.md [AGENTSMD][AAIF] | Repo | git; 60,000+ projects | none | Always on; nearest file wins. Claude Code reads it only when no CLAUDE.md exists [CC-MEMORY] | Independent, mixed [ETH-AGENTSMD][LULLA] | No |
| llms.txt [LLMSTXT][AHREFS] | Website | Public | none | Fetched on demand | Independent: ~97% of files got zero requests (137K domains) | No |
| Aider repo map [AIDER] | Local cache | none | Recomputed from mtime-keyed tag cache | Always on, 1k-token default budget, ranked by personalized PageRank | Vendor (2024): right file in 70.3% of SWE-bench Lite; no ablation | No |
| Augment Context Engine [AUGMENT-MCP][AUGMENT-COST][AUGMENT-LINEAGE] | Service index + local indexer; rules in repo; memories (storage undocumented) | Tenant; rules via git | Index updates within seconds; commit summaries (Context Lineage) | On-demand retrieval/MCP + always/agent-requested rules; memories need review since 2025-09 | Vendor: success ±2 pts vs Claude Code, cost -20% to -40% | No |
| Sourcegraph Cody / Amp [CODY-FAQ][AMP-THREADS] | Service (search + code graph); Amp: repo AGENTS.md + hosted threads | Org permissions; workspace-shared threads, `Amp-Thread-ID` commit trailer | Live search; no embeddings | Retrieval per chat; subtree AGENTS.md on read; threads on demand | none found | No (visibility scopes only) |
| Serena [SERENA] | No index (live LSP); memories in repo `.serena/memories/` | git | LSP live; `memories check` for stale references; rename rewrites references | Memory *names* listed; content pulled; "the harness does not inject memory content" | none (qualitative token claim) | No |
| codegraph / GitNexus / codebase-memory-mcp / Potpie [CODEGRAPH][GITNEXUS][CBM][POTPIE] | Local SQLite/graph; optional committed snapshot (CBM: ~6 GB over ~350 commits) | Index not shared; generated skills/AGENTS.md block committable | File watcher (2 s debounce); hooks flag stale index after commits | On-demand MCP; GitNexus also enriches grep/glob via PreToolUse hooks | codegraph (Vendor): -62% tokens, -44% cost, +80% resident context. CBM (Academic-own): quality 83% vs 92% at 10x fewer tokens | No (CBM and Potpie store decisions as unvalidated text) |
| Basic Memory, Obsidian MCP [BASIC-MEMORY] | Local Markdown + SQLite index; paid Teams cloud | git/sync; Teams has 5 access roles | none | On-demand MCP (`build_context` walks the graph) | none found | No (access roles, not perspectives) |
| Graphiti / Zep [ZEP-PAPER][ZEP-RESEARCH] | Service graph DB | Shared DB, group ids | Bi-temporal edges: invalidated, not deleted; provenance to source episodes | On-demand hybrid search | Vendor: LongMemEval 63.8-71.2% vs 55.4-60.2% full context, 115k→1.6k tokens | No |
| mem0 / OpenMemory [MEM0-PAPER][MEM0-2026] | Service or library + vector store | Platform; OpenMemory per user | 2025 ADD/UPDATE/DELETE/NOOP; 2026 switched to ADD-only because "overwrites erased key details" | On-demand search | Vendor (2025): **full context 72.9 beat every memory system**; 2026 claims 92.5 LoCoMo (disputed) | No |
| Letta [LETTA-CTXREPO][SLEEPTIME] | Server blocks; Letta Code "context repositories" = git repo of files | Org-owned shared memory repos (push/pull) | git history; sleep-time reflection; defragmentation to 15-25 files | File tree always in prompt; `system/` files loaded; rest on demand | Vendor: plain filesystem tools scored 74.0% LoCoMo vs Mem0g 68.5% | No |
| Cognee [COGNEE] | Self-hosted / cloud graph + vectors | Shared DB | `forget` only | On-demand | Vendor-only HotPotQA (24 questions) | No |
| ADR tooling: MADR, adr-tools, log4brains, Backstage [MADR] | Repo `docs/decisions/` | git | Manual `status` (proposed / accepted / superseded) | Plain files; no agent delivery | none found | Partial: `decision-makers / consulted / informed` |
| CodeRabbit / Greptile / Unblocked [CODERABBIT][GREPTILE][UNBLOCKED] | Service (+ Greptile repo rules) | Repo or org scope | CodeRabbit: "Active / Never Used" + manual quarterly review | Review context; filename-pattern learnings on match; Unblocked MCP on demand | Unblocked (Vendor): -48% tokens, 83% faster | No (team norms, unattributed) |
| Swimm [SWIMM] | Repo `.swm/` | git | Code-coupled; CI check fails on significant drift | IDE/PR; no agent MCP | none found | No |
| BMAD-METHOD [BMAD] | Repo artifacts (PRD, DESIGN.md, architecture, tickets, `.memlog.md`) | git; team override layer | Refresh/audit commands; `Verified … against <sha>` | Persona skill activation loads `persistent_facts` | none found | **Yes**: Analyst, PM, Architect, Developer, UX Designer personas |
| Spec Kit / Kiro / OpenSpec [SPECKIT][KIRO][OPENSPEC] | Repo (constitution, spec, plan, tasks; steering product/tech/structure) | git; Kiro global steering via MDM | Spec Kit `/converge` ("completion claims are not evidence"); OpenSpec validate | Commands; Kiro always / fileMatch / manual / auto | none found | Facets: product vs technical |
| Figma MCP, ChatPRD, Linear/Atlassian MCP [FIGMA-MCP][CHATPRD][LINEAR-MCP] | Service (live source of truth) | Tool permissions | Live | On-demand tools; Figma Code Connect maps design components to code components | none found | Facets: design and PM artifacts, no persona |

### B.2 Other measured results worth knowing

| Result | Source | Label |
|---|---|---|
| An AGENTS.md was associated with 28.64% lower median runtime and 16.58% fewer output tokens, with comparable completion (10 repos, 124 PRs) | [LULLA] | Independent |
| 2,303 context files from 1,925 repos "evolve like configuration code through frequent, small additions"; content dominated by tests, implementation details and architecture | [CONTEXT-FILES-STUDY] | Independent |
| A 108K-line C# system used a hot "constitution", 19 domain-expert agents and 34 cold specs served over MCP across 283 sessions (observational, no controlled comparison) | [VASILOPOULOS] | Academic-own |
| RepoGraph: +2.0 to +2.7 points absolute on SWE-bench Lite, at +3.7K to +20.4K tokens per instance | [REPOGRAPH] | Academic-own |
| ContextBench: scaffolding gives "only marginal gains in context retrieval"; large gap between explored and used context | [CONTEXTBENCH] | Independent |
| Cursor semantic search: +12.5% offline accuracy; online +2.6% code retention on 1,000+ file codebases; grep + semantic best | [CURSOR-SEMSEARCH] | Vendor |
| Claude Code's early RAG was dropped; agentic search "outperformed everything. By a lot" (internal impression, not a benchmark); RAG drifts out of sync | [LATENT-SPACE] | Vendor (anecdote) |
| ACE playbooks with itemized incremental updates: +10.6% on agent tasks; names "brevity bias" and "context collapse" from iterative rewriting | [ACE] | Academic-own |
| ReasoningBank, memory distilled from successes and failures: +4.6% on SWE-bench Verified with ~3 fewer steps | [REASONINGBANK] | Academic-own |
| Agent Workflow Memory: +24.6% and +51.1% relative success (Mind2Web, WebArena) | [AWM] | Academic-own |
| Experience-following: agents copy outputs of similar retrieved memories, so errors propagate; selective addition plus deletion gives ~+10% over naive growth | [EXP-FOLLOWING] | Academic-own |
| LoCoMo answer key ~6.4% wrong; the gpt-4o-mini judge accepted 62.81% of deliberately wrong but adjacent answers | [PENFIELD] | Independent (author sells memory) |
| MemoryAgentBench: no method masters retrieval, test-time learning, long-range understanding and conflict resolution together | [MEMAGENTBENCH] | Academic |

### B.3 Which systems model roles

Only **BMAD** defines explicit role personas (Analyst, PM, Architect, Developer, UX Designer). Each carries
`persistent_facts` (literal text or file globs) loaded on activation, with a base → team → user override layer
[BMAD]. Its earlier story template gave each section an owner and editors (the scrum master owns Status; only the
developer writes the Dev Agent Record). Even BMAD's persona is a working mode, not a store of what a specific human
lead knows. Partial role signals elsewhere:

- MADR records `decision-makers`, `consulted` and `informed` on every decision [MADR].
- Kiro splits steering into product, tech and structure facets [KIRO]. Spec Kit separates the product spec from
  the technical plan and gates plans on a versioned constitution [SPECKIT].
- Figma's MCP delivers the design facet, and Code Connect maps design components to code components ("without it,
  the model is guessing") [FIGMA-MCP]. ChatPRD and Linear/Atlassian MCP serve PM artifacts on demand.
- Copilot ties *authority* to permission: only users with write access create repo facts [COPILOT-DOCS].
- MetaGPT's SOP roles (PM, architect, engineer, QA) exchange documents with subscription by role [METAGPT]. A
  role-specification intervention gave +9.4% in a multi-agent failure study [MAST].

**Gap:** no system sources, freshens and attributes each role's knowledge separately ("tech lead: X; PM: Y;
designer: Z", each with owner, validity and provenance) for a coding agent. No measurement exists of whether that
helps.

### B.4 Poisoning and injection evidence

- **MINJA**: query-only memory injection reached 98.2% injection success and 76.8% attack success on GPT-4/4o
  agents. A detector tuned for one agent caught 131/135 there and 0/135 on another [MINJA].
- **AgentPoison**: over 80% attack success with under 0.1% of memory poisoned and under 1% benign impact
  [AGENTPOISON].
- **Rules File Backdoor**: invisible Unicode in Cursor and Copilot rules files. Reviewers see nothing. Cursor called
  it the user's responsibility; GitHub added an advisory hidden-Unicode warning on 2025-05-01 [PILLAR][GH-UNICODE].
- **Windsurf SpAIware**: `create_memory` ran without approval, so an injected source comment could plant persistent
  instructions that kept exfiltrating data across sessions [SPAIWARE].
- **MCPoison** (CVE-2025-54136): an approved MCP config in a shared repo could be swapped silently later, giving
  persistent team-wide code execution [MCPOISON]. **MCPTox**: 36.5% average tool-poisoning success over 20 models,
  and more capable models were often more susceptible [MCPTOX].
- **Defenses with evidence**: A-MemGuard (consensus validation across memories) cut attack success by over 95%
  [AMEMGUARD]. OWASP's Agentic Top 10 (ASI06) says to validate writes, segment memory, decay by provenance, and
  **not auto-reingest agent outputs** [OWASP-ASI06]. Copilot gates writes by write access and re-verifies citations
  [COPILOT-DOCS]. CodeRabbit holds chat-sourced learnings for admin approval for up to 30 days [CODERABBIT].
  Claude Code asks for trust approval on CLAUDE.md imports "to protect you from files other people commit to a
  shared project" [CC-MEMORY].

---

## Design questions

### Q1. Where knowledge lives: repo-tracked, user-local or service

**Evidence.**
- Team-shared agent knowledge has converged on git-tracked Markdown: CLAUDE.md/AGENTS.md (60,000+ projects
  [AAIF]), `.claude/rules`, `.cursor/rules`, `.github/instructions`, `.devin/rules`, `.kiro/steering`,
  `.serena/memories`, BMAD artifacts, Spec Kit, ADR directories, Letta's git-backed context repositories, and
  Claude Code's own `memory: project` for subagents [CC-SUBAGENTS][LETTA-CTXREPO].
- Per-user local memory cannot reach a team, and vendors stopped treating it as team knowledge. Claude Code's auto
  memory is machine-local [CC-MEMORY]. Cursor removed per-user Memories [CURSOR-FORUM]. Windsurf says durable
  knowledge belongs "in a Rule or AGENTS.md" [DEVIN-DESKTOP].
- The one service-side memory with outcome data (Copilot) is repo-scoped, permission-gated and citation-checked
  [COPILOT-BLOG]. Vendor-hosted Devin Knowledge was deprecated in favour of in-repo Skills [DEVIN-KNOWLEDGE].
- Derived indexes are kept local and rebuilt, not shared. Aider, codegraph and GitNexus keep caches out of git.
  The one tool that offers a committed graph snapshot warns of ~6 GB over ~350 commits [CBM]. Sourcegraph, Cline
  and Claude Code each rejected or dropped embedding indexes because they drift and "this index has to live
  somewhere" [CODY-FAQ][CLINE-NOINDEX][LATENT-SPACE].
- Claude Code reads AGENTS.md only when no CLAUDE.md exists, and a personal `CLAUDE.local.md` silently disables it
  [CC-MEMORY]. A cross-tool repo cannot assume one root file reaches every agent.

**For v2.** Three homes, chosen by who owns the knowledge:
1. **Team knowledge in the repo**, reviewed like code: decisions, conventions, role-owned rules, feature/area
   notes. Plain Markdown with frontmatter, so any agent and any human can read it without the plugin.
2. **Personal preferences and practices user-local**, separated at write time from project facts (a portable
   "practice" vs a repo-bound "fact").
3. **Derived structure as a local, gitignored cache** recomputed from code.

**Tension to resolve:** v1's constitution makes the plugin's own knowledge base "the only home" and forbids writes to
CLAUDE.md, `.claude/rules` and MEMORY.md (D2). v1 stores project memory per user. That design cannot share a lead's
or designer's knowledge with a teammate's session, and it cuts v2 off from the channels in Q2 that survive
compaction. v2's goal requires revisiting D2.

### Q2. Delivery channel: push, pull or native files

**Evidence.**
- **Must-choose retrieval is skipped.** A skill was not invoked in 56% of runs and the passive index won 100% vs
  53%/79% [VERCEL]. An on-demand dependency-graph tool reached 99.4% on hidden-dependency tasks, but 58% of trials
  with access made zero calls [CODECOMPASS]. Claude Code defers MCP tools behind tool search unless `alwaysLoad`
  is set [CODEGRAPH]. Skill descriptions are truncated at 1,536 chars, and the listing is capped at 1% of context,
  dropping the least-invoked first [CC-SKILLS].
- **Bulk push is ignored or costs more.** Overviews added 20-23% cost for no gain [ETH-AGENTSMD]. v1's pushed items
  were essentially never read [V1-TELEMETRY]. Adherence decays within a session whatever the file's size or
  position [ADHERENCE].
- **Every vendor converged on trigger-loaded native files**: Claude `paths:` rules and nested CLAUDE.md on read,
  Copilot `applyTo`, Cursor globs, Windsurf glob mode, Kiro `fileMatch`, Amp subtree AGENTS.md on read, CodeRabbit
  filename-pattern learnings [CC-MEMORY][COPILOT-INSTR][CURSOR-RULES][DEVIN-DESKTOP][KIRO][AMP-AGENTSMD][CODERABBIT].
- **Native files survive and hook text doesn't.** Project-root CLAUDE.md, unscoped rules and auto memory are re-read
  after compaction; hook context is summarized away [CC-CONTEXT]. Plugin hook output has regressed upstream
  [CC-ISSUE-12151]. Hook fields over 10,000 chars spill to a file the model is not asked to read [CC-HOOKS].
- **Subagents need their own channel.** They lack auto memory; Explore/Plan skip CLAUDE.md; SubagentStart is the
  only push [CC-SUBAGENTS].
- **Anthropic's own guidance favours identifiers over content:** keep "lightweight identifiers (file paths,
  stored queries, web links)" and load data just in time, noting that "runtime exploration is slower than
  retrieving pre-computed data" [ANTHROPIC-CTXENG].
- **A third mode exists but is unmeasured:** injecting context on the agent's own actions, such as GitNexus's
  PreToolUse enrichment of grep/glob or v1's injection on the first Read/Edit of a path [GITNEXUS].

**For v2.** Three tiers:
- **Tier 0, always on:** a compressed index (routes from areas and tasks to paths, decisions and playbooks), in a
  native file so it survives compaction and reaches most subagents.
- **Tier 1, path- or task-triggered:** the conventions and decisions that bind the files being touched, through
  native `paths:` rules where possible, or a PreToolUse hook on first touch.
- **Tier 2, pulled:** full bodies as plain files the agent Reads.

Use hooks only for what must be computed at that moment: freshness verdicts, subagent briefs, compaction steering.
Write them as facts, not commands. For "create a component", the index routes to the components area, and the first
write under `src/components/**` loads its conventions and decisions.

### Q3. Structure of a project "mindmap"

**Evidence.**
- **An index helps; a tour doesn't.** Overviews did not shorten the path to the first relevant file
  [ETH-AGENTSMD]. Guidance that helped was 30% structural pointers (which file, function, relation), 47%
  procedures and 23% quality gates, and its gain was localization [PROBE-REFINE]. The winning Vercel index was
  pipe-delimited paths, not prose [VERCEL]. C4 advises against storing code-level diagrams, which "most IDEs can
  generate … on demand" [C4].
- **Progressive disclosure is the common shape.** Skill names then bodies [CC-SKILLS]; DeepWiki MCP's structure,
  then contents, then ask [DEEPWIKI]; Serena's memory-name list [SERENA]; Letta's always-visible file tree with
  on-demand files [LETTA-CTXREPO]; Claude's MEMORY.md index plus topic files [CC-MEMORY]; a map-only boot
  [MEMORY-VAULT]. Read-everything boots do not scale [CLINE-MB].
- **Graphs pay for structure queries, not for ranking knowledge.** Code-graph tools cut tokens but can lower
  answer quality (83% vs 92%) and keep ~80% more context resident [CBM-PAPER][CODEGRAPH]. RepoGraph adds ~2
  points at a token cost [REPOGRAPH]. GraphRAG often underperforms plain RAG except on multi-hop questions
  [GRAPHRAG-BENCH], and v1's graph ranking boost was a wash [V1-TELEMETRY].
- **Decisions need a fixed shape.** BMAD's architecture records are `AD-n` with **Binds / Prevents / Rule**
  ("decisions, not rationale; rationale lives in the log") [BMAD]. MADR adds status, decision-makers, consulted and
  a Confirmation (fitness-function) field [MADR]. Accepted ADRs should bind agents, and a stale ADR kept an
  obsolete abstraction alive [DAVIDSON]. Compaction summaries drop rejected options unless carried explicitly
  [COMPACT-CANON]. Conflicting implicit decisions are the dominant multi-agent failure [COGNITION].
- **Procedural memory has measured gains.** Playbooks (+10.6%) [ACE], induced workflows (+24.6% to +51.1%
  relative) [AWM], and memory distilled from successes and failures (+4.6% on SWE-bench Verified)
  [REASONINGBANK]. Practitioners converge on task-shaped files: feature maps, job notes, Devin playbooks
  [PSTACK][MEMORY-VAULT][DEVIN-KNOWLEDGE].
- **Two kinds of context, two cadences.** Implementation context (commands, constraints, pitfalls) "must be tiny"
  and is always loaded. Planning context (rationale, rejected approaches, ownership) is "consulted in bursts"
  [BMAD].

**For v2.** A small hierarchy with typed links, not a semantic graph:
1. **Root index** (Tier 0): areas and task types → paths → the decisions, conventions and playbooks that own them.
2. **One node per area or feature** (for example "UI components"): fixed sections for where it lives, the exemplar
   to copy (agents copy existing patterns [PSTACK]), conventions, gotchas, and owner.
3. **Decision records**: claim, `binds` (path globs), rule, rejected alternatives, decided by / consulted,
   `enforced_by`, status / supersedes.
4. **Structure computed on demand**, never stored: the component inventory comes from the code at request time.

Links are typed (binds, supersedes, owned-by, see-also). There is no ranking boost over them.

### Q4. Capture: manual, at-decision, automatic extraction, and the noise/poisoning risk

**Evidence.**
- **Explicit capture dominates.** 43 of 44 gstack learnings came from an explicit command [GSTACK]. Copilot's
  agent stores a fact through a tool call during the task, with citations, when it finds "actionable implications"
  [COPILOT-BLOG].
- **Every vendor that auto-captures put a human or a signal gate in front of it.** Cursor added approval for
  background memories, then removed the feature [CURSOR-1-2][CURSOR-FORUM]. Augment added a memory review step
  [AUGMENT-REVIEW]. Devin's knowledge suggestions must be saved by a user [DEVIN-KNOWLEDGE]. CodeRabbit has
  `approval_delay` [CODERABBIT]. Bugbot promotes candidate rules on signal and disables them on negative signal
  [BUGBOT-LEARNING]. Augment's "noisy memory" promotes only after evidence is strong, and explicit human feedback
  weighs more than reactions or inferred outcomes [AUGMENT-EXPERTS].
- **Decision points are where team knowledge appears.** Greptile and Kiro learn from PR review comments, Augment's
  review memory runs on merge, BMAD captures with the persona when the decision is made, and Amp links commits to
  their thread [GREPTILE][KIRO][AUGMENT-EXPERTS][BMAD][AMP-THREADS].
- **Rewriting memory destroys it.** mem0 dropped UPDATE/DELETE in 2026 because "overwrites erased key details"
  [MEM0-2026]. ACE names brevity bias and context collapse from iterative rewrites [ACE]. Models over-edit
  Markdown lists [ANTHROPIC-HARNESS]. Agents copy the outputs of similar retrieved memories, so bad entries
  propagate [EXP-FOLLOWING].
- **Admission filters that exist:** "would removing this line change agent behavior?" and pitfalls only from
  observed failure [BMAD]; durable, decision-changing, not lint-enforceable [PSTACK]; add a rule only after the same
  mistake repeats [CURSOR-RULES]; a 12-bullet cap and a "nothing to record" answer [CURSOR-CL].
- **Poisoning risk is high and detectors are unreliable** (B.4): 98.2% query-only injection [MINJA], invisible
  rules-file payloads [PILLAR], unapproved memory writes [SPAIWARE], detectors at 0/135 [MINJA].

**For v2.**
- Capture at decision points: an explicit "record decision" or "record convention" action, PR merge, and resolved
  review threads.
- Background extraction only *proposes* candidates into a review queue. A candidate is promoted on recurrence or
  human approval and demoted on negative signal.
- Store append-only with supersede. Never rewrite in place.
- Every record carries its author, role and source pointer.
- Rules a linter or hook can enforce become backlog items for that lint or hook, not memory prose.
- Scan writes for invisible Unicode, and never auto-promote agent output into binding records.

### Q5. Freshness: anchors, verification, drift

**Evidence.**
- **Copilot's citation check is the only freshness mechanism with outcome data.** Citations are checked against the
  current branch before use; a contradicted memory is replaced; a confirmed one is re-stored, refreshing its
  timestamp; unused ones expire after 28 days [COPILOT-BLOG][COPILOT-DOCS]. The check is prompt-induced, not a
  deterministic checker.
- **Deterministic alternatives exist, without outcome data:** `Verified <date> against <sha>` plus
  `git log --diff-filter=DR` [BMAD]; code-coupled snippets that fail a PR check on drift [SWIMM]; reference checks
  and rename rewrites [SERENA]; file watchers and "stale index after commit" hooks [CODEGRAPH][GITNEXUS];
  recompute-per-request [AIDER].
- **Bi-temporal validity** (invalidate, don't delete, with provenance to the source episode) is the strongest
  model for changing facts [ZEP-PAPER].
- **Stale knowledge actively misleads.** Devin's Session Insights flags "Misleading Knowledge" written for a
  previous code version [DEVIN-INSIGHTS]. A stale ADR kept a dead abstraction alive [DAVIDSON].
- **Retirement depends on provenance.** Observed or generated facts can expire unused [COPILOT-DOCS]. Human or
  incident rules should die only when their subject is gone or a human removes them [BMAD]. v1 rejected
  usage-frequency forgetting as rich-get-richer bias [V1-TELEMETRY].

**For v2.**
- Anchor every record to path globs and, where useful, a symbol or `grep` check.
- At delivery, run cheap deterministic checks (path exists, pattern present) and stamp `verified @<sha>`. Inject a
  drifted record as "drifted: re-check" or not at all, and queue it for its owner.
- Never store structure.
- Carry decisions with their rejected options through compaction (Compact Instructions, ledger row A14).
- Expire by provenance, not by usage counts.

### Q6. Token economics

**Evidence.**
- **Costs of always-on content:** +20-23% for generated files, up to +19% for human-written ones, +2.45 to +3.92
  steps [ETH-AGENTSMD]. An AGENTS.md can also *save*: -16.58% output tokens and -28.64% runtime in one field study
  [LULLA].
- **Caps the market converged on:**

  | Surface | Cap |
  |---|---|
  | Tuned guidance [PROBE-REFINE] | 3,000 chars (~750 tokens) |
  | Vercel index [VERCEL] | 8 KB |
  | Aider map [AIDER] | 1K tokens by default |
  | CLAUDE.md [CC-MEMORY] | under 200 lines |
  | Auto memory [CC-MEMORY] | 200 lines or 25 KB |
  | Hook field [CC-HOOKS] | 10,000 chars |
  | Skill description [CC-SKILLS] | 1,536 chars |
  | Windsurf rules [DEVIN-DESKTOP] | 6,000 global; 12,000 per file |
  | Cursor rule [CURSOR-RULES] | under 500 lines |
  | Devin AGENTS.md read [DEVIN-AGENTSMD] | first 16 KiB |

- **On-demand retrieval saves tokens at a quality risk:** codegraph -62% tokens but +80% resident context
  [CODEGRAPH]; codebase-memory-mcp 10x fewer tokens with quality 92% → 83% [CBM-PAPER]; Augment -20% to -40% cost
  at ±2 points [AUGMENT-COST]; Unblocked -48% tokens (vendor) [UNBLOCKED]; Anthropic -84% tokens from clearing
  [ANTHROPIC-CTXMGMT].
- **More context can lower quality:** context rot [CONTEXT-ROT], a larger memory window derailing more
  [VENDING-BENCH], full context beating memory systems in mem0's own 2025 table [MEM0-PAPER], and within-session
  adherence decay [ADHERENCE].
- **Unread bytes are pure cost:** v1 pushed but saw ~0 reads [V1-TELEMETRY].
- **Prompt caching:** keep the always-on prefix stable. Manus cites cached input at $0.30 vs $3 uncached per
  million tokens [MANUS].

**For v2.**

| Tier | Budget |
|---|---|
| Tier 0 | about 3,000 chars, stable across a session (cache-friendly) |
| Tier 1 | at most ~3 items and ~700 B to 2 KB per trigger, at most once per path per session |
| Tier 2 | unbounded, but only when pulled |

Count resident context and end-to-end task tokens, not only bytes per injection. Add a ratchet test so no surface
grows "until consciously budgeted" [GSTACK].

### Q7. Measurement and evals

**Evidence.**
- **Usable metrics already exist:**
  - task success and cost per task [ETH-AGENTSMD]
  - steps to the first relevant file, and whether named tools get used [ETH-AGENTSMD]
  - evaluable-patch rate (localization) vs per-patch precision [PROBE-REFINE]
  - context recall and precision, explored vs used [CONTEXTBENCH]
  - merge rate and review feedback by A/B [COPILOT-BLOG]
  - "Keep Rate" (agent code still present after fixed intervals) [CURSOR-HARNESS]
  - Useful vs Misleading knowledge per item [DEVIN-INSIGHTS]
- **Memory benchmarks are disputed.** LoCoMo vendor numbers conflict. Its LLM judge accepted 62.81% of wrong but
  adjacent answers [PENFIELD][ZEP-BLOG]. Full context beat every memory system in one vendor's own table
  [MEM0-PAPER].
- **Results don't transfer across models.** Guidance tuned for one model destabilized another [PROBE-REFINE].
  Developer files helped every agent except Claude Code [ETH-AGENTSMD].
- **Practitioner harnesses:**
  - a with/without "arm benchmark" kept as a research instrument, not a release gate [GSTACK]
  - blinded evals graded from the files the agent actually opened, judged by a different model family [PSTACK]
  - knowledge-update and abstention as first-class categories [LONGMEMEVAL]
- **v1 is the cautionary case.** It had a retrieval gate (recall@2 = 1.0 on golden queries) but no behavioral
  evidence that agents used what was delivered [V1-TELEMETRY].

**For v2.** Build the A/B harness before adding surfaces:
- **Setup:** a fixture repo with planted decisions, conventions and role-owned rules, tasks like "create a
  component", and two arms (plugin on / off), run per model.
- **Metrics:**
  - task success
  - tokens and cost
  - steps to the first relevant file
  - compliance with planted decisions, checked deterministically on the diff
  - per-item delivered/used/misleading counts
- **Grading:** exact or deterministic checks over LLM judges.

### Q8. Team and role perspectives

**Evidence.**
- **No system models a role's knowledge as an attributed, separately maintained store** (B.3). The pieces exist
  separately:
  - personas with persistent facts and a team layer [BMAD]
  - decision-makers / consulted [MADR]
  - product / tech / structure facets [KIRO][SPECKIT]
  - design-to-code mapping [FIGMA-MCP]
  - authority from write permission [COPILOT-DOCS]
  - per-agent git-tracked memory [CC-SUBAGENTS]
- **Role separation helps when roles exchange structured artifacts.** MetaGPT's SOP roles exchange documents by
  subscription, and "sharing all information with every agent can lead to information overload" [METAGPT]. Role
  specification gave +9.4% [MAST].
- **Personas keyed on agent type misfire.** v1's role card, keyed on agent type, delivered a test-first card to a
  research task [V1-TELEMETRY].
- **The real risk between roles is conflicting implicit decisions**, which multiply errors across agents
  [COGNITION][SCALING-AGENTS].

**For v2.**
- Model a role as **authority and ownership**, not as a persona:
  - every record names who asserted it and in which role (lead, PM, designer), plus who was consulted;
  - each role owns artifact types and path globs. The designer owns component visual rules and design-token usage
    under the UI paths. The PM owns acceptance criteria and scope. The lead owns architecture decisions.
- Deliver by trigger, so an agent creating a component gets the designer-owned and lead-owned records that bind
  `src/components/**`, attributed.
- When two roles' records conflict, surface them as one open decision rather than injecting both.
- Pull live facets from their source of truth by pointer (Figma Code Connect, the issue tracker) instead of
  copying them.
- Treat this as a hypothesis: nothing measures it yet, so it belongs in the Q7 harness as its own arm.

---

## Gaps and things not verified

- **Vendor numbers are unreplicated.** No one has independently replicated Vercel's, Copilot's, Augment's or
  codegraph's results. Copilot gives no sample sizes.
- **Developer-written context files: +2.4 vs +4.** [ETH-AGENTSMD] is cited here at +2.4 points (p=0.21) from the
  paper body. One scan pass reported "+4%"; the body figure is used.
- **No measurement of hook-triggered injection.** No study measures injection on the agent's own actions (PreToolUse
  enrichment), role-attributed knowledge, or a routing table in isolation.
- **Abstract-level reads only:** [ADHERENCE], [KHATRI], [VENDING-BENCH], MCPTox, AIShellJack and A-MemGuard. The
  OWASP ASI06 mitigations come from a secondary summary.
- **Unconfirmed vendor details:** Copilot Memory GA status; DeepWiki refresh cadence; whether the Windsurf memory
  injection was fixed; where Augment memories are stored.
- **Cursor Memories:** forum replies disagree on whether 2.1.x removed the feature itself or only its management
  screen. Cursor staff told users to export memories into Rules either way.
- **Internal numbers ([V1-TELEMETRY]) are small samples** from one maintainer's machine. "Read" counts miss silent
  use of injected text.

---

## Top 12 evidence-backed rules for v2

1. **Store only what the code cannot say.** Never generate or inject repo overviews, directory tours or stack
   lists. Admit a line only if removing it would change agent behavior. [ETH-AGENTSMD] (overviews: -0.5 to -2 pts,
   +20-23% cost); [BMAD]; [OPENSPEC] (anti-back-fill).
2. **Keep the always-on layer a compressed routing index under a hard cap (~3,000 chars), not prose.**
   [PROBE-REFINE] (3,000-char guidance, +4.7 pts via localization); [VERCEL] (8 KB index, 100%); [CONTEXT-ROT].
3. **Push the index. Load details by observable triggers (path glob, file type, named task), never by model
   choice alone.** [VERCEL] (skill uninvoked in 56% of runs); [CODECOMPASS] (58% zero tool calls); glob-loaded
   rules in Claude, Copilot, Cursor, Windsurf and Kiro.
4. **Deliver through native, git-tracked files that survive compaction and reach subagents.** Use hooks only for
   computed, per-moment facts, phrased as facts. This means revisiting v1's "never write native files" rule.
   [CC-CONTEXT] (hook text summarized away); [CC-ISSUE-12151]; [CC-HOOKS] (10K cap); [V1-TELEMETRY] (0 reads of
   pushed items).
5. **Team knowledge lives in the repo and is reviewed like code. Personal practice stays user-local. Derived
   indexes are local caches.** [CURSOR-FORUM][DEVIN-DESKTOP][DEVIN-KNOWLEDGE] (vendor retreat from per-user
   memory); [AAIF] (60K+ repos); [CBM] (6 GB committed graph).
6. **Every record carries anchors, provenance (who, which role, source) and a verified-at SHA. Check anchors
   deterministically before delivery; never inject drifted items as truth.** [COPILOT-BLOG] (citations + verify →
   merge rate 83%→90%); [BMAD]; [SWIMM]; [DAVIDSON] (stale ADR harm).
7. **Compute structure on demand from code** (component inventory, symbols, dependencies) **instead of storing
   it.** [AIDER]; [CODY-FAQ]; [LATENT-SPACE]; [CLINE-NOINDEX]; [C4].
8. **Make decisions first-class, path-bound records** with rejected alternatives, decision-makers and an
   `enforced_by` pointer. Supersede, never delete or rewrite. [BMAD] (Binds/Prevents/Rule); [MADR];
   [COMPACT-CANON] (6/15 kept without explicit carry); [ZEP-PAPER]; [MEM0-2026] (ADD-only).
9. **Capture explicitly at decision points.** Automatic extraction only proposes; promote on recurrence or
   approval, demote on negative signal. Route lint-enforceable rules to lint. [GSTACK] (43/44 explicit);
   [BUGBOT-LEARNING]; [AUGMENT-EXPERTS]; [CODERABBIT]; [CURSOR-RULES].
10. **Treat every memory write as untrusted input:** authority gating, invisible-Unicode scan, no
    auto-reingestion of agent output, quarantined consolidation. [MINJA] (98.2% injection); [AGENTPOISON];
    [PILLAR]; [SPAIWARE]; [OWASP-ASI06]; [COPILOT-DOCS].
11. **Model roles as authority and path ownership delivered by trigger, not as personas keyed on agent type.**
    Surface cross-role conflicts as open decisions. Lower confidence: no system measures this. [BMAD]; [MADR];
    [KIRO]; [FIGMA-MCP]; [METAGPT]; [V1-TELEMETRY].
12. **Ship a with/without A/B harness before adding surfaces, and run it per model.** Measure success, cost,
    steps to the first relevant file, compliance with planted decisions, and per-item misleading rate.
    [ETH-AGENTSMD]; [PROBE-REFINE] (model instability); [DEVIN-INSIGHTS]; [GSTACK]; [V1-TELEMETRY].

---

## Sources

Papers
- [ETH-AGENTSMD] Gloaguen, Mündler, Müller, Raychev, Vechev, *Evaluating AGENTS.md: Are Repository-Level Context Files Helpful for Coding Agents?*, arXiv 2602.11988 (v1 2026-02-12, v3 2026-09-29). https://arxiv.org/abs/2602.11988
- [PROBE-REFINE] Shepard & Albrecht, *Probe-and-Refine Tuning of Repository Guidance for Coding Agents*, arXiv 2606.20512 (2026-06-18). https://arxiv.org/abs/2606.20512
- [KHATRI] Khatri, *Do Context Files Help Coding Agents?*, arXiv 2607.27250 (2026-07-28). https://arxiv.org/abs/2607.27250
- [ADHERENCE] *Instruction Adherence in Coding Agent Configuration Files*, arXiv 2605.10039. https://arxiv.org/abs/2605.10039
- [LULLA] Lulla et al., arXiv 2601.20404 (v2 2026-03-30). https://arxiv.org/abs/2601.20404
- [CONTEXT-FILES-STUDY] Chatlatanagulchai et al., arXiv 2511.12884 (v2 2026-08-09). https://arxiv.org/abs/2511.12884
- [VASILOPOULOS] Vasilopoulos, arXiv 2602.20478 (2026-02-24). https://arxiv.org/abs/2602.20478
- [CONTEXT-ROT] Hong, Troynikov, Huber, *Context Rot*, Chroma (2025-07-14). https://www.trychroma.com/research/context-rot
- [VENDING-BENCH] Backlund & Petersson, *Vending-Bench*, arXiv 2502.15840. https://arxiv.org/abs/2502.15840
- [REPOGRAPH] Ouyang et al., *RepoGraph*, ICLR 2025, arXiv 2410.14684. https://arxiv.org/abs/2410.14684
- [CONTEXTBENCH] Li et al., *ContextBench*, arXiv 2602.05892 (2026-02-05). https://arxiv.org/abs/2602.05892
- [CODECOMPASS] Paipuru, *CodeCompass*, arXiv 2602.20048 (2026-02-23). https://arxiv.org/abs/2602.20048
- [CBM-PAPER] Vogel et al., *Codebase-Memory*, arXiv 2603.27277 (2026-03-28). https://arxiv.org/abs/2603.27277
- [GRAPHRAG-BENCH] GraphRAG-Bench, arXiv 2506.05690. https://arxiv.org/abs/2506.05690
- [ZEP-PAPER] Rasmussen et al., *Zep: A Temporal Knowledge Graph Architecture for Agent Memory*, arXiv 2501.13956. https://arxiv.org/abs/2501.13956
- [MEM0-PAPER] Chhikara et al., *Mem0*, arXiv 2504.19413. https://arxiv.org/abs/2504.19413
- [SLEEPTIME] Lin et al., *Sleep-time Compute*, arXiv 2504.13171. https://arxiv.org/abs/2504.13171
- [LONGMEMEVAL] Wu et al., *LongMemEval*, ICLR 2025, arXiv 2410.10813. https://arxiv.org/abs/2410.10813
- [MEMAGENTBENCH] *MemoryAgentBench*, arXiv 2507.05257. https://arxiv.org/abs/2507.05257
- [ACE] *Agentic Context Engineering*, arXiv 2510.04618. https://arxiv.org/abs/2510.04618
- [REASONINGBANK] *ReasoningBank*, arXiv 2509.25140. https://arxiv.org/abs/2509.25140
- [AWM] Wang et al., *Agent Workflow Memory*, ICML 2025, arXiv 2409.07429. https://arxiv.org/abs/2409.07429
- [EXP-FOLLOWING] arXiv 2505.16067 (experience-following in memory agents). https://arxiv.org/abs/2505.16067
- [METAGPT] Hong et al., *MetaGPT*, ICLR 2024, arXiv 2308.00352. https://arxiv.org/abs/2308.00352
- [MAST] Cemri et al., *Why Do Multi-Agent LLM Systems Fail?*, arXiv 2503.13657. https://arxiv.org/abs/2503.13657
- [SCALING-AGENTS] Kim et al., *Towards a Science of Scaling Agent Systems*, arXiv 2512.08296. https://arxiv.org/abs/2512.08296
- [PROMPT-INFECTION] Lee & Tiwari, *Prompt Infection*, arXiv 2410.07283. https://arxiv.org/abs/2410.07283
- [CAMEL] Debenedetti et al., *Defeating Prompt Injections by Design* (CaMeL), arXiv 2503.18813. https://arxiv.org/abs/2503.18813
- [MINJA] Dong et al., *A Practical Memory Injection Attack against LLM Agents* (MINJA), arXiv 2503.03704. https://arxiv.org/abs/2503.03704
- [AGENTPOISON] Chen et al., *AgentPoison*, arXiv 2407.12784. https://arxiv.org/abs/2407.12784
- [AMEMGUARD] *A-MemGuard*, arXiv 2510.02373. https://arxiv.org/abs/2510.02373
- [MCPTOX] *MCPTox*, AAAI 2026. https://ojs.aaai.org/index.php/AAAI/article/view/40895

Anthropic / Claude Code
- [CC-MEMORY] Claude Code docs, *How Claude remembers your project*. https://code.claude.com/docs/en/memory
- [CC-CONTEXT] Claude Code docs, *Context window* (what survives compaction). https://code.claude.com/docs/en/context-window
- [CC-HOOKS] Claude Code docs, *Hooks reference*. https://code.claude.com/docs/en/hooks
- [CC-SUBAGENTS] Claude Code docs, *Subagents*. https://code.claude.com/docs/en/sub-agents
- [CC-SKILLS] Claude Code docs, *Skills*. https://code.claude.com/docs/en/skills
- [CC-ISSUE-12151] anthropics/claude-code issue #12151 (plugin hook output not captured). https://github.com/anthropics/claude-code/issues/12151
- [ANTHROPIC-CTXMGMT] Anthropic, *Managing context on the Claude Developer Platform* (2025-09-29). https://www.anthropic.com/news/context-management
- [ANTHROPIC-HARNESS] Anthropic, *Effective harnesses for long-running agents* (2025-11-26). https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- [ANTHROPIC-CTXENG] Anthropic, *Effective context engineering for AI agents* (2025-09-29). https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- [LATENT-SPACE] Latent Space, Claude Code episode with Boris Cherny (2025-05-07). https://www.latent.space/p/claude-code

GitHub, Cursor, Devin, Windsurf, standards
- [COPILOT-BLOG] GitHub Blog, *Building an agentic memory system for GitHub Copilot* (2026-01-15). https://github.blog/ai-and-ml/github-copilot/building-an-agentic-memory-system-for-github-copilot/
- [COPILOT-DOCS] GitHub Docs, *Copilot Memory*. https://docs.github.com/en/copilot/concepts/agents/copilot-memory
- [COPILOT-INSTR] GitHub Docs, *Adding repository custom instructions*. https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions
- [GH-UNICODE] GitHub Changelog, hidden Unicode warning (2025-05-01). https://github.blog/changelog/2025-05-01-github-now-provides-a-warning-about-hidden-unicode-text
- [CURSOR-RULES] Cursor Docs, *Rules*. https://cursor.com/docs/context/rules
- [CURSOR-1-2] Cursor Changelog 1.2 (2025-07-03). https://cursor.com/changelog/1-2
- [CURSOR-FORUM] Cursor Forum, *Are my memories gone?* (staff reply 2025-11-25). https://forum.cursor.com/t/are-my-memories-gone/144057
- [CURSOR-CL] cursor/plugins, `continual-learning`. https://github.com/cursor/plugins/tree/main/continual-learning
- [BUGBOT-LEARNING] Cursor Blog, *Bugbot learning* (2026-04-08). https://cursor.com/blog/bugbot-learning
- [CURSOR-HARNESS] Cursor Blog, *Continually improving the agent harness* (2026-04-30). https://cursor.com/blog/continually-improving-agent-harness
- [CURSOR-SEMSEARCH] Cursor Blog, *Improving agent with semantic search* (2025-11-06). https://cursor.com/blog/semsearch
- [DEVIN-DESKTOP] Devin Desktop (ex-Windsurf) docs, *Memories & Rules*. https://docs.devin.ai/desktop/cascade/memories
- [DEVIN-KNOWLEDGE] Devin docs, *Knowledge* (deprecated). https://docs.devin.ai/product-guides/knowledge
- [DEVIN-SKILLS] Devin docs, *Skills*. https://docs.devin.ai/product-guides/skills
- [DEEPWIKI] Devin docs, *DeepWiki*. https://docs.devin.ai/work-with-devin/deepwiki
- [DEVIN-INSIGHTS] Devin docs, *Session Insights*. https://docs.devin.ai/product-guides/session-insights
- [DEVIN-AGENTSMD] Devin docs, *AGENTS.md*. https://docs.devin.ai/onboard-devin/agents-md
- [SPAIWARE] Embrace The Red, *Windsurf: Memory-Persistent Data Exfiltration* (2025-08-22). https://embracethered.com/blog/posts/2025/windsurf-spaiware-exploit-persistent-prompt-injection/
- [AGENTSMD] agents.md. https://agents.md/
- [AAIF] Linux Foundation, *Agentic AI Foundation* announcement (2025-12-09). https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation
- [LLMSTXT] llmstxt.org (proposed 2024-09-03). https://llmstxt.org/
- [AHREFS] Ahrefs, *97% of llms.txt files never get read* (2026-06-15). https://ahrefs.com/blog/llmstxt-study/
- [VERCEL] Vercel, *AGENTS.md outperforms skills in our agent evals* (2026-01-27). https://vercel.com/blog/agents-md-outperforms-skills-in-our-agent-evals
- [C4] C4 model, *Code diagram*. https://c4model.com/diagrams/code

Context engines and code graphs
- [AIDER] Aider, *Repository map*. https://aider.chat/docs/repomap.html ; SWE-bench Lite result (2024-05-22) https://aider.chat/2024/05/22/swe-bench-lite.html
- [AUGMENT-MCP] Augment, *Context Engine MCP now live* (2026-02-06). https://www.augmentcode.com/blog/context-engine-mcp-now-live
- [AUGMENT-COST] Augment, *Auggie vs Claude Code on cost and quality* (2026-05-15). https://augmentcode.com/blog/auggie-beats-claude-code-on-cost-and-quality
- [AUGMENT-LINEAGE] Augment, *Context Lineage* (2025-07-29). https://augmentcode.com/blog/announcing-context-lineage
- [AUGMENT-REVIEW] Augment changelog, *Memory review* (2025-09-08). https://www.augmentcode.com/changelog/memory-review
- [AUGMENT-EXPERTS] Augment docs, *Experts memory*. https://docs.augmentcode.com/cosmos/experts-memory
- [CODY-FAQ] Sourcegraph Cody FAQ (embeddings replaced by Sourcegraph Search). https://sourcegraph.com/docs/cody/faq
- [AMP-THREADS] Amp docs, *Threads*. https://ampcode.com/docs/threads
- [AMP-AGENTSMD] Amp docs, *AGENTS.md*. https://ampcode.com/docs/customize/agents-md
- [CLINE-NOINDEX] Cline, *Why Cline doesn't index your codebase* (2025-05-27). https://cline.bot/blog/why-cline-doesnt-index-your-codebase-and-why-thats-a-good-thing
- [CLINE-MB] Cline docs, *Memory Bank*. https://docs.cline.bot/best-practices/memory-bank
- [SERENA] Serena, memories docs. https://oraios.github.io/serena/02-usage/045_memories.html ; repo https://github.com/oraios/serena
- [CODEGRAPH] colbymchenry/codegraph (benchmark 2026-08-05). https://github.com/colbymchenry/codegraph
- [GITNEXUS] GitNexus. https://github.com/abhigyanpatwari/GitNexus
- [CBM] DeusData/codebase-memory-mcp. https://github.com/DeusData/codebase-memory-mcp
- [POTPIE] Potpie. https://github.com/potpie-ai/potpie

Memory systems, decision logs, roles
- [BASIC-MEMORY] Basic Memory. https://github.com/basicmachines-co/basic-memory
- [ZEP-RESEARCH] Zep research page. https://getzep.com/research ; [ZEP-BLOG] *Is Mem0 really SOTA?* (2025-05-06) https://www.getzep.com/blog/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/
- [MEM0-2026] mem0, *The token-efficient memory algorithm* (2026). https://mem0.ai/blog/mem0-the-token-efficient-memory-algorithm
- [PENFIELD] Penfield Labs, LoCoMo answer-key audit (2026-04). https://dev.to/penfieldlabs/we-audited-locomo-64-of-the-answer-key-is-wrong-and-the-judge-accepts-up-to-63-of-intentionally-33lg
- [LETTA-CTXREPO] Letta, *Context Repositories* (2026-02-12). https://www.letta.com/blog/context-repositories ; benchmarking post (2025-08-12) https://www.letta.com/blog/benchmarking-ai-agent-memory
- [COGNEE] Cognee, knowledge-graph memory benchmarks (2026-01-07). https://www.cognee.ai/blog/deep-dives/knowledge-graph-memory-benchmarks
- [MADR] MADR. https://adr.github.io/madr/
- [DAVIDSON] Duncan Davidson, *Coding agents love decision records* (2026-09-01). https://duncandavidson.com/agents-love-decisions
- [CODERABBIT] CodeRabbit docs, *Learnings*. https://docs.coderabbit.ai/knowledge-base/learnings
- [GREPTILE] Greptile, *Learning*. https://www.greptile.com/learning
- [UNBLOCKED] Unblocked, MCP overview. https://docs.getunblocked.com/unblocked-mcp/mcp-overview
- [SWIMM] Swimm docs, *Auto-sync*. https://docs.swimm.io/features/keep-docs-updated-with-auto-sync/
- [BMAD] BMAD-METHOD (v6.12.4), incl. *Theory of project context*. https://github.com/bmad-code-org/BMAD-METHOD
- [SPECKIT] GitHub Spec Kit. https://github.com/github/spec-kit
- [OPENSPEC] OpenSpec. https://github.com/Fission-AI/OpenSpec
- [KIRO] Kiro docs, *Steering*. https://kiro.dev/docs/steering/
- [FIGMA-MCP] Figma MCP server guide. https://github.com/figma/mcp-server-guide
- [CHATPRD] ChatPRD MCP docs. https://chatprd.ai/docs/mcp-model-context-protocol-integration
- [LINEAR-MCP] Linear MCP docs. https://linear.app/docs/mcp

Practitioners, multi-agent, security
- [PSTACK] Lauren Tan, pstack (cursor/plugins). https://github.com/cursor/plugins/tree/main/pstack ; guide Pt. 1 (2026-08-31) https://x.com/poteto/status/2094457600259842065
- [GSTACK] garrytan/gstack. https://github.com/garrytan/gstack
- [MEMORY-VAULT] jaredrhod/ai-memory-vault. https://github.com/jaredrhod/ai-memory-vault
- [COMPACT-CANON] tonydzi/compact-canon, MEASUREMENTS.md. https://github.com/tonydzi/compact-canon
- [COGNITION] Cognition, *Don't Build Multi-Agents* (2025-06-12). https://cognition.com/blog/dont-build-multi-agents
- [MANUS] Manus, *Context Engineering for AI Agents* (2025-07-18). https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
- [TRIFECTA] Simon Willison, *The lethal trifecta for AI agents* (2025-06-16). https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- [PILLAR] Pillar Security, *Rules File Backdoor* (2025-03-18). https://www.pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents
- [MCPOISON] Check Point Research, *MCPoison* (2025-08-05). https://research.checkpoint.com/2025/cursor-vulnerability-mcpoison/
- [OWASP-ASI06] OWASP Top 10 for Agentic Applications 2026, ASI06 (via secondary summary). https://goteleport.com/blog/owasp-top-10-agentic-applications

Internal
- [V1-TELEMETRY] second-brain v1 telemetry, probes and measurements (unpublished; small samples from the
  maintainer's sessions): value-loop injected-vs-read counts, compaction frequency, graph-boost measurement, the
  role-card observation.
