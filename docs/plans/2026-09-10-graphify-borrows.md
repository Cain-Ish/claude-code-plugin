# Graphify borrows — what to take, what to reject

**Status: PROPOSED.** Source: full-source read of `Graphify-Labs/graphify@v8` (Apache-2.0, Python, v0.9.57)
on 2026-09-10. Each item gives options; the recommended one is marked. Nothing here is decided.

Graphify graphs a **corpus** (code, docs, PDFs, video) into a committed `graph.json`. We graph **sessions**
(decisions, blockers, learnings). Same phrase "knowledge graph", opposite input — so nothing here is a
"catch up to them" item. These are three mechanisms of theirs that answer questions our architecture
already has open.

---

## 1. Outcome memory as a non-destructive overlay (their `reflect.py`)

Their `graphify save-result` records a Q&A outcome (`useful | dead_end | corrected`); `graphify reflect`
time-decays and corroborates those into `reflections/LESSONS.md` plus a `.graphify_learning.json` overlay
tagging nodes `preferred | tentative | contested`. It is deterministic and LLM-free, and — the part that
matters — **no learning field is ever written into `graph.json`**. The overlay is a sidecar.

We have no usage or outcome signal at all: forgetting scores on *structural importance only*. But we already
collect the raw material and throw most of it away — `observe-tool-use.sh` writes `{ts, tool, target, ok, err}`
per tool call to `~/.second-brain/observations/<session>.jsonl`, and it is mined **only** as extraction input,
never as a retrieval or forgetting signal.

- **A. Record and expose, change no ranking (recommended).** Derive a per-page outcome tally from the
  observation ledger + injection manifest, write it to a sidecar (never into the page, never into
  `edges.jsonl`), and surface it in `knowledge_fetch`/`knowledge_stats`. Ranking, forgetting and injection
  stay exactly as they are. Cost: bounded, additive, deletable. Falsifiable milestone: *for the pages
  injected in the last 30 days, does the outcome tally separate the 2-reads-per-117-injections wheat from
  the chaff?* If it does not separate them, the signal is not there and items B/C die cheaply.
- **B. Feed the overlay into forgetting.** Structural importance plus outcome decay. Only defensible once A
  shows the signal exists, and forgetting is the one consumer where a wrong input silently destroys pages.
- **C. Feed the overlay into search ranking.** **Do not do this first.** The repo has already been burned by
  exactly this shape — an access-derived boost applied to the ranker corrupted search
  (`theme-access-boost-search-corruption`, and the post-RRF-boost bug class in
  `sb-memory-systems-reference`). A boost that multiplies a fused score is not a small change, whatever it
  looks like in the diff.

**Recommended first slice: A.** It is the only one of the three that cannot corrupt retrieval, and it is a
measurement that decides whether B and C are worth building.

## 2. Graded, provenance-aware edge confidence (their `EXTRACTED / INFERRED / AMBIGUOUS`)

Every graphify edge carries `EXTRACTED` (1.0, explicit in source), `INFERRED` (discrete rubric
0.95/0.85/0.75/0.65/0.55) or `AMBIGUOUS` (flagged for human review), documented in `docs/how-it-works.md:34-52`.

We are closer to this than it first appears, and worse off than we think. `graph-store.ts:18` already types
`confidence?: 'high' | 'medium'`, and the live store has 346 `high` / 14 `medium` across 360 edges, with
`source` in `{manual: 220, maintainer: 93, extractor: 47}`.

**The defect:** nothing reads it. `grep confidence mcp/src/tools/knowledge-neighbors.ts` returns nothing —
`knowledge_neighbors` neither filters nor ranks on confidence, and neither does search. Meanwhile
`consolidate-writer.ts:314-315` justifies forcing `medium` with the comment *"the graph's own consumers treat
confidence as a trust signal"* — which is not true of any consumer in the tree. That is a prose promise with
no machine lock, the exact class the repo's change-control rules name.

- **A. Make the existing field load-bearing (recommended).** Add a `min_confidence` filter to
  `knowledge_neighbors`, and a test asserting a `medium` edge is excluded at `min_confidence: 'high'`. Fixes
  the false comment by making it true. Small, additive, no schema change, no migration.
- **B. Add the third state (`ambiguous`) and widen the vocabulary.** This is what unblocks something real:
  `kb-schema.json` currently restricts the unattended P6 lane to `rel: relates` only, *because* a wrong typed
  edge distorts blast-radius answers. A confidence grade is the more precise instrument — the lane could
  propose `requires` at `ambiguous` instead of being forced to downgrade the type and lose the claim. Do it
  after A, and only with the dream-accept confirm-gate wired.
- **C. Numeric confidence with a rubric.** Rejected. Their 0.95/0.85/0.75 rubric is discrete labels wearing a
  float costume; it buys nothing our three-value vocabulary would not, and invites arithmetic on it.

## 3. Deterministic AST code extraction — **REJECT as reimplementation**

Their code path is genuinely impressive: ~40 languages via tree-sitter, `ProcessPoolExecutor` parallelism,
cross-file symbol resolution, **zero LLM credits to build a code graph**. Our `code_map` is PageRank over
imports.

Reasons not to build it:

1. **Native dependency.** tree-sitter's Node bindings are native; the repo's non-negotiables forbid native
   deps. `web-tree-sitter` (WASM) is the only route and it means shipping a `.wasm` grammar per language.
2. **Wrong subject.** A code graph is graphify's product and it is Apache-2.0 and better than anything we
   would write. Session memory is ours.
3. The LLM-free property we actually want from it — deterministic extraction with no model in the loop — is
   already the design goal of the P6 Stage-B writer. Borrow the *principle*, not the parser.

If code understanding ever becomes load-bearing here, the option is **interop, not reimplementation**: if a
repo has a `graphify-out/graph.json`, read it. Both stores are plain JSON on disk. That is a reader, not a
pipeline.

---

## What not to take at all

- **Committed, team-shared graph state with a git merge driver.** Their `graphify-out/` is designed to be
  committed and union-merged. Ours is single-user local by charter.
- **`--strict` PreToolUse deny.** Their strict mode *denies* the first raw source read of a session to force
  graph use. We already run a `PreToolUse` guard family; adding a deny that trains the agent to route around
  it is the wrong lever.
- **Graph-DB export, HTML force-directed viewer, PR triage, cross-repo global graph.** Product surface for a
  hosted service, not local-first memory.

## Sequencing

1. **1A** — outcome sidecar, no ranking change. Decides whether 1B/1C exist.
2. **2A** — `min_confidence` on `knowledge_neighbors` + the test that makes the false comment true.
3. Re-read this doc before starting **1B** or **2B**; both depend on 1A's measurement.
