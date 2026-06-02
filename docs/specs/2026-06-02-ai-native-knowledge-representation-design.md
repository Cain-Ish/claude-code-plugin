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

- **Frontmatter gains** `confidence:` (high/med/low) and `provenance:` (origin: session/source/version) — the weighting signals. (`created`/`updated` already give recency.)
- **Format:** simple `key: value` (multi-line values allowed via folded text). Token-cheap, BM25-friendly (keys + values are plain text), human-skimmable. Not JSON (keeps BM25/embeddings + Obsidian rendering intact).

## 5. Consumption (where the win lands)

- **session-load injection** prefers the `ai:begin` block over the prose body — token-cheap, no re-parse. The full prose stays one fetch away.
- **`knowledge_search`** BM25-weights the block (it's the high-signal, deduped statement of the page) and can return the block as the snippet.
- **The reading LLM** gets the shared intermediate first; it reads prose only when it needs nuance. This is the TriMem atomic-layer benefit.

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

## 13. Open questions

- Block format: flat `key: value` (this spec) vs a fenced ```yaml block vs extending frontmatter. (Leaning `key: value` marked-region for BM25-friendliness + multi-line + consistency with existing marked regions.)
- Should the block be embedding-indexed separately (its own vector) for sharper retrieval, or share the page's embedding?
- Confidence: LLM-assigned vs derived from corroboration count (how many sessions/sources assert the claim)?
