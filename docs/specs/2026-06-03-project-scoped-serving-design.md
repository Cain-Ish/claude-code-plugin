# SP-1 — Project-Scoped Serving (design)

**Status:** approved design (2026-06-03) — first sub-project of the plugin-consolidation vision.

**One-liner:** When working in project A, the persona/search serves A's knowledge + a shared layer first, and only broadens to other projects when the scoped result is thin — so Claude stops getting cross-project noise, without losing relevant knowledge while project facets are still sparse.

## 1. Problem

`knowledge_search` searches the **entire** wiki regardless of which project the session is in (it loads all category dirs and merely *augments* candidates with the active project's registry pages — `knowledge-search.ts:94`). The per-prompt persona injection (`persona-context.sh` → `knowledge-search-cli`) and `/second-brain:query` ride on that same global search. Result: in project A, Claude is fed pages from projects B, C, … — noise that dilutes the signal and wastes the context budget.

A `project:` frontmatter facet exists (since 0.23.0: a page is "in" project X, or shared if it has no facet) but is **sparsely populated** (the maintainer backfills it incrementally — that is SP-2–SP-4). So a naive hard filter on the facet would hide most pages today.

## 2. Goals / non-goals

**Goals**
- In project A, `knowledge_search` returns A-relevant + shared knowledge first, demoting/excluding other projects.
- Degrade gracefully *now* (sparse facets) and tighten *automatically* as facets fill.
- One chokepoint (`knowledge_search`) so the persona injection and `query` skill inherit scoping for free.
- Fully back-compatible: a caller that passes no project context (`brainDir`/`projectSlug`) gets byte-for-byte today's behaviour.
- Cross-platform (pure TS logic; no new path/process concerns).

**Non-goals (SP-1)**
- Scoping `episodic_search`/`/recall` (transcripts already carry a project slug; revisit in a later SP).
- Populating `project:` facets (SP-2 raw-inbox + SP-4 maintainer own that).
- Changing `session-load` (already project-aware via the active PROJECT.md + graph neighbourhood).

## 3. Membership model — "in-scope for project A"

Each scored candidate is classified into a **tier** (higher = closer to A). The signals are what we have *today*; the model needs no new data and self-tightens as facets populate.

| Tier | Definition | Rationale |
|---|---|---|
| **T1 — project** | `doc.project === activeSlug` | definitively A (the facet) |
| **T2 — neighbourhood** | within `K` graph hops (default `K=2`) of any T1 page **or** the active `PROJECT.md`'s `[[cross-references]]` | catches A-relevant pages that aren't facet-tagged yet (the bridge while facets are sparse) |
| **T3 — shared** | `doc.project === ''` (no facet) and not in any other project's neighbourhood | genuinely cross-cutting knowledge (general learnings, security doctrine, …) |
| **OUT — other-project** | `doc.project === someOtherSlug` (≠ A) and not in A's neighbourhood | the noise we suppress; only appears on auto-broaden |

`activeSlug` is resolved exactly as the MCP server already does (`resolveActiveSlug()` → pin or `slugFromProjectDir(activeProjectDir())`), so SP-1 introduces no new project-resolution logic.

**Neighbourhood (T2)** is computed from the existing typed graph (`graph-store`): seed = T1 slugs ∪ PROJECT.md cross-reference slugs; expand `K` hops over current (`valid_to == null`) edges. This reuses the graph the search already loads for its relevance boost — no extra I/O beyond reading the edge log once.

## 4. Scoping algorithm (scoped-first, auto-broaden)

After the existing BM25 + graph + access + recency scoring produces a scored candidate list:

1. Classify each candidate into T1/T2/T3/OUT.
2. `inScope = T1 ∪ T2 ∪ T3`; sort by `(tier, score desc)` — T1 first, then T2, then T3, each by score.
3. Let `strong = inScope filtered to score >= floor` (the same score floor the consumer already uses, default surfaced via the existing per-call cut).
4. **If `strong.length >= SB_SCOPE_MIN_HITS`** (default **3**): return `inScope` top-N. Done — no other-project pages.
5. **Else (thin scoped result → auto-broaden):** append `OUT` (sorted by score) *after* the in-scope set and return the combined top-N. The scoped pages still rank first; the broadened ones fill the tail.

This means: when A has enough of its own/shared knowledge, B/C never appear. When A is new/empty (or facets sparse and nothing matched), the user still gets globally-relevant results rather than nothing.

**Tie to the facet rollout:** today most pages are T3 (no facet) → `inScope` is broad → little is excluded except clearly other-project (T-OUT) pages. As SP-4's maintainer tags pages `project:X`, T3 shrinks and OUT grows → scoping tightens automatically, no code change.

## 5. Configuration

- `SB_PROJECT_SCOPE=off` — disable scoping entirely; `knowledge_search` behaves exactly as 0.24.7 (global). Default `on`.
- `SB_SCOPE_MIN_HITS` (default `3`) — the auto-broaden threshold (noise-vs-recall lever).
- `SB_SCOPE_HOPS` (default `2`) — neighbourhood radius `K`.
- `scope: "all"` — an explicit per-call override (already a string param on `knowledge_search`; today it names a category. Reserve the literal `"all"` to mean "search every project, no scoping" — distinct from a category name, which no category will ever be). A caller wanting a category keeps passing the category name; that path is orthogonal to project scoping and both can compose (category filter THEN project tiering).

## 6. Components (files touched)

- `mcp/src/tools/knowledge-search.ts` — add the classification + scoped-first ordering after scoring; gated on `projectSlug` present AND `SB_PROJECT_SCOPE !== 'off'` AND `scope !== 'all'`. New small pure helpers: `classifyTier(doc, ctx)` and `projectNeighbourhood(seeds, edges, hops)`.
- `mcp/src/tools/knowledge-search.ts` (same file) — `KnowledgeSearchArgs` already carries `projectSlug`/`brainDir`; no signature change. The result item already exposes `project`; add an internal (non-breaking) `tier`/`scoped` marker used only for ordering (not necessarily returned).
- `mcp/src/server.ts` — already passes `projectSlug: resolveActiveSlug()` + `brainDir` to `knowledge_search` (done). No change beyond reading the env flags (read inside the tool).
- `mcp/src/tools/knowledge-search-cli.ts` — **required wiring** (confirmed: today it calls `knowledgeSearch({ query, knowledgeDir })` with NO project context, so the per-prompt persona injection is currently global). Make the CLI resolve `brainDir` (`process.env.BRAIN_DIR` → `~/.second-brain`) and `projectSlug` (`process.env.SB_ACTIVE_SLUG` — the calling hook already resolves the active slug via `sb_resolve_slug`; it passes it through), and forward both to `knowledgeSearch`. Without this, scoping would apply to the MCP tool but not the hook injection — the main noise surface.
- `scripts/persona-context.sh` (+ `scripts/session-load.sh` if it calls the CLI) — export `SB_ACTIVE_SLUG="$slug"` (already computed in the hook) before invoking the search CLI. One-line addition each; the slug is already in scope.
- The `query` skill calls `knowledge_search` (the MCP tool, already wired) → inherits scoping with no change.
- `kb-schema.json` — **not** touched (scoping is behaviour, not structure). Project-resolution stays in the existing `project-dir.ts`/`lib.sh` (already a shared source).

## 7. Error handling / back-compat

- No `projectSlug` (or no `brainDir`) → scoping is skipped → identical to 0.24.7. This is the back-compat guarantee and the safety valve (an unknown/odd environment falls back to global, never to empty).
- Missing/unreadable graph → T2 is empty (neighbourhood = just the seeds); scoping still works on T1/T3/OUT. Fail-soft.
- Empty wiki / no candidates → returns empty as today.
- The classification is pure and total (every doc lands in exactly one tier), so there is no "unclassified" gap.

## 8. Testing (TDD)

Unit tests in `knowledge-search.test.ts` over a temp wiki:
1. **scoped result** — pages `a1,a2` (`project:A`), `b1` (`project:B`), `s1` (no facet); query matches all → A-query returns `a*` + `s1`, `b1` absent (in-scope strong ≥ MIN_HITS).
2. **auto-broaden** — only `b1` matches the query (no A/shared hits) → `b1` IS returned (broadened, not hidden).
3. **neighbourhood (T2)** — untagged `n1` linked by a graph edge to `a1`; A-query surfaces `n1` above an unrelated `project:C` page.
4. **override + kill switch** — `scope:"all"` returns global ranking; `SB_PROJECT_SCOPE=off` returns 0.24.7 ordering.
5. **back-compat** — call with no `projectSlug` → identical candidate set/order to pre-SP-1 (guard against accidental behaviour change).
6. **threshold** — `SB_SCOPE_MIN_HITS` controls when broadening kicks in (set to 1 vs 5, observe).

The existing `knowledge-search.test.ts` graph-boost + back-compat cases must stay green unchanged.

## 9. Cross-platform

Pure TypeScript in the MCP server (no child processes, no path passing to bash). Env flags read via `process.env`. No Windows/macOS-specific concerns. The one bash touchpoint (wiring `projectSlug` through the search CLI if needed) uses the existing `lib.sh sb_resolve_slug` — already cross-platform.

## 10. How later SPs build on this

- **SP-2 (raw inbox) / SP-4 (maintainer)** populate `project:` facets → T3 shrinks, OUT grows → scoping tightens automatically (this spec needs no change).
- **SP-3 (setup deep-scan)** seeds a new project's pages already facet-tagged → a fresh project is scoped correctly from day one.
- A later SP can extend the same tier model to `episodic_search`/recall.
