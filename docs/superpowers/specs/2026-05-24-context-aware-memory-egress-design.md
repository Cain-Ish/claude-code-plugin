# Context-Aware Memory Egress (Persona Knowledge Layer) — Design

- **Status:** Draft for review
- **Date:** 2026-05-24
- **Author:** brainstormed with Claude (OpenHuman study → data-grounded rethink → external verification)
- **Scope:** Subsystem #1 of the OpenHuman-inspired program. Reborn from "Token Compression" after a data-driven rethink (see §2). Subsystem #2 (data hygiene) is the existing **maintainer**; subsystem #3 (dream-as-MCP-loop) is separate.

---

## 1. Summary

Make the second-brain persona enrich Claude's context with the **least weight** that still does the job: surface the *gist + a pointer* so Claude is **aware** knowledge exists, serve **tiered detail on demand**, and enforce a **hard ceiling** on any single retrieval so a query can never flood the window. Three moves — **POINT / SERVE / GUARD** — all running locally; serving is deterministic (no LLM on the hot path), summaries are precomputed by the existing extractor/maintainer.

**Guiding principle:** *gist by default, detail on demand, never flood — and the persona points, because Claude can't pull what it doesn't know exists.*

This is not a TokenJuice-style tool-output compressor (that idea was rejected — see §2 and §7). It is a knowledge-**egress** discipline coupled to the wiki's structure.

---

## 2. Background & the rethink (why this is not "Token Compression")

We set out to "steal" OpenHuman's Smart Token Compression. Grounding in **measured reality** killed the original framing:

| Measured | Finding |
|---|---|
| Wiki corpus | 118 pages / 2.2 MB; **median 4.2 KB (~1k tok)**; fat tail **50–80 KB** (`self-evolve` plan docs) |
| `episodic-index.json` | **8.4 MB**; 14 MB transcripts |
| `knowledge_search` | already returns `{path, score, first_lines}` — **snippet + pointer**, not full bodies |
| `episodic_search` | already returns 200-char snippets + `archivePath`/`lineStart/End` + a separate `episodic_read` — **already progressive disclosure** |
| Embeddings | **cached** per path+hash (`.embeddings-cache.json`) — not recomputed per query |
| `persona-context.sh` | re-injects persona **every turn** (deliberate); wiki hits are **slug-only**, 12-cap (deliberate) |
| `decisions/` | ~24 near-duplicate `evolve-*` pages (corpus pollution) |

**Conclusions that reshaped the design:**

1. Egress is *already* snippet+pointer — there is no fat payload to "compress." A TokenJuice port (shell-output line reducers) would solve a problem we don't have, in the wrong domain (prose, not `git`/`npm` spew). **Rejected.**
2. Context weight is **structural**, not post-hoc: it's decided by *how knowledge is represented and at what granularity it's handed over*. So this work fuses with the wiki structure ("Obsidian Memory").
3. The real, code-level weight is concentrated: **fat-tail page `Read`s** (occasional ~20k tok) and **recurring hot-tier injection** (USER.md + PROJECT.md once; persona block every turn).
4. **Current data is not source-of-truth** (legacy from v0.0.1). The **maintainer** reshapes/migrates/dedups data into whatever target we define — so corpus dedup and migration are *out of scope here* and we have full design freedom on structure.
5. The plugin **only runs inside Claude Code** — "Claude down" ⇒ "plugin down." So there is **no offline-survival requirement** for this pipeline; a **local LLM is optional** (cost/latency/privacy backend for summary generation), not a mandated failover.

What survived as the real goal: control the weight knowledge imposes on Claude. That goal is delivered by POINT / SERVE / GUARD.

---

## 3. Goals / Non-goals

**Goals**
- Surface relevant knowledge so Claude is *aware* of it, at minimal token cost (POINT).
- Serve detail in tiers with frictionless drill-down (SERVE).
- Guarantee no single knowledge/episodic response can flood context (GUARD).
- Keep all serving **local and deterministic** (no LLM on the hot path).
- Extend existing components (hooks, MCP tools, maintainer) — do not build a parallel system.

