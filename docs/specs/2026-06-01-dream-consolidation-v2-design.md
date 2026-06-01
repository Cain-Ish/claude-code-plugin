# Design: consolidation v2 — community-summary pages (dream) + retrieval-grounded reconciliation (maintainer)

**Date:** 2026-06-01
**Status:** Implemented in 0.22.2 (PR #7, branch `feat/graphiti-adoption-specs`) — brainstorm output (Graphiti eval `wf_ac6b4c11-117`), **revised after adversarial review** (`wf_51f2dbeb-ae1`)
**Author:** second-brain session
**Target release:** plugin 0.22.2 / knowledge-base MCP 2.3.1

> **Revision note (post-review):** the original draft put **both** features in the dream. That violates the shipped contract — `agents/dream-runner.md` Phase 3: the dream runs on a **staging copy of `wiki/` only**, does **not** curate edges, and `graph/edges.jsonl` is **not** snapshotted. So edge-mutating work (B2's supersede/invalidate) **cannot** live in the dream. This revision splits by execution context:
> - **B1 (community-summary pages)** → **dream** (theme pages are staging-safe wiki pages; clustering reads only staging `related:` links; invoked via a `scripts/*.sh` shim because the dream-runner cannot run `node`).
> - **B2 (retrieval-grounded reconciliation, incl. supersede/invalidate edges)** → **`knowledge-maintainer`** Phase 2+3, the **live** path that already curates pages and edges via `knowledge_relate`.
> Also fixed: a concrete deterministic SUPERSEDE mechanism, a fully-specified deterministic label-propagation update model, `themes` forget-protection wired to the real scorer, `related:` (not a novel `members:`) for member links, and a content-aware `member_hash`.

## Summary

Two upgrades to the consolidation layer, each placed in the context allowed to perform it, both **file-based, no graph DB, LLM-only-at-consolidation-time**.

- **B2 — retrieval-grounded reconciliation (upgrades `knowledge-maintainer` Phase 2 DEDUPLICATE + Phase 3 RELATE, LIVE).** Today the maintainer dedups by eyeballing overlapping titles; the extractor proposes create-or-update with *no similarity lookup*, so synonymous pages fragment (`auth-bug` vs `auth-error`). B2 makes the decision retrieval-grounded à la **Mem0's two-phase add**: for each candidate, call `knowledge_search` (top-k nearest, which already fuses BM25 + ONNX cosine and degrades to BM25 when embeddings are down), then the maintainer emits a structured op — **ADD / UPDATE(merge into `<slug>`) / NOOP / SUPERSEDE(`<slug>`)**. SUPERSEDE writes the new page **and** performs a *deterministic, explicitly-enumerated* set of `knowledge_relate` edge writes (§B2.2). It runs on the **live** wiki, where both page and edge writes are sanctioned.

- **B1 — whole-corpus community-summary pages (new dream phase, STAGING).** Our biggest gap is **zero corpus-level sensemaking**: `index.md` is a flat per-category list; `knowledge_neighbors` walks point-to-point edges but cannot *name a region*. B1 adopts **GraphRAG's community reports as an offline artifact** — cluster the **staging** wiki's link graph with **label propagation** (the algorithm Graphiti chose over Leiden for cheap incremental updates), then LLM-write one "theme" page per cluster, refreshing only clusters whose membership **or member content** changed. Theme pages are ordinary staging markdown → reviewed at `dream_accept`, then indexed into BM25 + the embedding cache like any page. This is the concrete realization of the "Memory Tree hierarchical summarization" flagged in `openhuman-evaluation-2026-05-24`.

## Why now / problem statement

- **No sensemaking layer.** `session-load.sh` surfaces nearest slugs; nothing answers "what clusters of work exist?". The relational graph gives edges, not regions.
- **Fragmentation.** `merge-edges.sh` endpoint-guards but does not dedup *nodes*; the maintainer's dedup is title-overlap eyeballing with no retrieval — the duplicate-slug failure mode `knowledge_validate` cleans up after.
- Both are **write/consolidation** problems — where the research confirms graph-memory value (and cost) lives. Neither touches the hot/offline write path.

## Goals

- **B1**: deterministic in-memory clustering (no DB; reproducible/testable — see §B1.1 update model) + LLM-written, regenerable, **staging** theme pages reviewed at `dream_accept`; cost bounded to changed clusters; invokable by the dream-runner under its real tool allowlist.
- **B2**: retrieval-grounded dedup/merge/supersede on the **live** path via `knowledge_search` + `knowledge_relate`; SUPERSEDE edge invalidation is an explicit, deterministic, per-edge loop (no cascade); every change bounded by the maintainer's 50-change cap and visible in git.
- **Strict back-compat**: `SB_DREAM_SUMMARIZE=off` ⇒ the dream is byte-for-byte the current cycle; `SB_RECONCILE=off` ⇒ the maintainer dedup/relate is byte-for-byte current.

## Non-goals (YAGNI)

- **No graph database, no Leiden, no query-time map-reduce.** We take GraphRAG's *artifact* (offline cluster summaries as files), not its engine. Label propagation runs in-memory over a few-thousand-node graph in milliseconds.
- **No edge writes in the dream.** B1 clustering **reads** staging `related:` links; it never writes `graph/edges.jsonl`. All edge curation is B2/maintainer (live) or `knowledge_relate`.
- **No embeddings on edges, no new vector store, no new npm dependency.** B1 clustering is plain TS (verified: `mcp/package.json` deps are only `@huggingface/transformers`, `@modelcontextprotocol/sdk`, `glob`, `zod`); B2 reuses `knowledge_search`.
- **No always-on / hot-path LLM.** Both phases are consolidation-time only.
- **No auto-apply for B1.** Theme pages stage into the dream diff, apply on `dream_accept`. (B2 runs in the maintainer, which writes live — same trust model as the maintainer's *existing* dedup/relate; bounded + git-visible.)
- **No A-MEM-style mutation of arbitrary neighbor notes.**

## Background — what exists today (must keep working)

| Component | File | Current behaviour |
|---|---|---|
| Dream | `skills/dream/SKILL.md` + `agents/dream-runner.md` | Staging-only consolidation; **two phase vocabularies**: SKILL.md `2a..2f` (AUDIT/DEDUPLICATE/RELATE/ENRICH/REINDEX/FORGET); dream-runner.md `Phase 1..6` (same order). Applies on `dream_accept`. **Does not curate edges.** |
| **Maintainer** | `agents/knowledge-maintainer.md` | **LIVE** 6-phase cycle; **Phase 2 DEDUPLICATE** merges live pages; **Phase 3 RELATE** curates edges via `knowledge_relate` (assert/invalidate/supersede) + `knowledge_reindex`. 50-change cap. |
| Hybrid search | `mcp/src/tools/knowledge-search.ts` | BM25 + ONNX cosine fused via RRF (`RRF_K=60`); the embedding block is a try/catch that **falls back to BM25 only** when `embedTexts→null`. Parses `related:` from frontmatter; **falls back to harvesting ALL body `[[links]]` only when `related:` is empty** (lines 335-340). |
| Embeddings | `mcp/src/tools/embeddings.ts` | `embedTexts`/`cosineSimilarity`; cache `.embeddings-cache.json` keyed by page path, **per-path content hash** at line 104. Kill switch `SECOND_BRAIN_DISABLE_EMBEDDINGS=1`. |
| Validate | `mcp/src/tools/knowledge-validate.ts` | Issue types: `orphan_file\|broken_link\|missing_frontmatter\|duplicate_slug\|stale_page\|empty_page\|root_orphan`. Iterates `doc.related` for `broken_link`. **No generated-region / theme awareness** (net-new if wanted). |
| Forget | `scripts/wiki-forget-candidates.sh` → `scripts/wiki-forget-score.sh` | **`candidates.sh` is the real entry point** (dream FORGET + maintainer call it); it internally runs `score.sh`. `score.sh` category `case`: `learnings\|decisions\|concepts`→PROTECT; `entities\|...`→0.5; **`*)`→0.2, unprotected** — so an unrecognized `themes` category is currently a **prime forget candidate**. |
| Dream-runner tools | `agents/dream-runner.md` frontmatter | `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)`, `jq`, `find`, … — **no `node`**. A node CLI must be wrapped in a `scripts/*.sh` shim (the FORGET phase already does this: `wiki-forget-candidates.sh` → `wiki-recall-check.sh` → node search CLI). |

## Architecture

```
  ── LIVE path (knowledge-maintainer) ───────────────────────────────
   Phase 2 DEDUPLICATE  ── B2: knowledge_search top-k → {ADD|UPDATE|NOOP|SUPERSEDE}
   Phase 3 RELATE       ── B2 SUPERSEDE edges + (A1) drain conflicts.jsonl, via knowledge_relate
   Phase 5 REINDEX      ── knowledge_reindex (projects related: + Dependencies)

  ── DREAM path (dream-runner, STAGING copy of wiki/) ────────────────
   Phase 1 AUDIT → 2 DEDUPLICATE → 3 RELATE → 4 ENRICH
   Phase 4b SUMMARIZE (NEW)  ── B1: scripts/graph-cluster.sh (label-prop over staging related:)
                                → write themes/<cluster>.md into staging
   Phase 5 REINDEX  ── regenerates staging index incl. theme pages
   Phase 6 FORGET   ── wiki-forget-candidates.sh (themes PROTECTED)
        │ dream_accept → theme pages land live + reindex + embed
```

SUMMARIZE is inserted **after ENRICH, before REINDEX** (so theme pages are in the regenerated index) and **before FORGET** (which now protects them). **No existing phase is reordered** — only one phase is inserted — which keeps the back-compat golden test simple. The insertion must land in **both** SKILL.md (`2d` → new `2e SUMMARIZE` → renumber REINDEX `2f`, FORGET `2g`) **and** dream-runner.md (`Phase 4` → new `Phase 4b/5 SUMMARIZE` → REINDEX/FORGET shift), kept consistent.

## B2 — retrieval-grounded reconciliation (LIVE, `knowledge-maintainer`)

### B2.1 Mechanism (Mem0 two-phase add, on the live wiki)

In Phase 2 DEDUPLICATE, for each candidate page (a newly-mined page, or an existing page AUDIT flags as a possible duplicate):

1. **Retrieve.** Call `knowledge_search(candidate_title_or_text)` → top-k nearest live pages (`SB_RECONCILE_TOPK`, default 5). `knowledge_search` already fuses BM25 + cosine and **already falls back to BM25-only when `SECOND_BRAIN_DISABLE_EMBEDDINGS=1` or the vector dep is missing** — so no bespoke fallback code is needed (resolves the "where's the BM25 fallback" gap; the reusable fallback *is* `knowledge_search`).
2. **Decide (the maintainer's own reasoning, one decision per candidate):** emit `ADD` | `UPDATE <slug>` (merge facts into the canonical page; `## History` entry as the maintainer already does on merge) | `NOOP` | `SUPERSEDE <slug>` (§B2.2).
3. **Apply live**, bounded by the 50-change cap, visible in git.

### B2.2 Deterministic SUPERSEDE (the explicit-list mechanism)

`knowledge_relate(invalidate)` closes **exactly one** edge identity per call, and "which of the superseded page's edges are *now wrong*" is a semantic judgment, not a structural rule. So SUPERSEDE is specified as **N deterministic writes driven by an explicit LLM-chosen list**, never an automatic cascade:

1. Write the new page (Edit/Write).
2. `knowledge_neighbors(<old-slug>, direction:"out")` → enumerate the old page's **current-valid out-edges** `[(old, type, X)…]`.
3. The maintainer emits an **explicit list** of which of those `(old,type,X)` edges to invalidate (it may keep some — e.g. a still-true `part_of`).
4. **Loop**: one `knowledge_relate({from:old, type, to:X, invalidate:true, valid_to:<date>})` per named edge — each requiring that open edge to exist (it errors `ok:false` otherwise, which is a guard, not a cascade).
5. Assert the replacement: `knowledge_relate({from:<new>, to:<old>, type:"supersedes"})`.

**Directionality guard:** `knowledge_neighbors(direction:"out")` returns only edges whose **stored `from`** is `<old>`, and `knowledge_relate(invalidate)` matches on the **stored `(from,type,to)` identity** — *not* the auto-bidirectional read projection (`knowledge-maintainer.md`: "Bidirectionality is automatic — edges are walked both directions" applies to *reads*, not to the stored row). So the per-edge invalidate addresses exactly the enumerated out-edges and leaves any **inbound** `(X, type, old)` edge untouched. This must be asserted by a test (see #6), not assumed.

"Deterministic" = the *writes* are deterministic and idempotent given the list; the *selection* is the explicit, auditable LLM decision.

### B2.3 Safety & degrade (B2)

- **Live writes, but no new *write* powers**: B2 adds exactly one **new read tool** to the maintainer's repertoire — `knowledge_search` (reached via the same inherited MCP access as its existing `knowledge_relate`/`knowledge_neighbors` calls; no agent-frontmatter change). Its page/edge *write* powers are unchanged: the maintainer *already* merges pages (Phase 2) and curates edges (Phase 3) on the live wiki, bounded by 50 changes and recorded in git — B2 only makes those decisions *retrieval-grounded*. `wiki-write-guard` still guards file writes.
- **Degrade**: embeddings down ⇒ `knowledge_search` returns BM25-ranked top-k (degraded but functional). LLM/MCP down ⇒ the maintainer simply doesn't run; the deterministic extractor keeps appending pages/edges as today.
- **Failure mode** (Mem0/A-MEM documented risk): a wrong UPDATE/merge silently overwriting a good page → mitigated by git history + the maintainer's bounded, reportable change set.

### B2.4 Config (B2)

| Var | Default | Meaning |
|-----|---------|---------|
| `SB_RECONCILE` | `on` | enable retrieval-grounded dedup/supersede in the maintainer |
| `SB_RECONCILE_TOPK` | `5` | nearest live pages retrieved per candidate |
| `SB_RECONCILE_MAX` | `20` | cap reconcile decisions per maintainer run |

## B1 — community-summary pages (DREAM, new phase SUMMARIZE)

### B1.1 Clustering — deterministic label propagation (the determinism contract)

A new TS module `mcp/src/tools/graph-cluster.ts`, shipped as a bundled CLI and **wrapped in `scripts/graph-cluster.sh`** so the dream-runner can invoke it via `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)` (it cannot run `node` directly — same shim pattern as `wiki-forget-candidates.sh`).

- **Adjacency** is built from the **staging** wiki pages only: each page's `related:` frontmatter (the edge projection *as it stood when the staging snapshot was taken*) plus body `[[wiki-links]]`, undirected. This is a **point-in-time snapshot** — it may lag live edges appended during the dream's runtime — which is fine for an offline summary artifact (and avoids reading the non-snapshotted live `graph/edges.jsonl`). It is *not* "current-valid"; the periodic full rebuild + `dream_accept` review absorb the drift.
- **Determinism contract (this is the load-bearing part — tie-break alone is NOT enough):**
  - **Synchronous rounds** over nodes visited in **lexicographic slug order** (a total, machine-independent order).
  - Each round, every node's *next* label = the label held by the **plurality of its neighbors**, computed from the **previous round's** labels (synchronous ⇒ order-independent within a round).
  - **Labels ARE slugs** — a node's label is a page slug, and a community's id is the **lexicographically-smallest slug** among its members (stable, content-addressable). There is exactly **one** tie-break key.
  - **Tie-break**: keep the node's **own current label** if it is among the tied plurality, else take the **smallest slug** among the tied labels. (Keeping-own converges dense regions — cliques/triangles — which is exactly where theme-worthy clusters form.)
  - **Convergence**: stop when a round changes no labels, or at `SB_LABELPROP_MAXITER` (default 20); the final assignment is whatever the deterministic rule produced at cutoff (no randomness at the boundary).
  - **Known limitation (immaterial in practice):** a bare 2-node pair / pure bipartite component gives the keep-own rule no tie to bite on, so it oscillates and lands as *singletons* at the cutoff rather than merging. This never matters because theme pages require `minSize ≥ 4` and such components never reach that size. Verified by `tests/test-graph-cluster-shim.sh` (a 4-clique + a separate triangle both converge deterministically; the shuffle-invariance unit test covers visit-order).
- **Incremental** `assignNewNode`: a single synchronous step assigns a new node the plurality community of its neighbors; per Graphiti's own caveat this degrades over time, so a **full re-cluster** runs every `SB_SUMMARIZE_REBUILD_EVERY` dreams (default 7).

This determinism is **our** obligation regardless of what Graphiti does — the Graphiti citation is motivation, not proof. **Test #1 asserts byte-identical cluster assignment across (a) repeated runs and (b) the adjacency presented in shuffled insertion order** — shuffling the input is the test that actually catches visit-order leakage.

### B1.2 Theme pages (LLM summaries, regenerable, gated)

For each cluster with `≥ SB_SUMMARIZE_MIN_CLUSTER` members (default 4), the dream-runner writes `staging/wiki/themes/<cluster-slug>.md`:

```yaml
---
title: "Theme: <cluster label>"
type: themes
generated: true
related: [[member-a]], [[member-b]], ...      # member links go in related: (NOT a novel members: key)
member_hash: <hash>                            # see below
created: <date>
updated: <date>
---
<!-- theme:begin (generated — do not hand-edit) -->
## Theme summary
<LLM summary of what this cluster is about + how members relate>
<!-- theme:end -->
```

- **Member links live in `related:`**, the key `knowledge-search`/`knowledge-validate` actually read. (A novel `members:` key would be invisible to both, and because `related:` is populated the body-`[[links]]` harvest fallback never fires — so member links don't double-count.)
- **`member_hash` is content-aware**: a **self-contained** hash (computed in `graph-cluster.ts`) over the sorted member slugs concatenated with each member file's full-content hash (or sorted mtimes). Do **not** reuse `embeddings.ts`'s `simpleHash` — it is unexported and hashes *truncated embed-text*, not full file content, so it is the wrong primitive here. **Refresh a theme page when membership OR any member's content changed** — because ENRICH/DEDUPLICATE routinely change member *content* at stable membership; a set-only hash would silently serve stale summaries.
- **Regeneration is overwrite-enforced**: only the `theme:begin/end` region is rewritten (mirroring the `graph:begin/end` contract enforced by `graph-project.ts`). A hand-edit inside the region is overwritten next SUMMARIZE. *(An explicit validate warning for hand-edits is **net-new** logic — `knowledge-validate` has no such rule for `graph:begin/end` today — so it is listed as an optional follow-up, not "reuse an existing rule".)*

### B1.3 Interaction with FORGET, search, session-load

- **FORGET**: `themes` must be **protected** — and today it is the *opposite* (unrecognized category → `*)`→ `s_cat=0.2`, unprotected → a fresh, not-yet-inbound-linked theme page is a prime candidate). Add an explicit `themes)` arm to `scripts/wiki-forget-score.sh`'s category `case` with `prot="PROTECT:category"`. Because `wiki-forget-candidates.sh` (the real entry point) and the dream Review-phase re-score both call `score.sh`, the protection propagates to **both** paths. Protection is enforced via the **protflag column** (`candidates.sh` filters `$5==""`), independent of the numeric score — so the unconditional stub-floor down-weight on a short generated page is harmless (a builder must not "fix" this by raising `s_cat` alone). Test #8 asserts a freshly-generated theme page (0 inbound links, fresh mtime) is **never** emitted as a candidate by `wiki-forget-candidates.sh`.
- **Search**: no change required — theme pages are ordinary indexed pages once accepted. (Optional follow-up: a small boost so a theme page outranks its members on a broad query.)
- **`session-load.sh`**: for the active project's key entities, surface the **theme page of their cluster** (one line) within the byte budget — region, not just nearest slugs.
- **Caches/index populate at `dream_accept`, not dream-time.** In-dream "REINDEX" only rebuilds the staging `index.md` (the MCP reindex can't target staging). The embedding cache + live index update when the accepted theme pages land live. The spec does **not** claim theme pages participate in retrieval mid-dream.

### B1.4 Config (B1)

| Var | Default | Meaning |
|-----|---------|---------|
| `SB_DREAM_SUMMARIZE` | `on` | enable the SUMMARIZE phase |
| `SB_SUMMARIZE_MIN_CLUSTER` | `4` | min cluster size for a theme page |
| `SB_SUMMARIZE_MAX_PAGES` | `8` | cap theme pages written/refreshed per dream |
| `SB_SUMMARIZE_REBUILD_EVERY` | `7` | full re-cluster cadence (dreams) vs incremental assignment |
| `SB_LABELPROP_MAXITER` | `20` | label-propagation round cap |

## Error handling / safety

| Failure | Behaviour |
|---|---|
| Embeddings unavailable | B2: `knowledge_search` returns BM25-only top-k. B1: clustering uses links only — unaffected. |
| LLM/MCP-down | Maintainer/dream don't run; deterministic write path already captured pages/edges; nothing half-applied. |
| Bad merge / wrong supersede (B2, live) | Bounded by 50-change cap + git history + maintainer report; `wiki-write-guard` guards writes. |
| Theme page hand-edited inside markers | Region overwritten next SUMMARIZE (overwrite-enforced). |
| Cluster oscillation | Synchronous + keep-own-label tie-break breaks 2-cycles; `maxIter` cutoff is deterministic. |
| Theme vs FORGET | `themes` protected via the `score.sh` category arm → never a candidate. |
| `graph-cluster.sh` shim / node missing | Shim exits non-zero; SUMMARIZE skips (fail-safe), dream continues; logged. |

## Testing strategy (per the validate-the-real-capability learning)

TS via vitest (`graph-cluster.test.ts`), shell via `tests/test-*.sh`; gated by the deep-review release gate.

1. **Label-prop determinism (headline)**: fixed graph → byte-identical assignment across (a) repeated runs **and (b) shuffled adjacency insertion order**.
2. **Two-clique barbell**: → two clusters; the bridge node lands deterministically.
3. **Incremental assignment**: add a node linked mostly to cluster A → assigned A, no global re-cluster.
4. **Min-cluster gate**: a 3-member cluster (< 4) → no theme page.
5. **member_hash content-aware**: unchanged membership **but** a member's content changed → theme page **is** rewritten (proves content-fold, not set-only).
6. **B2 ops (live fixture)**: ADD writes a page; UPDATE merges into the named slug (no new file, `## History` added); NOOP drops; SUPERSEDE writes the page **and** invalidates exactly the maintainer-named out-edges (via `knowledge_neighbors` enumeration) while leaving unnamed ones live **and an inbound `(X,type,old)` edge untouched** (the directionality guard), then asserts the `supersedes` edge.
7. **B2 BM25 fallback**: with `SECOND_BRAIN_DISABLE_EMBEDDINGS=1`, reconcile still retrieves top-k via `knowledge_search` and decides.
8. **FORGET protection**: a freshly-generated `themes/` page (0 inbound, fresh mtime) is never emitted by `wiki-forget-candidates.sh`.
9. **validate**: theme-page `related:` member links don't raise `broken_link`/orphan; `type: themes` pages aren't mis-flagged. (Generated-region hand-edit warning is an optional follow-up test if that net-new rule is built.)
10. **Back-compat golden**: `SB_DREAM_SUMMARIZE=off` → the **staged dream diff** is identical to the 0.22.x baseline (SUMMARIZE is a pure insertion, so off ⇒ no new phase runs); `SB_RECONCILE=off` → the maintainer dedup/relate output is identical to baseline. Assert the **emitted phase sequence from both SKILL.md and dream-runner.md** match (the insertion landed consistently in both vocabularies).

## File-change inventory

**New:**
- `mcp/src/tools/graph-cluster.ts` — `buildAdjacency`, `labelPropagate` (synchronous, sorted-slug order, keep-own/lowest-id tie-break, deterministic cutoff), `assignNewNode`, cluster → members + content-aware `member_hash`.
- `mcp/src/tools/graph-cluster.test.ts` — determinism (repeat + shuffle), barbell, incremental, member_hash.
- `mcp/src/tools/graph-cluster-cli.ts` — bundled CLI (append to the `bundle` script in `mcp/package.json`).
- `scripts/graph-cluster.sh` — **shim** wrapping the node CLI so the dream-runner can invoke it via `Bash(bash $CLAUDE_PLUGIN_ROOT/scripts/*)`.
- `tests/test-dream-summarize.sh`, `tests/test-reconcile.sh` (+ fixtures).

**Modified:**
- `agents/knowledge-maintainer.md` — **B2**: Phase 2 retrieval-grounded dedup (`knowledge_search` top-k); Phase 3 deterministic SUPERSEDE (enumerate via `knowledge_neighbors`, explicit invalidate list) + (A1) conflict-queue drain.
- `skills/dream/SKILL.md` — insert `SUMMARIZE` after ENRICH/before REINDEX; renumber REINDEX/FORGET; correct the stale `### Step 2: 5-Phase` heading (it already lists 6).
- `agents/dream-runner.md` — insert the SUMMARIZE phase consistently in the `Phase 1..6` vocabulary; grant the `graph-cluster.sh` shim; theme-page write conventions.
- `scripts/wiki-forget-score.sh` — add a `themes)` category arm with `prot="PROTECT:category"` (propagates to `wiki-forget-candidates.sh` + the dream Review re-score).
- `mcp/src/tools/knowledge-validate.ts` — recognize `type: themes`/`generated:true` (don't mis-flag); add `themes` to `KNOWN_CATEGORIES` so `addFrontmatter` assigns `type: themes` if a theme page ever loses its frontmatter; *optional* net-new generated-region hand-edit warning.
- `scripts/session-load.sh` — surface the active project's theme page within the byte budget.
- `mcp/src/server.ts` — bump knowledge-base to `2.3.1` (bundled CLI + validate `themes` awareness; no new MCP *tool* / protocol change — additive patch).
- `mcp/src/tools/knowledge-reindex.ts` — confirm `themes/` pages are indexed (verify; likely automatic).
- `skills/upgrade/SKILL.md` — migration row (additive; `themes/` created lazily, no data migration).

## Rollout

1. Ship **dormant-safe**: with no cluster ≥ min size and no dup candidates, nothing new is produced; the flags allow a byte-identical opt-out.
2. First maintainer run: retrieval-grounded reconcile (live, bounded, git-visible). First dream: SUMMARIZE stages the first theme pages → reviewed at `dream_accept`.
3. Tune `SB_SUMMARIZE_MIN_CLUSTER` / `SB_RECONCILE_TOPK` against the first real diffs.
4. Validate with the test suite + a deep-review pass before release (per the gate).
5. Follow-ups (separate specs): theme-page retrieval boost; the optional validate hand-edit warning; A-MEM-style gated neighbor enrichment if reconcile proves safe in practice.
