# AI-Native Knowledge Representation — Design

- **Status:** Draft (brainstormed 2026-06-02; web-researched; direction approved — "structured block + prose"; pending spec review). A **future track**, orthogonal to the just-shipped hierarchy (0.23.x) — the hierarchy is *where* a page lives; this is *how a page is written for an AI reader*.
- **Target release:** plugin 0.24.0 candidate (additive, flag-gated, back-compat).
- **Lineage:** extends `kb-main-groups-heterogeneous` (groups may differ — now: their *block schemas* differ) and the KB-org spec `2026-06-02-knowledge-base-hierarchical-organization-design`.

---

## 1. Problem / reframe

The KB (wiki pages, learnings, decisions, …) is **AI-to-AI**: written by AI (extractor, dream, maintainer) and read by AI (session-load injection, `knowledge_search` results fed to Claude). The human almost never reads it directly. Yet it is shaped as **human-PKM prose markdown**.

The cost: **prose forces every AI reader to re-derive structure** — extract the claim, the trigger, the action, the evidence, the relations — on *every* read, with "no shared intermediate" ([Knows: Agent-Native Structured Representations](https://arxiv.org/html/2604.17309v1)). That is repeated tokens + reasoning each retrieval, and it's lossy (different readers extract differently).

## 2. Research basis (don't overcorrect)

- **Keep markdown.** It is the validated AI substrate — Karpathy's LLM-wiki pattern (raw → LLM-generated wiki → schema), which second-brain already mirrors, and the [llms.txt](https://buildwithfern.com/post/how-to-write-llm-friendly-documentation) movement (heading hierarchy > HTML; far fewer tokens). Don't go full-JSON.
- **Multi-granularity, not atomic-only.** SOTA agent memory ([TriMem](https://www.emergentmind.com/topics/memory-mechanisms-in-llm-based-agents)) keeps three coexisting layers — raw segments (fidelity) + atomic facts (retrieval) + synthesized profiles (reasoning). ["Beyond Atomic Facts"](https://arxiv.org/abs/2605.19952) warns atomic-only loses context.
- **Provenance + confidence + typed records are first-class** for AI weighting and against memory-poisoning ([mem0 2026](https://mem0.ai/blog/state-of-ai-agent-memory-2026), [typed-memory provenance](https://arxiv.org/html/2605.25869)).

**What we already have:** the *synthesized profile* (prose pages) + the *relations* (bi-temporal edge graph) + *raw* (episodic transcripts). **What's missing:** the **atomic, schema'd shared-intermediate** layer + first-class provenance/confidence/applicability on pages.

## 3. Goals / Non-goals

**Goals**
- Add a per-page **machine-first structured block** (the shared intermediate) an AI reads *directly* without re-parsing prose.
- Make **provenance, confidence, scope/applicability** first-class so retrieval can *weight* what it surfaces.
- Keep the markdown substrate, the prose (nuance), and everything that works on it (BM25, embeddings, Obsidian, the projection/validation machinery).
- Multi-granularity: raw (episodic) + **atomic (new block)** + synthesized (prose) + relations (edges) coexist.

**Non-goals**
- No full-JSON rewrite / dropping prose (overshoots; "Beyond Atomic Facts").
- No new store for the block (it lives IN the page — not a sidecar to sync).
- No change to the hierarchy/MOC layer (orthogonal).

## 4. The AI block

A **marked body region** per page — consistent with the codebase's existing generated/marked regions (`graph:begin`, `theme:begin`, `moc:begin`), so the same author-only-the-region + validate machinery applies:

```
<!-- ai:begin (schema'd, machine-first — the shared intermediate) -->
claim:   <one-line canonical proposition>
trigger: <when this applies>
action:  <what to do>
scope:   <where it holds / boundary>
evidence: <provenance: versions, sessions, sources>
supersedes: <slug | ->
<!-- ai:end -->
```

- **Authored, not projected.** Unlike `related:`/`## Dependencies` (projected from edges), the block is *authored* by whatever writes the page (the prose is its source). It is written ONCE by the producing AI and read MANY times by consuming AIs without re-derivation.
- **Per-type schema** (the missing formalization of the maintainer's existing ENRICH category guidance):

| type | block fields |
|---|---|
| `learnings` | claim, trigger, action, scope, evidence, supersedes |
| `decisions` | context, choice, alternatives, rationale, status, supersedes |
| `entities` | identity, current_state, depends_on, owns, status |
| `issues` | symptom, cause, fix, severity, status |
| `concepts` | problem, solution, where_applied, tradeoffs |
| `security` | threat, mitigation, scope, status |

- **Frontmatter gains** `confidence:` and `provenance:` — the weighting signals. **Confidence is HYBRID (RESOLVED — SOTA):** the producing AI's **verbalized** confidence (high/med/low) is the *primary* signal — a March 2026 study found verbalized confidence is the best-*calibrated* (ECE 0.166 vs 0.229 for self-consistency, at 1/5th the cost) — **corroborated** by an evidence/recurrence count (how many sessions/sources assert the claim, tracked in `evidence:`) and recency (`created`/`updated`). Not pure-corroboration (2026 research shows it's worse-calibrated alone). Refs: [LLM grader calibration](https://arxiv.org/abs/2603.29559), [verbal+consistency hybrid](https://openreview.net/forum?id=66D3rZrNjV).
- **Field values are PLAIN SLUGS, never `[[wikilinks]]`** (e.g. `supersedes: other-slug`, not `supersedes: [[other-slug]]`). Constraint from the state-check: the FORGET connectivity signal and `parseDoc`'s body-`[[link]]` → `related:` fallback both scrape `[[..]]`; a bracketed value in the block would silently pollute connectivity + the projected `related:`. Relations belong in the edge graph, not the block.
- **Format (RESOLVED — SOTA):** **flat YAML `key: value`** (multi-line via folded `>`), inside the marked region. YAML is the model-preferred structured format (GPT-5/Gemini benchmarks) and ~16% more token-efficient than JSON with better nested-data comprehension; it stays plain-text so BM25/embeddings/Obsidian keep working, and **flat** YAML is parseable by a tiny line parser with **no new dependency** (offline-first). NOT JSON (token cost + comprehension hit + embedding noise). Refs: [nested-format benchmark](https://www.improvingagents.com/blog/best-nested-data-format/), [token efficiency](https://shshell.com/blog/token-efficiency-module-13-lesson-2-format-comparison).

## 5. Consumption (where the win lands)

- **The block is a first-class, proposition-level retrieval unit (RESOLVED — SOTA Q2).** "Dense X Retrieval"/factoid-wiki shows atomic propositions as retrieval units significantly outperform passage/sentence retrieval (sharper precision, fewer tokens, better downstream QA); AGRaME confirms proposition-granularity ranking. So:
  - **Phase 1 (offline-first):** `knowledge_search` BM25-weights the block (high-signal, deduped) — `parseDoc` extracts it as `aiBlock`, scored above body, returned as the snippet. Works with no embeddings (the Pi default).
  - **Phase 2 (embeddings present):** the block gets its **own embedding/vector** (proposition-level index), not folded into the page's body vector. Refs: [Dense X Retrieval](https://arxiv.org/html/2312.06648v2), [AGRaME](https://arxiv.org/pdf/2405.15028).
- **session-load injection** prefers the `ai:begin` block over the prose body — token-cheap, no re-parse. The full prose stays one fetch away.
- **The reading LLM** gets the shared intermediate first; it reads prose only when it needs nuance. This is the TriMem atomic-layer benefit.

## 5b. Integration constraints (from the 2026-06-02 state-check — do not assume)

A parallel read of the live subsystems surfaced these hard constraints; the implementation MUST honor them:

- **Exclude the block from length/byte counts.** `wiki-forget-score.sh` (`wc -c` whole-file + `body<200` stub-floor) and `knowledge-search.ts` (stub penalty, `body<100`) must measure **prose only** — strip `<!-- ai:begin … ai:end -->` (and the other marked regions) before counting, or a uniform block shifts FORGET scores and escapes stub penalties. `tests/test-wiki-forget-score.sh` fixtures assume tiny stubs — update or the test breaks.
- **`firstSentence` (knowledge-reindex.ts) must strip `ai:begin`** exactly as it already strips `graph:begin`, so the block never leaks into `index.md`/MOC descriptions.
- **`parseDoc` gains `aiBlock`** (parsed from the marked region); a flat-YAML line parser (no new dep). BM25 weights it; the body-`[[link]]`→`related:` fallback must run on prose with the block stripped.
- **`graph-project` is safe** (it rewrites only its own `graph:begin` region + `related:` frontmatter, both distinct from `ai:begin`) — but a regression test must prove a reindex never clobbers the block.
- **Authoring respects the automation boundary.** The **extractor** (Stop/PreCompact — already automatic) authors the block at capture (extend `extract-prompt.txt` to emit `ai_block` per type + `merge-project-update.sh` to inject the region). The **dream/maintainer** *refresh* it — and they are **explicit-invocation-only** (banners, never auto-dispatch). Do NOT add auto-dispatch (it would revert the 0.21.0 hardening).
- **`knowledge_fetch`** gains a block-aware path (a `block` tier, or block-first in `summary`) so a consumer can read the shared intermediate without the prose.

## 6. Authoring & maintenance

- **Extractor** (capture-time): when it writes/updates a page for a known type, author the `ai:begin` block from the session (the same extraction it already does, but emitted as the schema'd block, not only prose).
- **dream / knowledge-maintainer** (consolidation): author/refresh blocks; the maintainer's existing per-category ENRICH guidance *becomes* the block schema (one source of truth for "what a good X page contains").
- **Closed schema:** the block's fields per type are fixed (a deterministic post-filter drops unknown fields), so the structure can't drift — same closed-vocabulary discipline as project facets.

## 7. Validation

- `knowledge_validate` schema-checks each `ai:begin` block: required fields present for the page's type; warns on missing block or missing required field (gentle — additive, not a hard fail while migrating).
- `/second-brain:lint` surfaces pages whose block is **stale vs the prose** (heuristic: block older than body's `updated`) so drift is caught.

## 8. Multi-granularity model (the whole memory, after this)

| layer | store | role | reader |
|---|---|---|---|
| **raw** | `~/.second-brain/transcripts/` | fidelity | `episodic_search` / dream mining |
| **atomic** (new) | `ai:begin` block in each page | retrieval / injection | session-load, `knowledge_search`, the LLM |
| **synthesized** | prose body | nuance / reasoning | the LLM on demand |
| **relations** | `graph/edges.jsonl` | structure / blast-radius | `knowledge_neighbors`, projection |

## 9. Heterogeneous groups (honored)

Each main group's block schema differs (§4 table) — a `learnings` block is `trigger/action`, a `decisions` block is `choice/alternatives`. The uniform contract is "every page has an `ai:begin` block validated against *its type's* schema"; the shape inside differs by group, exactly the `kb-main-groups-heterogeneous` principle.

## 10. Migration

- **Additive + back-compat:** a page with no `ai:begin` block still works (session-load/search fall back to prose); the block accrues as pages are written/consolidated. Flag `SB_AI_BLOCK` (default on for new writes).
- **Backfill:** the dream/maintainer author blocks for existing pages over their normal passes (no big-bang); optionally a one-shot LLM backfill pass for the ~118 current pages.
- **Reversible:** delete the marked regions; pages revert to pure prose.

## 11. Trade-offs / risks

- **Authoring cost** — the producing AI does extra work per write. Mitigation: it's the *same* extraction it already does; the block just captures it once instead of every reader re-doing it. Net token win across reads.
- **Block↔prose drift** — the block could go stale vs the prose. Mitigation: lint staleness check (§7); the dream refreshes both together.
- **Schema rigidity** — a fixed per-type schema may not fit every page. Mitigation: all fields optional-but-recommended; an `notes:` free field for the rest; schema evolves per group.
- **Over-structuring** — risk of losing the nuance prose carries. Mitigation: prose stays; the block is the *index*, not the replacement ("Beyond Atomic Facts").

## 12. Phasing (own plan when pursued)

- **P1 — block + schema + validate:** define per-type schemas; `ai:begin` parse + schema-validate in `knowledge-validate`; `parseDoc` exposes the block. Author blocks in the extractor for new writes.
- **P2 — consumption:** session-load injects the block; `knowledge_search` weights/returns it.
- **P3 — maintenance + backfill:** dream/maintainer author+refresh blocks; lint staleness; one-shot backfill of existing pages.

## 13. Resolved decisions (web-researched 2026-06-02 — SOTA over quick-win)

1. **Block format → flat YAML `key: value`** in the `ai:begin` marked region (NOT JSON, NOT extended frontmatter). YAML is the model-preferred, token-efficient, plain-text (BM25/embedding-friendly) structured format; flat keeps it parseable by a tiny line parser with no new dependency (offline-first). [§4]
2. **Embedding → proposition-level.** The block is its own retrieval unit: Phase 1 BM25-weights it (offline); Phase 2 gives it its own vector (proposition indexing beats passage/sentence). [§5]
3. **Confidence → hybrid**, LLM-verbalized primary (best-calibrated per 2026 study) + evidence/recurrence corroboration + recency. [§4]

(Remaining genuinely-open, to settle in the plan: the exact `aiBlock` BM25 weight (lean 1.5, between body 1.0 and tags 2.0); whether `knowledge_fetch` adds a `block` tier vs folds into `summary`.)