**Non-goals (explicitly out of scope)**
- Data cleanup / dedup / migration → **maintainer's job** (existing 6-phase agent).
- The always-on background consolidation loop → **subsystem #3** (dream-as-MCP-loop).
- A temporal knowledge-graph substrate (Zep/Graphiti/mem0g) → deliberately *not* adopted (see §7). We keep markdown + `related:` links (lightweight graph).
- Rewriting live **tool** output → impossible in Claude Code (PostToolUse can only append `additionalContext`, verified with claude-code-guide). Not attempted.

---

## 4. The model: POINT / SERVE / GUARD

| Move | Direction | What | Cost control | Runs |
|---|---|---|---|---|
| **POINT** | push (awareness) | persona injects *gist + pointer* (top-N) / *pointer-only* (rest) for context-relevant decisions/approach/memory/issues | relevance-gated; hard token cap; per-result token-count label | hooks (SessionStart, UserPromptSubmit, PreCompact re-seed) |
| **SERVE** | pull (detail) | tiered retrieval: T0 gist → T1 skeleton → T2 summary → T3 full | size-gated summaries; token-count labels | MCP tools (deterministic) |
| **GUARD** | ceiling | deterministic hard cap on any single knowledge/episodic response; "N more — drill down" | never-expand; aggregate token budget | MCP tools (deterministic) |

**Local/deterministic split:** SERVE+GUARD are pure-local, no LLM (cost & latency, not offline survival). Summaries (the only LLM step) are precomputed **cold** by the maintainer/extractor (local LLM optional).

---

## 5. Design detail

### A. Tiered page node

Each wiki page is retrievable at four granularities:

| Tier | Content | Stored | Cost |
|---|---|---|---|
| **T0 — gist** | one-line `description:` (curated, maintainer-enforced) | frontmatter (exists) | ~20 tok |
| **T1 — skeleton** | gist + `##` headings | computed on read (deterministic) | ~80 tok |
| **T2 — summary** | section-level précis, **only for large pages** | **in-body `## Summary` block** (decision D-3) | ~300 tok |
| **T3 — full** | page body | body (exists) | full |

- **Size-gated:** T2 is generated only when body exceeds a threshold (**D-4**, default ~1,500 tokens / ~6 KB). Small pages stay T0+T3 — no summary overhead. This mirrors OpenHuman's token-budget-gated sealing (not universal tiering).
- **Evidence-vs-interpretation:** the body (T3) is the source of truth; T2 is derived and carries a backlink to its source. Never summarize a summary.

### B. SERVE — tiered retrieval

- `knowledge_search` change: return the curated **`description` (T0 gist)** instead of `first_lines` (raw frontmatter chop), plus `path`, `score`, and a **token-count estimate** per candidate.
- **New MCP tool `knowledge_fetch(slug, tier)`** → returns `gist | skeleton | summary | full`. Claude uses this *instead of raw `Read`* for large pages, getting the summary first and drilling to full only when needed. Each response carries a token-count label and the source pointer.
- Drill-down must be **frictionless** (summaries are lossy — §8): the gist/summary always backlinks to T3.

### B+. GUARD — deterministic egress budget

- Every knowledge/episodic MCP response passes a deterministic budget guard: cap aggregate tokens (**D-5**, default ~2,000 tok/response, configurable), return highest-ranked tiers first, and append `"N more — drill down via knowledge_fetch(...)"`.
- Philosophy borrowed from TokenJuice's *guard rails* (caps, never-expand, "N omitted"), **not** its shell-output rules.
- This is the hard ceiling that prevents the fat-tail / multi-fetch / long-`episodic_read` flood cases. Validated by Chroma "Context Rot" and Zep's reranking-to-budget approach.

