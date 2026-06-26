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
   guardrails *while coding*, + an optional cost-router (Opus plans, Sonnet implements,
   Haiku mechanical).

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
- **Usage-ranked forgetting** (Codex CLI): rank by usage_count + recency; prune entries
  unrecalled beyond a window (~30 days). The freshness/bloat control.
- **Six atomic operations** every contextual memory needs: Consolidate, Update, Index,
  Forget, Retrieve, Condense.

## 4. Autonomy resolution (constraint vs safe-erase)

Tension: full autonomy (no human gate) vs dream's human-review-before-erase. Resolved
**with research mechanisms, not by dropping safety**:
- **Safe forgetting** = usage-ranked pruning (only prune the demonstrably-unused), append-only
  history so nothing is hard-deleted.
- **Safe guardrails** = reflection grounding (a rule can't fire unless it cites evidence; a
  contradicted rule is auto-retired).
- **Safe auto-consolidation** = stage → **auto-accept** → keep a rollback/undo trail (reversible),
  replacing the manual `dream_accept` gate.

## 5. Keep / Fix / Cut ledger

| Capability | Fate |
|---|---|
| dream (background consolidation, FORGET) | **KEEP + PROMOTE** → the §3 doubt-loop + usage-ranked forgetting; auto-accept+rollback (§4) |
| persona L1 context / L2 brief / L3 guard / L4 quality-gate / L5 MCP | **KEEP + PROMOTE** (L3=guardrail engine, L4=salience write-path filter) |
| extraction (Stop/PreCompact + marker) | **KEEP + FIX** → run autonomously; per-turn; salience-default; grounded |
| hot tier + episodic recall + on-demand search | **KEEP** |
| **Code-structure map (layer 4)** | **ADD** (the orientation gap; use tree-sitter+PageRank, don't reinvent) |
| **Code↔knowledge relations (layer 5)** | **ADD** (typed code edges + traceability; MCP blast-radius query) |
| access-count search boost | **CUT** (~10,000× corruption) |
| typed node↔node graph | **DEMOTE** for search ranking; keep as read-time metadata; fold into layer 5 |
| 8 wiki categories | **COLLAPSE** → minimal set aligned to the 6 layers |
| 44K-token upgrade skill, dup vendored skills, dead scripts | **CUT** |

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
- **P2 — Grounded learning → active guardrail (HIGH/MED).** Learned practices resolve to a
  PROJECT decision **or** a persona-rules.json guardrail that fires at PreToolUse — each
  carrying a citation to its transcript evidence; auto-retire contradicted rules.
- **P3 — Orientation layer (HIGH user-value).** Auto-generated, token-capped, PageRank-ranked
  code-structure map (layer 4) + typed code↔knowledge relations (layer 5), exposed via MCP
  for blast-radius, regenerated out-of-band on code change (drift detection). Prefer a
  proven generator (Aider-style tree-sitter+PageRank) over hand-rolling.
- **P4 — Diet + autonomous doubt loop.** Collapse categories to the 6-layer-aligned minimal
  set; cut access-boost; demote graph; fix dream `auto_maintain` (bwrap/RestrictNamespaces);
  FORGET as centerpiece with usage-ranked pruning + auto-accept+rollback.

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
  (unproven for this use case).

## 11. Sources (verified, adversarially)

MemGPT (2310.08560); ProMem (2601.04463); ARC (2601.12030); Du survey (2603.07670v1);
mem0 (2504.19413); Microsoft human-inspired memory (2605.08538v1); memory ops survey
(2505.00675); Hermes Agent docs; Khoj; Cline Memory Bank; Cursor rules; Aider repo-map;
Codebase-Memory (2603.27277v1); coding-agent taxonomy (2604.03515); mex; Codex CLI memories.
(Caveat: most quantitative figures are 2026 preprints — directional, not load-bearing; the
mechanism-level convergence across ≥3 independent sources is the robust part.)

## 12. Scope boundary

This spec is the contract. Each workstream (P0–P4) is decomposed into its own plan via the
writing-plans skill and built/reviewed under the existing release discipline (version-bump
lockstep + migration row + deep-review gate + green suite + the new surface-budget gate).
