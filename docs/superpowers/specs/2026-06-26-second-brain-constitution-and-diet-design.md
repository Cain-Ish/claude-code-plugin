# second-brain Constitution + Diet — design (v2, research-grounded)

**Date:** 2026-06-26
**Status:** Draft for implementation
**Author:** brainstormed with user (machuta); v2 incorporates two deep-research streams
**Supersedes direction of:** [[second-brain-v1-redesign]] (2026-05-01, regressed)

> v2 changelog: folds in two verified research streams — (A) AI-memory systems
> landscape (Hermes/MemGPT/mem0/ARC/ProMem/Khoj), (B) coding-agent KB content model
> (Cline Memory Bank / Cursor rules / Aider repo-map / Codebase-Memory / mex / Codex CLI).
> Adds the 6-layer content model, the capture/consolidation mechanics, the
> project-orientation pillar, and the full-autonomy resolution.
>
> v3 changelog (2026-06-27): folds in a third research stream — (C) Claude Code *mechanics*
> best practices (subagents/teams, skills, hooks, context/token engineering, plan-first), from
> Anthropic primary docs + multi-agent-research-system + community. Findings: our agent/skill/hook
> mechanics are already best-practice-aligned (no rewrite). Adds the **token-discipline core
> principle** (§1 — token optimization is core to memory, cost-router is the separable
> model-routing axis), **cache-stable injection** (§3), and three workstream extensions:
> cache-aware-injection audit (P1), skill-catalog prune (P4), and **P5 plan-first soft-nudge
> guardrail**. Grounding: [[claude-mechanics-best-practices-2026-06]].
>
> v4 changelog (2026-06-28): folds in a fourth, *wider* research stream — (D) agent-architecture
> deep dive (competitive ecosystem, SOTA memory architectures, multi-agent orchestration evidence,
> agent/memory evaluation, and the **security threat model of auto-injected/auto-consolidated
> memory**). Validates the core shape; forces five changes: **P6 security & untrusted-content
> isolation** (quarantine/dual-LLM consolidation — the top new finding), **P7 graph justify-or-
> demote** (instrument overlap first; bi-temporal `supersedes` is the keeper), a **cross-encoder
> reranker** (P3), **redundancy/importance-based forgetting + a reflection op** (P4 — corrects the
> v2 "usage-ranked" wording, which is the rich-get-richer hub-bias footgun), **JIT/conversation-
> layer injection** (P1 — don't inject the wiki every turn), and **P8 evaluation & silent-failure
> detection**. Grounding: [[claude-agent-architecture-deep-2026-06]].

---

## 0. Why this document exists

The plugin works but **re-accreted into a trash collector** — the exact failure the
v1.0 redesign fixed once, now regressed (90 wiki pages / 8 categories; `auto_maintain`
100% structural failure; ~10,000× search-score corruption; one dir-resolver copy-pasted
to ~16 sites, 11 wrong — fixed 0.33.17). Root cause: accretion with no forcing function
for simplicity, and a self-cleaning loop that exists but does not reliably run.

**Two deep-research streams (2026-06-26) independently validate evolve-over-rewrite:**
the architecture has the right shape (Hermes' pillars + the hook/MCP/timer primitives map
1:1); the gaps are specific and additive. A second from-scratch rewrite would re-accrete
(v1.0 proves it). The lever is governance + three targeted additions, not replacement.

## 1. Mission (frozen north star)

**second-brain = the AI's MEMORY OF THE PROJECT + support skills/agents + an optional
cost-router wrapper.** The core is the mental model a senior developer holds *before
opening a file*: WHAT exists, WHERE it lives, WHY, HOW it works, WHY-THIS-WAY. So when the
user asks for work, Claude starts **oriented**, not re-deriving by grep.

The mission is a triad:
1. **Orientation** — the project mental model (what/where/why/how/why-this-way + a code map).
2. **Compounding personalization** — learned best practices (global + per-project) that
   become **active guardrails**, so Claude grows tailored to this user with use.
3. **Support + cost** — persona agents that keep focus / ask the right questions / enforce
   guardrails *while coding*, + an optional cost-router.

**Token discipline (core principle, added v3 2026-06-27).** Memory's job is to minimize the
high-signal token set: **JIT retrieval** (store identifiers, fetch on demand), **summarize-
before-evict** compaction, **cache-stable injection** (volatile persona/wiki context injected
LAST so the prompt-cache prefix stays warm). *Good memory IS token optimization* — it is core to
this plugin (knowledge_fetch tiers, BM25, PreCompact, hot/cold tier), **not** the cost-router's
job. The **cost-router is only the orthogonal model-routing axis** (which model — Opus plans,
Sonnet implements, Haiku mechanical — not which tokens); the two axes meet at the subagent
boundary. Grounding: [[claude-mechanics-best-practices-2026-06]] (sourced research, 2026-06-27).

**IS NOT:** a session log; a trivia dump; a graph for its own sake; pages that sit unread.
**Test:** *if a saved item does not actively guide a future decision, it does not belong.*

**HARD CONSTRAINT — FULLY AUTONOMOUS:** zero required user interaction. Claude + plugin
operate together automatically: auto-capture, auto-consolidate, auto-inject, auto-guard,
auto-tailor. No manual `/dream`, no manual accept, no manual pins. (Resolution in §4.)

## 2. The memory content model (target shape) — 6 layers, not a monolith

Research B converged hard (Cline, Cursor, Aider, mex, Codebase-Memory): agent project
memory is a small *layered* artifact set; the anti-pattern is one giant instruction file
that "floods context and drifts from the code."

| # | Layer | Holds | Read cadence | Update cadence |
|---|---|---|---|---|
| 1 | **Anchor / router** | tiny pointer (~one-liner + routes) | hot (always) | on structure change |
| 2 | **Intent & requirements** | vision/concept, goals, **non-goals** | hot | on scope change (human/decision) |
| 3 | **Architecture + conventions (ADR)** | why-this-way, patterns, rules; **<500 lines/rule, reference code not copy** | hot (thin) | append-only ADR/event log |
| 4 | **Code-structure map** | token-capped, **PageRank-ranked signature index** (tree-sitter); the WHERE | on-demand | **regenerated out-of-band on code change** (drift); never hand-maintained |
| 5 | **Relations graph** | typed edges (CALLS/IMPORTS/IMPLEMENTS) + **code↔requirement traceability** → blast-radius | on-demand (MCP) | with the map |
| 6 | **Active / learned memory** | current focus + learned facts/practices | hot (thin) | **background extraction + usage-ranked pruning** |

Mapping to current storage: 1=CLAUDE.md; 2=USER.md+PROJECT.md(intent); 3=wiki
decisions+PROJECT conventions; **4=MISSING**; **5=node↔node graph only, no code links**;
6=extraction+persona signals+dream.

## 3. Capture / consolidation mechanics (the how)

Research A, verified across ≥3 independent sources each:

- **Salience-filtered write path** (the anti-trash mechanism): filter low-signal →
  canonicalize → dedup → priority-score (mem0 ADD/UPDATE/DELETE/**NOOP**). Never verbatim.
- **Incremental capture beats threshold-triggered** (ARC ablation 31% vs 24-27%): consolidate
  per-turn (Stop / optionally UserPromptSubmit), **not** only at a budget threshold.
  PreCompact = safety-net (summarize-before-evict, MemGPT paging boundary).
- **Grounded learned rules**: every guardrail must cite the transcript evidence that produced
  it, or false beliefs lock in forever ("API X always fails → never retried").
- **Out-of-band doubt-loop consolidation** (ProMem/ARC): first-pass extract → self-question
  → supplementary memory → dedup; expensive + non-interactive ⇒ belongs on the timer.
- **Redundancy/importance-ranked forgetting** (CORRECTED v4): forget by dedup-merge + low
  importance, **NOT raw usage_count/recency**. Round-2 evidence: goal-agnostic decay *demonstrably
  hurts* (2511.21726); the Ebbinghaus model was never ablated; and frequency-boosting is the recsys
  "rich-get-richer" hub bias — literally our ~10,000× score-inflation bug. Never hard-delete (archive
  with a back-reference — already correct). Recency may *break ties*, never drive eviction.
- **Reflection** (added v4 — the one memory op with peer-reviewed ablation support, Generative
  Agents 2304.03442): periodically synthesize higher-level insights from clusters of low-level
  memories. Distinct from dedup/relate/enrich; removing it measurably degraded quality. Belongs in
  the out-of-band dream cycle.
- **Reranking** (added v4): a cross-encoder reranker over hybrid-search candidates is the
  highest-ROI retrieval add in the field (+5–15 nDCG@10; Anthropic cut top-20 failure 67%).
  Retrieve a reranked **top-3–5**, not a large top-k (context-rot: more retrieval hurts past an optimum).
- **Six atomic operations** every contextual memory needs: Consolidate, Update, Index,
  Forget, Retrieve, Condense.
- **Cache-stable + JIT injection** (v3 + SHARPENED v4, Research C/D — prompt-caching, context-rot,
  security): cache reads are ~90% cheaper within a 5-min TTL; the prefix is tools→system→messages.
  (a) **Don't inject the wiki every turn** — inject only a tiny pointer/index upfront and let
  `knowledge_search`/`fetch` Select on demand (every-turn injection guarantees context rot AND is
  the injection attack surface, §6 P6). (b) Use Claude Code's own cache-safe mechanism — append
  volatile context to the **conversation layer via `<system-reminder>`**, never mutate the cached
  prefix. Constrains `persona-context.sh` / `session-load.sh` (see P1 audit).

## 4. Autonomy resolution (constraint vs safe-erase)

Tension: full autonomy (no human gate) vs dream's human-review-before-erase. Resolved
**with research mechanisms, not by dropping safety**:
- **Safe forgetting** = redundancy/importance-ranked pruning (dedup-merge + low-importance; NOT raw
  usage frequency — v4 correction), append-only history so nothing is hard-deleted.
- **Safe guardrails** = reflection grounding (a rule can't fire unless it cites evidence; a
  contradicted rule is auto-retired).
- **Safe auto-consolidation** = stage → **auto-accept** → keep a rollback/undo trail (reversible),
  replacing the manual `dream_accept` gate.

## 5. Keep / Fix / Cut ledger

| Capability | Fate |
|---|---|
| dream (background consolidation, FORGET) | **KEEP + PROMOTE** → §3 doubt-loop + redundancy/importance forgetting + **reflection** (v4); auto-accept+rollback (§4) |
| persona L1 context / L2 brief / L3 guard / L4 quality-gate / L5 MCP | **KEEP + PROMOTE** (L3=guardrail engine, L4=salience write-path filter) |
| extraction (Stop/PreCompact + marker) | **KEEP + FIX** → run autonomously; per-turn; salience-default; grounded |
| hot tier + episodic recall + on-demand search | **KEEP** |
| **Code-structure map (layer 4)** | **ADD** (the orientation gap; use tree-sitter+PageRank, don't reinvent) |
| **Code↔knowledge relations (layer 5)** | **ADD** (typed code edges + traceability; MCP blast-radius query) |
| access-count search boost | **CUT** (~10,000× corruption) |
| typed node↔node graph | **DEMOTE** for search ranking; keep as read-time metadata; fold into layer 5 |
| 8 wiki categories | **COLLAPSE** → minimal set aligned to the 6 layers |
| 44K-token upgrade skill, dup vendored skills, dead scripts | **CUT** |
| 20-skill catalog (per-session metadata tax) | **PRUNE/MERGE** (P4) toward a minimal set; ratchet-held |
| cache-unstable volatile injection (persona/wiki) | **FIX** (P1) → JIT, conversation-layer/system-reminder, not every-turn (§3) |
| plan-first discipline (none today) | **ADD** (P5) → soft nudge on multi-file coding; skip one-liners |
| untrusted-content isolation in consolidation (v4) | **ADD** (P6) → quarantine/dual-LLM drainer; least-privilege agents; provenance; strip zero-width chars |
| tool-return injection scanner | **RECLASSIFY** (v4) → telemetry/defense-in-depth, NOT a trust boundary (≤100% evasion) |
| cross-encoder reranker | **ADD** (P3, v4) → highest-ROI retrieval gain; reranked top-3–5 |
| graph tier value (single-dev local) | **JUSTIFY-OR-DEMOTE** (P7, v4) → instrument query overlap; keep bi-temporal `supersedes` |
| memory/retrieval/guardrail evals | **ADD** (P8, v4) → LongMemEval-shaped recall + abstention + reconciliation + guard-liveness |

## 6. Workstreams (research-prioritized, dependency-ordered)

Each becomes its own implementation plan; this spec is the shared contract.

- **P0 — Governance forcing function (FIRST).** Constitution as an enforced artifact + a
  CI **surface-budget gate** (ratchet: baseline counts, fail on increase) + a generalized
  duplicate-logic source-scan (extend the 0.33.17 `process.env.HOME` guard to the
  config-read antipattern class). Nothing else is safe to change until accretion is blocked.
- **P1 — Autonomous capture loop (HIGH/LOW).** Make extraction run with zero manual steps and
  not depend on the in-session OAuth `claude` lock: out-of-band drainer timer as default
  (install on setup) and/or a deterministic non-LLM capture fallback; add the salience
  write-path filter as enforced default; per-turn incremental + PreCompact safety-net.
  **+ Cache-aware + JIT injection audit (v3, EXPANDED v4):** verify `persona-context.sh` /
  `session-load.sh` (a) do NOT inject the wiki body every turn — inject a tiny pointer/index and
  Select on demand; (b) append volatile context to the conversation layer via `<system-reminder>`,
  not the cached prefix. Measure before/after token-count of the SessionStart / UserPromptSubmit
  payload (§3). Converges with P6 (every-turn injection is also the attack surface).
- **P2 — Grounded learning → active guardrail (HIGH/MED).** Learned practices resolve to a
  PROJECT decision **or** a persona-rules.json guardrail that fires at PreToolUse — each
  carrying a citation to its transcript evidence; auto-retire contradicted rules.
- **P3 — Orientation layer (HIGH user-value).** Auto-generated, token-capped, PageRank-ranked
  code-structure map (layer 4) + typed code↔knowledge relations (layer 5), exposed via MCP
  for blast-radius, regenerated out-of-band on code change (drift detection). Prefer a
  proven generator (Aider-style tree-sitter+PageRank) over hand-rolling.
  **+ Cross-encoder reranker (added v4):** add a local-ONNX reranker over hybrid-search candidates
  (return a reranked top-3–5). Highest-ROI retrieval gain in the field; vet cross-platform like the
  vector-deps (pure-JS/no-rerank fallback). Likely delivers more than the graph tier (see P7).
- **P4 — Diet + autonomous doubt loop.** Collapse categories to the 6-layer-aligned minimal
  set; cut access-boost; demote graph (see P7); fix dream `auto_maintain` (bwrap/RestrictNamespaces);
  FORGET as centerpiece — **redundancy/importance-ranked (NOT usage-frequency — v4 correction)** +
  auto-accept+rollback; **add a reflection pass** (v4) that synthesizes cross-cutting learnings from
  memory clusters (the one ablation-backed memory op).
  **+ Skill-catalog prune (added v3):** 20 installed skills is a standing per-session metadata
  tax (~100 tokens each) + selection ambiguity; merge thin/overlapping skills toward a minimal
  set, held down by the P0 surface-budget ratchet. (Research: bloated skill catalogs degrade
  both context budget and dispatch accuracy.)
- **P5 — Plan-first guardrail (added v3, LOW effort / HIGH leverage).** A lightweight persona/flow
  **soft nudge** (NOT a hard block) that, on a multi-file or unfamiliar-code coding prompt with no
  plan, suggests plan mode once; **silent for one-sentence diffs** (Anthropic: skip planning for
  trivial changes). Directly attacks the code→re-code→switch-approach token thrash. Reuses the
  existing `flow-guard.sh` PreToolUse machinery + `persona-rules.default.json`; carries a
  kill-switch like the other guards. Tested like existing guards (fixture: nudge on multi-file,
  silence on one-liner) + a kill-switch test.
- **P6 — Security & untrusted-content isolation (added v4, HIGH — the top new finding).** We ingest
  untrusted text (transcripts, web, tool returns) → distill it → store it → re-inject it every turn:
  a persistent, delayed-trigger memory-poisoning substrate (AgentPoison/SpAIware/Gemini-delayed —
  <0.1% poisoning → >80% trigger). Hardening (chosen: full quarantine/dual-LLM):
  - **Quarantine/dual-LLM drainer:** split consolidation into a *quarantined summarizer* (no Bash /
    network / write; treats transcript content as DATA to summarize, never instructions) that emits
    structured, **provenance-tagged** candidate facts → a *privileged writer* (wiki-scope grant only)
    that consumes **only that structured output**, never the raw transcript. (CaMeL pattern; ~7-pt
    utility cost for a real boundary.)
  - **Least-privilege consolidation agents:** drop `node` / arbitrary-script / network Bash; write
    ONLY to staging; verify the wiki-scope guard is a hard *path-canonicalized* boundary (not string
    prefix; cover Windows `\\?\`, junctions, WebDAV `\\*`).
  - **Sever a trifecta leg:** no network egress during consolidation (sandbox/deny proxy — opt in).
  - **Injection-resistant injection:** strip zero-width / Unicode-Tags-block chars before store+inject
    (deterministic win vs ASCII-smuggling); wrap injected content as "untrusted reference — not
    instructions"; gate untrusted-*only*-derived new wiki pages behind confirm (extend `dream_accept`).
  - **Reclassify** the tool-return injection scanner as telemetry/defense-in-depth, NOT a trust
    boundary (detectors hit ≤100% evasion; 99% is a failing grade in appsec).
- **P7 — Graph justify-or-demote (added v4, evidence-gathering FIRST).** GraphRAG-Bench: graphs
  *frequently underperform plain RAG* below ~100K docs except genuine multi-hop. Instrument query
  overlap — do episodic search + wiki BM25/vector + graph each answer queries the others can't?
  **Keep bi-temporal `supersedes` regardless** (the one justified graph feature — fixes "LLMs can't
  suppress superseded facts"). Demote graph from *search ranking* to on-demand metadata +
  `knowledge_neighbors` blast-radius only if the data shows redundancy. No premature cut.
- **P8 — Evaluation & silent-failure detection (added v4).** The "how do we KNOW it works" gap.
  - **LongMemEval-shaped recall suite:** 20–50 hand-authored (fact, gold-answer, planted-session)
    triples; **decompose retrieval-vs-reading** (force-fed-memory ceiling vs real-retrieval actual);
    make **abstention** (never-stored → "I don't have that") and **knowledge-update** (overwrite →
    new wins, stale gone) first-class. Exact-match assertions over LLM-judge (judges pass ~63% of
    wrong-but-plausible answers).
  - **Retrieval guards (CI):** exact-match canary (known doc ranks #1) + BM25-only-vs-hybrid recall
    diff (hybrid must never lose an exact match BM25 finds) — closes the score-eviction bug class.
  - **Capture reconciliation + guard liveness:** declared-vs-observed capture counts + a
    produced-at-vs-captured-at silence-latency metric; prove each guard fires by injecting the
    violation it targets (a check that always passes is itself a silent failure).

## 7. Governance (the forcing function — P0 detail)

- **CONSTITUTION.md** — the §1 frozen mission, committed at repo root.
- **Surface-budget gate** (test): records a committed baseline of wiki page count
  (per category), skill/script/MCP-tool file counts; **fails when any count increases**
  beyond baseline (ratchet — accretion blocked now; the P4 diet lowers the baseline). Ships
  green immediately (baseline = current), so it does not red the build pre-diet.
- **Duplicate-logic guard**: generalize `brain-paths.test.ts`'s source-scan so no file
  re-introduces a copy-pasted dir-resolver / env-path-read antipattern.

## 8. Success criteria

- Constitution committed + CI surface-budget gate green (ratchet active).
- Auto-capture runs end-to-end with zero manual steps on the user's OAuth setup (evidence:
  a session's decisions land in PROJECT.md without `/capture`).
- Compaction/clear-safe: a long session that compacts loses no captured decisions
  (PreCompact + incremental marker union covers the full transcript).
- Every learned guardrail carries a transcript citation; contradicted rules auto-retire.
- A code-structure map + blast-radius query exist and are auto-regenerated on code change.
- Wiki page count down materially after P4; zero orphan pages added post-gate.
- Skill catalog reduced after P4 (fewer always-listed skills → lower per-session metadata cost).
- Volatile context (persona/wiki) injected cache-stably + JIT (P1: no per-turn cache-write churn; wiki body not injected every turn).
  - **P1c measured (2026-06-30):** the per-turn `UserPromptSubmit` injection from `persona-context.sh`
    is ~662 B / ~165 tokens (slug pointers `[[…]]` + behavioral principles only); no full wiki page
    body is injected (a body would be KB-scale). Bodies are fetched on demand via `knowledge_fetch`.
- Plan-first nudge fires on multi-file coding prompts and stays silent on one-line diffs (P5 fixtures). **Shipped P5 (2026-06-30):** `plan-first-nudge.sh` + `test-plan-first-nudge.sh`.
- Consolidation runs with no network egress and no raw-transcript access in the privileged writer (P6 quarantine boundary verified).
- Ingested content is zero-width/Unicode-Tags-stripped before store+inject; injection scanner is logged-but-not-trusted (P6).
- A LongMemEval-shaped recall suite (incl. abstention + knowledge-update) is green; capture reconciliation surfaces drift; guards proven live by violation-injection (P8).
- Graph tier decision is data-backed (P7 overlap instrumented); bi-temporal `supersedes` retained.

## 9. Non-goals (YAGNI)

- No autonomous always-on daemon / chat gateway (out of plugin scope).
- No migration to hermes-agent (relocates accretion; forfeits cross-platform fixes).
- No new retrieval tech for its own sake (no vector-DB swap); fix the stack we have.
- No heavy native deps without a cross-platform plan (tree-sitter parsers must be vetted
  like the vector-deps were — fallback to a pure-JS/regex symbol index if needed).

## 10. Open questions (from research, to resolve per-workstream)

- Optimal code-map regeneration trigger/frequency (every commit / N edits / drift-threshold).
- Per-turn LLM consolidation cost inside hooks — when must it defer to the timer?
- Dual capture (continuous Stop + PreCompact safety-net) dedup conflicts.
- Code↔requirement traceability edge generation (manual / LLM-inferred / commit-mined) +
  staleness detection.
- Knowledge-graph tier value vs simpler vector+markdown for a single-dev local context
  (unproven for this use case) — **now being resolved empirically in P7 (instrument overlap).**
- Reranker cross-platform footprint (ONNX cross-encoder) vs a pure-JS fallback (vet like vector-deps).
- Quarantine boundary granularity (P6): does the privileged writer ever need *any* free-text from the
  transcript, or is fully-structured candidate-fact handoff sufficient without quality loss?
- Reflection trigger/cadence (P4): importance-threshold (Generative Agents ~150) vs fixed per-dream.

## 11. Sources (verified, adversarially)

MemGPT (2310.08560); ProMem (2601.04463); ARC (2601.12030); Du survey (2603.07670v1);
mem0 (2504.19413); Microsoft human-inspired memory (2605.08538v1); memory ops survey
(2505.00675); Hermes Agent docs; Khoj; Cline Memory Bank; Cursor rules; Aider repo-map;
Codebase-Memory (2603.27277v1); coding-agent taxonomy (2604.03515); mex; Codex CLI memories.
**Stream C (mechanics, v3):** Anthropic docs — sub-agents, agent-teams, hooks, best-practices,
effective-context-engineering, prompt-caching, agent-skills (overview + best-practices); Anthropic
engineering — multi-agent-research-system, building-effective-agents; community — Simon Willison
(Claude Skills / sub-agents), alexop.dev.
**Stream D (agent-architecture deep, v4):** peer-reviewed/ablation anchors — Generative Agents
(2304.03442, reflection/importance), Lost-in-the-Middle (2307.03172), GraphRAG-Bench (2506.05690),
MAST (2503.13657), AgentPoison (2407.12784), PoisonedRAG (2402.07867), CaMeL (2503.18813), Design
Patterns for Securing LLM Agents (2506.08837), LongMemEval (2410.10813); + Anthropic contextual-
retrieval, Zep/Graphiti (2501.13956), Letta sleep-time, Willison lethal-trifecta, AGENTS.md/Linux
Foundation. Full brief: [[claude-agent-architecture-deep-2026-06]]. (Caveat: most quantitative
figures are 2026 preprints / order-of-magnitude — directional, not load-bearing; vendor memory
benchmarks (LoCoMo/DMR) are mutually disputed and treated as marketing; the mechanism-level
convergence across ≥3 independent sources, and the peer-reviewed ablations, are the robust part.)

## 12. Scope boundary

This spec is the contract. Each workstream (P0–P8) is decomposed into its own plan via the
writing-plans skill and built/reviewed under the existing release discipline (version-bump
lockstep + migration row + deep-review gate + green suite + the new surface-budget gate).
**Suggested ordering after P0:** P6 (security — active exposure) and P1 (autonomous capture incl.
JIT injection) first; then P8 (evals — so later changes are measurable); then P7 (graph instrument)
before P4's demote; P3 reranker is independent and high-ROI; P2/P5 as scheduled.