### C. Summary generation (extend the maintainer)

- The **maintainer Phase 4 (ENRICH)** gains: for pages over the size threshold, generate/refresh the `## Summary` (and section summaries) using the **existing extractor path** (`claude -p`/API; local LLM optional), keyed by content hash so it only regenerates on change.
- Runs **cold** (maintainer cadence + its 50-change cap + idempotency). No hot-path LLM.
- Maintainer Phase 0 already enforces hot-tier size caps and Phase 4 already curates `description` — T0 is already maintained; we add T2.

### D. POINT — proactive, relevance-gated, minimal, recency-placed

Reworks `persona-context.sh` injection:

- **Static identity** (immutable prefs/persona): keep re-injecting per turn (it's the only durable mechanism; verified — see §6/§8) but **hard-cap the block** (Letta-style, **D-6** default ~aggressively minimal) and inject the irreducible set only.
- **Dynamic pointing** (the persona's core value): surface *gist + pointer* for the **top ~3** context-relevant hits, *pointer-only* for the rest (up to the existing 12 cap), each with a token-count label. This is the discoverability mechanism — Claude can't pull what it doesn't know exists.
- **Relevance-gate hard** (Willison failure mode, §8): only POINT what scores above the existing floor; cheap enough to ignore.
- **Placement:** prefer **end-of-trace** for act-now guidance (Replit: +15% tool use vs system-prompt).
- **Post-compaction re-seed is mandatory** (`PreCompact` hook): re-seed persona + relevant pointers at the live end after compaction (Anthropic/Cognition: compaction drops durable instructions). Re-seed at the **live end**, not a static pin (Lost-in-the-Middle: favored position moves as the trace grows).

### E. Episodic scaling (deferred)

The 8.4 MB index is fully loaded + scanned per `episodic_search`. Future: persistent/sharded index. **Deferred** — perf, not context-weight, and not blocking. Noted so it isn't lost.

---

## 6. Decisions (resolved on evidence)

- **D-1 — Search granularity:** gist (curated `description`) for top-3 + pointer for the rest, each with a **token-count label**. *Evidence:* Anthropic context-engineering (hybrid: signal up front + explore on demand), Corpus2Skill (~one-line descriptions up front), basic-memory / Claude-Mem (pointer→gist→full). The prior slug-only choice rejected *truncated* descriptions (fragments); the curated frontmatter `description` is a proper gist — different thing.
- **D-2 — Persona persistence:** re-inject per turn (not inject-once, not static pin), **hard-capped minimal**, end-of-trace placement, **mandatory post-compaction re-seed at the live end**. *Evidence:* Letta/MemGPT re-renders core blocks every turn by design + 2k-char cap; Replit decision-time guidance (recency +15%, negative returns past 3–4 reminders); Lost-in-the-Middle (static pins decay).
- **D-3 — T2 storage = in-body `## Summary` block.** *Rationale:* Obsidian-native (just markdown), no new storage tech, human-readable/editable, nothing extra to integrity-check (good for the P0 threat model), maintainer can write/refresh it. *Alternatives considered:* frontmatter (can't hold multi-section), sibling `.summary.md` (file sprawl), SQLite sidecar (binary index to integrity-check; overkill for 118 curated pages — reconsider only for episodic). *Open to change in review.*
- **D-4 — Summary size threshold:** default body > ~1,500 tok (~6 KB). Tunable.
- **D-5 — GUARD aggregate cap:** default ~2,000 tok/response. Tunable.
- **D-6 — POINT static block cap:** aggressively minimal (target: irreducible identity only). Tunable; "minimal" enforced as a hard rule, not a guideline.

---

## 7. OpenHuman & field patterns — adopt / drop

**Adopt (genuinely applicable):**
- Size-gated hierarchical summarization (their bucket-seal, scaled to page level).
- Progressive disclosure: gist/summary + pointer + drill-down (their `drill_down`/`fetch_leaves`).
- Evidence-vs-interpretation (body is source; summary derived + backlinked).
- Per-result token-count labels (Claude-Mem "context as bank account").
- Hard-capped always-on block (Letta 2k-char discipline).

**Drop (wrong fit / cargo-cult):**
- TokenJuice shell-output regex reducers (wrong domain).
- Full chunk→L1→L2 *seal cascade* + content-addressed chunk DB (we lack firehose volume; 118 curated pages).
- Separate source/topic/global *trees* (our categories + entity pages already serve "topic"; a daily global digest is maybe-later).
- Temporal knowledge-graph substrate (Zep/mem0g) — heavier, QA-recall-tuned; revisit only if evolving-fact recall becomes primary.

**Patterns to name for reviewers:** parent-document retriever · auto-merging retrieval · RAPTOR (recursive/hierarchical summarization) · MemGPT tiered memory paging · decision-time / progressive-disclosure context engineering.

---

## 8. Risks & cautions (from external research)

1. **Proactive injection can pollute context** (Willison 2025-06-27, ChatGPT memory leaking into unrelated request). → POINT must be **relevance-gated** and cheap to ignore.
2. **Summaries lose critical detail** (Anthropic, Cognition). → drill-down frictionless; gist always backlinks; never let the gist be the *only* thing the model sees when the task needs detail.
3. **Over-injection backfires** (Replit: negative returns past 3–4 reminders). → "minimal" is a hard rule.
4. **Retrieval ≠ correctness** ("sufficient context" work). → make T3 reachable; don't trust the gist as the answer.
5. **Don't over-fit to exact token positions** (Chroma NIAH nuance). → "less total + high signal + favored end for act-now," not precise offsets.

---

## 9. Relationship to existing components

- `scripts/persona-context.sh` — POINT (UserPromptSubmit); add gist-top-3, token labels, hard-capped static block.
- `scripts/session-load.sh` — POINT at SessionStart.
- `scripts/pre-compact.sh` — POINT post-compaction re-seed.
- `mcp/src/tools/knowledge-search.ts` — return `description` + token-count (SERVE).
- `mcp/src/tools/knowledge-fetch.ts` — **new** tiered fetch (SERVE).
- New deterministic **GUARD** module in `mcp/` (imported by knowledge/episodic tools; node CLI for hooks).
- `agents/knowledge-maintainer.md` — Phase 4 ENRICH extension to generate/refresh `## Summary` (C).
- Tests: `mcp/test/` (TS units for fetch/guard/search) + `tests/` (hook integration).

---

## 10. Testing approach

- **GUARD:** deterministic unit tests — never-expand, cap enforcement, "N more" affordance, grapheme-safe truncation, pointer always present.
- **SERVE / `knowledge_fetch`:** tier correctness (gist/skeleton/summary/full), token-count accuracy, backlink presence.
- **Summary generation:** content-hash idempotency (no regen on unchanged), threshold gating, maintainer 50-change-cap compliance.
- **POINT:** static-block size cap, relevance gating, top-3-gist format, post-compaction re-seed fires.
- Existing `extraction-quality-gate.sh` / regression suite must stay green.

---

## 11. Rough phasing (for the implementation plan)

1. **GUARD module + token-count labels** — smallest, deterministic, high-leverage; testable in isolation.
2. **Tiered nodes + `knowledge_fetch` + `knowledge_search` `description` fix** (SERVE).
3. **Maintainer ENRICH extension** — `## Summary` generation (C).
4. **POINT rework** — gist-top-3, hard-capped static block, post-compaction re-seed (D).
5. **(Deferred)** Episodic index scaling (E).

---

## Open items for reviewer
- Confirm **D-3** (in-body `## Summary` vs sibling/sqlite).
- Confirm threshold/cap defaults (**D-4, D-5, D-6**) — or mark as runtime-tunable config.
- Confirm POINT keeps the existing 12-slug cap as the outer bound.
