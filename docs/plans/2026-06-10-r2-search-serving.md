# R2 — Search Serves the Right Page — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Fix the hub-boost score corruption that floor-evicts exact-title pages, make the eval able to see that bug class, make search output honest (tier / normalized score / degraded flag), and make embeddings survive version bumps without manual rescue.

**Architecture:** Boost contributions are computed from a frozen snapshot of pre-boost base scores and capped at ≤1× each page's own base (a page with zero text relevance can no longer ride the graph); the relevance floor uses base scores in the BM25-only path (RRF scores are rank-derived and inflation-proof, so the floor stays on final scores there). The eval gains a hub-distractor fixture (graph edges in the fixture corpus) and a `--live-titles` probe (every real page's title must return its own slug in top-2). Output adds additive fields only — raw `score` is unchanged because `KNOWLEDGE_MIN_SCORE` callers (persona-context 0.045, forget-probe 0.1) filter on it. Embeddings auto-relink at SessionStart via a new `--relink-only` installer mode that can never download (consent boundary preserved); the existing indexer repair-pass backfills empty embeddings on the next Stop hook.

**Tech Stack:** TypeScript + vitest (mcp/), bash (scripts/, tests/), jq. Spec: `docs/specs/2026-06-10-plugin-deep-dive-improvements-design.md` (wave R2). Findings: MCP-SEARCH-1/2, MCP-EVAL-1, MCP-DEPS-1 in the appendix.

**Versioning:** one release: plugin `0.24.38 → 0.24.39`, marketplace lockstep, MCP server `2.6.8 → 2.6.9` (knowledge_search/episodic_search output schema + descriptions), bundle rebuilt, migration row, deep-review gate.

**Executor caveats:**
- New shell tests must `unset CLAUDECODE` and sandbox `HOME`/`BRAIN_DIR` (see `tests/test-stop-extract.sh:13`).
- `tests/run-all.sh` re-chmods test files (known R6 chore) — commit explicit paths only.
- The eval harness runs BM25-only (`SECOND_BRAIN_DISABLE_EMBEDDINGS=1`) — deterministic; the vitest boost tests must set the same env.

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `mcp/src/tools/knowledge-search-boost.test.ts` | Create | R2.1 contract: title-match beats hub; zero-base page can't ride the graph |
| `mcp/src/tools/knowledge-search.ts` | Modify | frozen-base boost + cap, relates 0.25, floor-on-base (BM25 path), `score_norm`/`tier`/`degraded` output |
| `tests/fixtures/eval-wiki/graph/edges.jsonl` | Create | hub-distractor edges (fixture corpus root maps to KNOWLEDGE_DIR) |
| `tests/fixtures/eval-wiki/wiki/concepts/graph-hub.md` | Create | the hub page |
| `tests/fixtures/eval-queries.jsonl` | Modify | +2 golden hub-distractor queries |
| `scripts/wiki-recall-check.sh` | Modify | `--live-titles <wiki-dir>` probe mode |
| `tests/test-recall-live-titles.sh` | Create | probe mode works on the fixture corpus |
| `skills/lint/SKILL.md` | Modify | new check 5: live-title recall probe |
| `mcp/src/tools/episodic-search.ts` | Modify | `degraded: 'text-only'` when vector requested but unavailable |
| `mcp/src/tools/search-output-contract.test.ts` | Create | score_norm/degraded shape for both tools |
| `mcp/src/server.ts` | Modify | honest tool descriptions; version 2.6.9 |
| `bin/install-vector-deps.sh` | Modify | `--relink-only` mode (exit 3 unless the no-network step-1 path applies) |
| `scripts/session-load.sh` | Modify | block 0b auto-relink before bannering |
| `tests/test-session-load-relink.sh` | Create | auto-relink fires; failure falls back to the old banner |
| `skills/status/SKILL.md` | Modify | embeddings-coverage line |
| `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/upgrade/SKILL.md`, `mcp/dist/*` | Modify | 0.24.39 release mechanics |

---

### Task 1: Branch

- [ ] **Step 1:**

```bash
git checkout main && git pull
git checkout -b fix/0.24.39-r2-search-serving
git add docs/plans/2026-06-10-r2-search-serving.md
git commit -m "plan: R2 search-serving wave (deep-dive wave 2)"
```

---

### Task 2: R2.1 failing tests — vitest boost contract + eval hub fixture

- [ ] **Step 1: Create `mcp/src/tools/knowledge-search-boost.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeSearch } from './knowledge-search.js';

// R2.1 (MCP-SEARCH-1): graph boosts must be computed from FROZEN pre-boost base
// scores and capped at <=1x each page's own base. The old in-place mutation
// compounded geometrically through hub pages (~10,000x observed live), and the
// relative floor then evicted exact-title matches.
describe('hub-proof graph boost', () => {
  let kd: string;
  const page = (cat: string, slug: string, title: string, body: string) =>
    writeFileSync(join(kd, 'wiki', cat, `${slug}.md`),
      `---\ntitle: "${title}"\ndescription: "${title}"\ntype: ${cat}\n---\n\n# ${title}\n\n${body}\n`);

  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    kd = mkdtempSync(join(tmpdir(), 'sb-boost-'));
    mkdirSync(join(kd, 'wiki', 'concepts'), { recursive: true });
    mkdirSync(join(kd, 'graph'), { recursive: true });
    // Target: exact-title match for the query.
    page('concepts', 'wg-watchdog', 'wireguard tunnel watchdog restart',
      'The watchdog restarts the wireguard tunnel when the handshake goes stale. '.repeat(4));
    // Hub: weak text match, but connected to EVERY filler page.
    page('concepts', 'big-hub', 'architecture overview',
      'General overview page; mentions the tunnel once. '.repeat(4));
    // Zero-base page: no query tokens at all, linked to the hub.
    page('concepts', 'zero-base', 'unrelated gardening notes',
      'Tomatoes and compost only, nothing else. '.repeat(4));
    // 20 fillers each weakly matching one query token and linked to the hub.
    const edges: string[] = [];
    for (let i = 0; i < 20; i++) {
      page('concepts', `filler-${i}`, `note ${i}`,
        `This note mentions the tunnel briefly. Padding text for length here. `.repeat(3));
      edges.push(JSON.stringify({ op: 'assert', from: `filler-${i}`, to: 'big-hub', type: 'relates', valid_from: '2026-01-01', valid_to: null, recorded_at: '2026-01-01T00:00:00Z', source: 'test' }));
    }
    edges.push(JSON.stringify({ op: 'assert', from: 'big-hub', to: 'zero-base', type: 'relates', valid_from: '2026-01-01', valid_to: null, recorded_at: '2026-01-01T00:00:00Z', source: 'test' }));
    writeFileSync(join(kd, 'graph', 'edges.jsonl'), edges.join('\n') + '\n');
  });
  afterAll(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    rmSync(kd, { recursive: true, force: true });
  });

  it('exact-title page outranks the dense hub', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.length).toBeGreaterThan(0);
    expect(r.candidates[0].path).toContain('wg-watchdog');
  });

  it('exact-title page is not floor-evicted from the top-8', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.some(c => c.path.includes('wg-watchdog'))).toBe(true);
  });

  it('a zero-base page cannot ride the graph into the results', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.some(c => c.path.includes('zero-base'))).toBe(false);
  });
});
```

- [ ] **Step 2: Hub-distractor eval fixture.** Create `tests/fixtures/eval-wiki/wiki/concepts/graph-hub.md`:

```markdown
---
title: "knowledge system overview"
description: "High-level map of the second-brain memory system"
type: concepts
---

# knowledge system overview

A general map: search uses bm25 with a recency boost, embeddings come from the
vector deps cache, tiers split hot and cold memory, and dreams stage changes.
This page deliberately grazes every other fixture page's topic once.
```

Create `tests/fixtures/eval-wiki/graph/edges.jsonl` — the hub relates to every existing fixture page (one assert per line, exact shape):

```
{"op":"assert","from":"bm25-recency-boost","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"oauth-bare-flag","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"vector-deps-cache","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"episodic-embeddings","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"hot-cold-tier","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"hybrid-search","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"dream-staging","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
{"op":"assert","from":"forget-archive-move","to":"graph-hub","type":"relates","valid_from":"2026-01-01","valid_to":null,"recorded_at":"2026-01-01T00:00:00Z","source":"fixture"}
```

Append 2 golden queries to `tests/fixtures/eval-queries.jsonl` (title-matching pages must beat the hub at recall@2):

```
{"q":"how does the recency boost rank newer pages","expect":["bm25-recency-boost"]}
{"q":"dream staging directory for wiki changes","expect":["dream-staging"]}
```

- [ ] **Step 3: Run both — expect RED**

Run: `cd mcp && npx vitest run src/tools/knowledge-search-boost.test.ts; cd .. && bash tests/test-knowledge-eval.sh`
Expected: at least one vitest case FAILS (hub outranks / zero-base appears) and/or the eval gate FAILS on the new queries. If BOTH pass, STOP — the fixture isn't dense enough to reproduce compounding; add 10 more filler pages+edges to the vitest corpus before proceeding.

- [ ] **Step 4: Commit the red tests**

```bash
git add mcp/src/tools/knowledge-search-boost.test.ts tests/fixtures/eval-wiki/graph/edges.jsonl \
        tests/fixtures/eval-wiki/wiki/concepts/graph-hub.md tests/fixtures/eval-queries.jsonl
git commit -m "test(search): hub-distractor boost contract — RED (R2.1/R2.2, MCP-SEARCH-1, MCP-EVAL-1)"
```

---

### Task 3: R2.1 GREEN — frozen-base capped boost + floor-on-base

**Files:** Modify `mcp/src/tools/knowledge-search.ts`

- [ ] **Step 1: Track base scores.** In the `scored` map construction (line ~137), add a `baseScore` field initialized to the same BM25 value:

```ts
  const scored = allDocs.map(({ doc, rawContent, source, tokens }) => {
    const bm25 = scoreBM25(queryTokens, doc, avgDL, N, dfMap);
    return {
      path: doc.path,
      tier: 0,   // SP-1 project-scope tier (0 = scoping inactive); set below, stripped before return
      score: bm25,
      baseScore: bm25,   // frozen pre-boost BM25 (R2.1): boost math + the floor read THIS, never the mutated score
      related: doc.related,
      description: (doc.aiBlock && Object.keys(doc.aiBlock).length)
        ? aiBlockSnippet(doc.type, doc.aiBlock).slice(0, SNIPPET_CHARS)
        : (source === 'local-doc'
          ? doc.description
          : (doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim())),
      tokens,
      source,
    };
  });
```

- [ ] **Step 2: Replace the boost block** (lines ~151-206, both graph and legacy paths) with frozen-base accumulation + cap. `relates` drops 0.5 → 0.25:

```ts
  // Graph boost: propagate relevance through the typed relationship graph.
  // R2.1 (MCP-SEARCH-1): contributions are computed from FROZEN pre-boost base
  // scores and accumulated separately, then capped at <=1x each page's own
  // base. The previous in-place `target.score +=` compounded geometrically
  // through hub pages (~10,000x observed) and corrupted every ranking; a page
  // with zero text relevance can no longer ride the graph at all.
  const GRAPH_BOOST = 0.3;
  const slugScoreMap = new Map(scored.map(s => [slugFromPath(s.path), s]));
  const boostAccum = new Map<string, number>();
  let graphEdges: CurrentEdge[] = [];
  try {
    const recs = await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
    if (recs.length > 0) {
      const nowIso = new Date().toISOString();
      graphEdges = foldToCurrent(recs).filter(e => validAt(e, nowIso));
    }
  } catch { /* no graph — legacy path below */ }

  if (graphEdges.length > 0) {
    // Multi-hop typed propagation (depth 2). requires/affects propagate full,
    // relates much weaker (90% of real graphs are migration-generated relates).
    const TYPE_W: Record<string, number> = { requires: 1, affects: 1, part_of: 0.8, supersedes: 0.6, relates: 0.25 };
    const adj = new Map<string, { to: string; w: number }[]>();
    for (const e of graphEdges) {
      for (const [a, b] of [[e.from, e.to], [e.to, e.from]] as [string, string][]) {
        if (!adj.has(a)) adj.set(a, []);
        adj.get(a)!.push({ to: b, w: TYPE_W[e.type] ?? 0.25 });
      }
    }
    for (const entry of scored) {
      if (entry.baseScore <= 0) continue;
      const start = slugFromPath(entry.path);
      let frontier = [{ node: start, factor: 1 }];
      const seen = new Set<string>([start]);
      for (let hop = 0; hop < 2; hop++) {
        const next: { node: string; factor: number }[] = [];
        for (const { node, factor } of frontier) {
          for (const { to, w } of adj.get(node) ?? []) {
            const target = slugScoreMap.get(to);
            if (target && target !== entry) {
              boostAccum.set(to, (boostAccum.get(to) ?? 0) + entry.baseScore * GRAPH_BOOST * factor * w);
            }
            if (!seen.has(to)) { seen.add(to); next.push({ node: to, factor: factor * GRAPH_BOOST }); }
          }
        }
        frontier = next;
      }
    }
  } else {
    // Legacy one-hop boost over frontmatter related: — same frozen-base + cap discipline.
    for (const entry of scored) {
      if (entry.baseScore <= 0) continue;
      for (const rel of entry.related) {
        const target = slugScoreMap.get(rel);
        if (target && target !== entry) {
          boostAccum.set(rel, (boostAccum.get(rel) ?? 0) + entry.baseScore * GRAPH_BOOST);
        }
      }
    }
  }

  // Apply: total received boost capped at 1x the page's own base score.
  for (const s of scored) {
    const b = boostAccum.get(slugFromPath(s.path)) ?? 0;
    s.score = s.baseScore + Math.min(b, s.baseScore);
  }
```

- [ ] **Step 3: Capture embeddings-active state.** In the RRF block (line ~208), hoist a flag (Task 5 reuses it):

```ts
  // Hybrid search: if ONNX embeddings are available, fuse BM25 + cosine via RRF
  const RRF_K = 60;
  let embeddingsActive = false;
  try {
    ...
    if (embeddings) {
      embeddingsActive = true;
      ...
```

- [ ] **Step 4: Floor on base scores in the BM25-only path** (replace lines ~297-298). RRF scores are rank-derived (inflation-proof), so the floor stays on final scores there; raw BM25+boost is where the corruption lived:

```ts
  const topScore = scored.reduce((m, s) => Math.max(m, s.score), 0);
  const topBase = scored.reduce((m, s) => Math.max(m, s.baseScore), 0);
  // R2.1: in BM25-only mode the floor compares FROZEN base scores — the boost
  // can no longer inflate the cutoff and evict honestly-scored pages.
  const passesFloor = (c: { score: number; baseScore: number }) => embeddingsActive
    ? c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO)
    : c.score > 0 && (topBase === 0 || c.baseScore >= topBase * MIN_SCORE_RATIO);
```

- [ ] **Step 5: Strip the new field from output** — the candidate map (line ~310) destructure becomes `({ related, baseScore, tier, ...rest }) => rest` (Task 5 rewrites this map again; here just keep compilation green).

- [ ] **Step 6: Verify GREEN**

Run: `cd mcp && npx tsc --noEmit && npx vitest run && cd .. && bash tests/test-knowledge-eval.sh`
Expected: tsc clean; ALL vitest pass (incl. the 3 new + existing knowledge-search tests); eval gate `GATE PASS` incl. the 2 new queries.

- [ ] **Step 7: Live-wiki sanity check (the headline bug, on the real corpus)**

Run: `KNOWLEDGE_DIR=$HOME/knowledge SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node mcp/dist/tools/knowledge-search-cli.bundle.js "plugin hardening gap analysis" 2>/dev/null` — wait, the bundle is stale until Task 8; instead run via tsx/vitest is overkill — defer this check to Task 8 Step 3 after the bundle rebuild. Mark this step done.

- [ ] **Step 8: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts
git commit -m "fix(search): hub-proof ranking — frozen-base capped boost, relates 0.25, floor-on-base (R2.1, MCP-SEARCH-1)"
```

---

### Task 4: R2.3 — honest output contract (both search tools, server 2.6.9)

**Files:** Modify `mcp/src/tools/knowledge-search.ts`, `mcp/src/tools/episodic-search.ts`, `mcp/src/server.ts`; Create `mcp/src/tools/search-output-contract.test.ts`

- [ ] **Step 1: Write the failing test** — create `mcp/src/tools/search-output-contract.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeSearch } from './knowledge-search.js';
import { episodicSearch } from './episodic-search.js';

// R2.3 (MCP-SEARCH-2): output must be interpretable — additive score_norm on
// one 0..1 scale, and an explicit degraded flag when vector search is dead.
// Raw `score` stays untouched (KNOWLEDGE_MIN_SCORE callers filter on it).
describe('search output contract', () => {
  let kd: string; let brain: string;
  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    kd = mkdtempSync(join(tmpdir(), 'sb-contract-'));
    mkdirSync(join(kd, 'wiki', 'concepts'), { recursive: true });
    writeFileSync(join(kd, 'wiki', 'concepts', 'alpha.md'),
      '---\ntitle: "alpha tunnel page"\ndescription: "about tunnels"\ntype: concepts\n---\n\n# alpha tunnel page\n\ntunnel content here for matching\n');
    brain = mkdtempSync(join(tmpdir(), 'sb-contract-brain-'));
    writeFileSync(join(brain, 'episodic-index.json'), JSON.stringify({
      version: 1,
      exchanges: [{
        id: 'x1', sessionId: 's', project: 'p', date: '2026-06-01',
        userSnippet: 'how do tunnels work', assistantSnippet: 'tunnels work via wireguard',
        embedding: [], archivePath: join(brain, 'transcripts', 'a.txt'), lineStart: 1, lineEnd: 2,
      }],
    }));
  });
  afterAll(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    rmSync(kd, { recursive: true, force: true }); rmSync(brain, { recursive: true, force: true });
  });

  it('knowledge_search: score_norm in (0,1], top hit = 1, degraded flagged without embeddings', async () => {
    const r = await knowledgeSearch({ query: 'alpha tunnel', knowledgeDir: kd });
    expect(r.degraded).toBe('bm25-only');
    expect(r.candidates[0].score_norm).toBe(1);
    for (const c of r.candidates) {
      expect(c.score_norm).toBeGreaterThan(0);
      expect(c.score_norm).toBeLessThanOrEqual(1);
      expect(typeof c.score).toBe('number'); // raw score still present
    }
  });

  it('episodic_search: vector-requested search with no embeddings reports degraded text-only', async () => {
    const r = await episodicSearch({ query: 'tunnels', mode: 'both' }, brain);
    expect(r.degraded).toBe('text-only');
    expect(r.results.length).toBeGreaterThan(0); // text fallback still works
  });

  it('episodic_search: explicit text mode is not "degraded"', async () => {
    const r = await episodicSearch({ query: 'tunnels', mode: 'text' }, brain);
    expect(r.degraded).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`score_norm`/`degraded` undefined)

Run: `cd mcp && npx vitest run src/tools/search-output-contract.test.ts`

- [ ] **Step 3: knowledge-search.ts output.** Update the interface and the final map:

```ts
export interface KnowledgeSearchResult {
  candidates: { path: string; score: number; score_norm: number; tier?: number; description: string; tokens: number; source: string }[];
  /** Present when ONNX embeddings were unavailable — ranking fell back to BM25(+graph) only. */
  degraded?: 'bm25-only';
}
```

Final candidate construction (replaces the Task 3 Step 5 map):

```ts
  const topFinal = pool.reduce((m, s) => Math.max(m, s.score), 0);
  const candidates = pool
    .filter(passesFloor)
    .slice(0, TOP_K)
    .map(({ related, baseScore, tier, ...rest }) => ({
      ...rest,
      // Rank-normalized to (0,1] on ONE scale regardless of BM25-vs-RRF mode —
      // raw `score` is intentionally unchanged (KNOWLEDGE_MIN_SCORE contract).
      score_norm: topFinal > 0 ? Math.round((rest.score / topFinal) * 10000) / 10000 : 0,
      ...(scopeOn ? { tier } : {}),
    }));
```

And the return: `return { candidates, ...(embeddingsActive ? {} : { degraded: 'bm25-only' as const }) };`

- [ ] **Step 4: episodic-search.ts degraded flag.** Add to the result interface (find `EpisodicSearchResult` near the top): `degraded?: 'text-only';`. Change `vectorSearch` to report unavailability:

```ts
async function vectorSearch(
  query: string, index: EpisodicIndex, limit: number,
  filters: EpisodicSearchArgs, brainDir: string
): Promise<{ hits: (IndexedExchange & { similarity: number })[]; unavailable: boolean }> {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
  // unavailable = vector search COULD have run but can't (no vectors / no model);
  // an empty filter result is not a degradation.
  if (withEmbeddings.length === 0) return { hits: [], unavailable: filtered.length > 0 };

  const queryEmbedding = await embedTexts(
    [query], join(brainDir, 'transcripts'), ['']
  );
  if (!queryEmbedding) return { hits: [], unavailable: true };
  const qVec = queryEmbedding[0];

  return {
    hits: withEmbeddings
      .map(e => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) }))
      .sort((a, b) => b.similarity - a.similarity)
      .slice(0, limit),
    unavailable: false,
  };
}
```

In `episodicSearch` (single-query path):

```ts
  let degraded: 'text-only' | undefined;
  if (mode === 'vector' || mode === 'both') {
    const v = await vectorSearch(query, index, candLimit, args, brainDir);
    vectorResults = v.hits;
    if (v.unavailable) degraded = 'text-only';
  }
```

and the return: `return { results: ..., ...(degraded ? { degraded } : {}) };`. In `multiConceptSearch`, the two silent-empty returns (`withEmbeddings.length === 0` and `!conceptEmbeddings`) become `return { results: [], degraded: 'text-only' };`.

- [ ] **Step 5: server.ts.** Version `2.6.8 → 2.6.9` (line ~50). knowledge_search description becomes:

```
Hybrid search across the knowledge base wiki: BM25 (title 3x, description 2x, tags 2x, ai-block 1.5x, body 1x) fused with ONNX embeddings via RRF when available, plus capped graph-edge, access-frequency and recency boosts, project-scoped tiering. Returns top 8 candidates with path, raw score, score_norm (0..1, comparable across modes), tier (when project scoping is active), and snippet. Result carries degraded:'bm25-only' when embeddings are unavailable.
```

episodic_search description: append ` Result carries degraded:'text-only' when vector search is unavailable (embeddings missing) and only text matching ran.`

- [ ] **Step 6: GREEN + neighbors**

Run: `cd mcp && npx tsc --noEmit && npx vitest run`
Expected: clean; all pass (the new contract tests + existing knowledge-search/episodic tests — if an existing test asserts the exact candidate shape, update it to tolerate the additive fields).

- [ ] **Step 7: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/episodic-search.ts mcp/src/server.ts mcp/src/tools/search-output-contract.test.ts
git commit -m "feat(search): honest output contract — score_norm, tier, degraded flags; server 2.6.9 (R2.3, MCP-SEARCH-2)"
```

---

### Task 5: R2.2 — live-title recall probe

**Files:** Modify `scripts/wiki-recall-check.sh`, `skills/lint/SKILL.md`; Create `tests/test-recall-live-titles.sh`

- [ ] **Step 1: Write the failing test** — create `tests/test-recall-live-titles.sh`:

```bash
#!/bin/bash
# tests/test-recall-live-titles.sh — R2.2 live-title probe: every wiki page's own
# title, used as a query, must return that page's slug in the top-K. This is the
# invariant the hub-boost bug broke on the real wiki (exact-title page evicted).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

OUT=$(bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$ROOT/tests/fixtures/eval-wiki" --k 2 2>&1) \
  || fail "probe errored: $OUT"
echo "$OUT" | grep -q 'recall@2=1.000' || fail "fixture corpus must self-recall at 1.0, got: $OUT"
echo "$OUT" | grep -qE 'queries=[1-9]' || fail "probe generated no queries: $OUT"

# Gate mode wires through:
bash "$ROOT/scripts/wiki-recall-check.sh" --live-titles "$ROOT/tests/fixtures/eval-wiki" --k 2 --gate >/dev/null 2>&1 \
  || fail "gate mode failed on a healthy corpus"
echo "PASS: live-title probe self-recalls the fixture corpus"
echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL** (`unknown arg --live-titles`, exit 2)

Run: `bash tests/test-recall-live-titles.sh`

- [ ] **Step 3: Implement.** In `scripts/wiki-recall-check.sh`: accept the new arg in the parse loop:

```bash
  --live-titles) CORPUS="$2"; LIVE_TITLES=1; shift 2;;
```

(initialize `LIVE_TITLES=0` next to `CORPUS=""`). After the `[ -d "$CORPUS/wiki" ]` check, synthesize the queries file when in live mode:

```bash
# --live-titles (R2.2): generate one golden query per wiki page from its own
# title — invariant: a page's title must return its own slug in the top-K.
# This is exactly the class the hub-boost bug broke (MCP-SEARCH-1) and the
# fixed-fixture gate couldn't see (MCP-EVAL-1). Pages without a title line and
# index.md are skipped; sample cap via SB_EVAL_TITLE_SAMPLE (default all).
if [ "$LIVE_TITLES" -eq 1 ]; then
  QUERIES=$(mktemp)
  trap 'rm -f "$QUERIES"' EXIT
  CAP="${SB_EVAL_TITLE_SAMPLE:-0}"; case "$CAP" in ''|*[!0-9]*) CAP=0 ;; esac
  n=0
  while IFS= read -r f; do
    slug=$(basename "$f" .md)
    title=$(sed -n 's/^title:[[:space:]]*["'\'']\{0,1\}\(.*[^"'\'' ]\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$f" | head -1)
    [ -n "$title" ] || continue
    jq -nc --arg q "$title" --arg e "$slug" '{q:$q, expect:[$e]}' >> "$QUERIES"
    n=$((n+1)); [ "$CAP" -gt 0 ] && [ "$n" -ge "$CAP" ] && break
  done < <(find "$CORPUS/wiki" -name '*.md' ! -name 'index.md' | sort)
  [ -s "$QUERIES" ] || { echo "recall: no titled pages found under $CORPUS/wiki" >&2; exit 2; }
fi
```

(The existing `[ -f "$QUERIES" ]` check then passes; everything downstream is unchanged.)

- [ ] **Step 4: GREEN + existing eval still green**

Run: `bash tests/test-recall-live-titles.sh && bash tests/test-knowledge-eval.sh`
Expected: ALL PASS both.

- [ ] **Step 5: Wire into the lint skill.** In `skills/lint/SKILL.md`, after check 4 (`### 4. Missing ai-block…`), add:

```markdown
### 5. Live-title recall probe (search health)

Every page's own title should retrieve that page in the top-2. A failure here
means search ranking is broken for real content (the hub-boost class), not that
a page is bad. Read-only; uses the BM25-only deterministic path.

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-recall-check.sh" \
  --live-titles "${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}" --k 2
```

Report the recall line; if misses are listed, name the missed slugs under a
`## Search recall misses` section — they are SERVING bugs to investigate, not
pages to edit.
```

(Also update the lint skill's `allowed-tools` line if it does not already grant `Bash(bash *)` — check the frontmatter and add the narrowest matching grant consistent with its existing dialect.)

- [ ] **Step 6: Commit**

```bash
git add scripts/wiki-recall-check.sh tests/test-recall-live-titles.sh skills/lint/SKILL.md
git commit -m "feat(eval): --live-titles recall probe + lint wiring (R2.2, MCP-EVAL-1)"
```

---

### Task 6: R2.4 — `--relink-only` + SessionStart auto-relink

**Files:** Modify `bin/install-vector-deps.sh`, `scripts/session-load.sh`; Create `tests/test-session-load-relink.sh`

- [ ] **Step 1: Write the failing test** — create `tests/test-session-load-relink.sh` (mirror the sandbox scaffolding of `tests/test-session-load-embed-banner.sh` where it differs):

```bash
#!/bin/bash
# tests/test-session-load-relink.sh — R2.4: when transformers are missing from the
# plugin cache but the shared vector-deps tree is intact, SessionStart re-links
# AUTOMATICALLY (pure local symlink, no network, no consent needed) and banners
# "auto-relinked" once — instead of asking the user to run a command (MCP-DEPS-1).
# When the relink-only path can't apply (exit 3), the old fix-it banner remains.
set -u
unset CLAUDECODE 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
export HOME="$SANDBOX"
export BRAIN_DIR="$SANDBOX/.second-brain"
mkdir -p "$BRAIN_DIR"

# Index with >10 empty embeddings so trigger (2) is armed too.
jq -n '{version:1, exchanges:[range(0;12) | {id:("x"+tostring), sessionId:"s", project:"p", date:"2026-06-01", userSnippet:"u", assistantSnippet:"a", embedding:[], archivePath:"", lineStart:1, lineEnd:2}]}' \
  > "$BRAIN_DIR/episodic-index.json"

# Fake plugin root: no mcp/node_modules/@huggingface/transformers → EPI_XFMR_MISSING=1.
PR="$SANDBOX/plugin-root"
mkdir -p "$PR/bin" "$PR/mcp" "$PR/scripts"
cp "$ROOT/scripts/session-load.sh" "$ROOT/scripts/lib.sh" "$PR/scripts/" 2>/dev/null || true
CALLED="$SANDBOX/relink-called"
cat > "$PR/bin/install-vector-deps.sh" <<EOF
#!/bin/bash
echo "\$1" > "$CALLED"
exit "\${SB_TEST_RELINK_RC:-0}"
EOF
chmod +x "$PR/bin/install-vector-deps.sh"
export CLAUDE_PLUGIN_ROOT="$PR"

run_load() { printf '{"hook_event_name":"SessionStart"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null; }

# Case 1: relink succeeds → auto-relinked banner, NOT the manual-fix banner.
OUT=$(SB_TEST_RELINK_RC=0 run_load)
[ -f "$CALLED" ] || fail "install-vector-deps.sh was not invoked"
[ "$(cat "$CALLED")" = "--relink-only" ] || fail "expected --relink-only arg, got '$(cat "$CALLED")'"
printf '%s' "$OUT" | grep -q 'auto-relinked' || fail "success: missing auto-relinked banner"
printf '%s' "$OUT" | grep -q 'install-vector-deps.sh` (re-links' && fail "success: manual-fix banner still shown"

# Case 2: relink-only not applicable (exit 3) → the manual banner remains.
rm -f "$CALLED"
OUT=$(SB_TEST_RELINK_RC=3 run_load)
printf '%s' "$OUT" | grep -q 'episodic vector search degraded' || fail "failure: manual banner missing"
printf '%s' "$OUT" | grep -q 'auto-relinked' && fail "failure: auto-relinked banner shown despite rc=3"

echo "PASS: SessionStart auto-relink (success + fallback paths)"
echo "ALL PASS"
```

NOTE: `run_load` invokes the REPO's session-load.sh (so the change under test is exercised) while `CLAUDE_PLUGIN_ROOT` points at the fake root for the stub + the missing-transformers check. If session-load.sh requires other sandbox furniture to reach block 0b (it is fail-soft by design), check `tests/test-session-load-embed-banner.sh` and copy its minimal setup lines.

- [ ] **Step 2: Run — expect FAIL** (no invocation / no auto-relinked banner)

Run: `bash tests/test-session-load-relink.sh`

- [ ] **Step 3: `--relink-only` in `bin/install-vector-deps.sh`.** After `set -eu` (line 22):

```bash
# --relink-only (R2.4): succeed ONLY via the no-network step-1 path (shared tree
# present + key-current + complete + importable → symlink). Anything that would
# require staging or npm exits 3 untouched — callers (SessionStart auto-heal)
# rely on this NEVER downloading, preserving the consent-for-download boundary.
RELINK_ONLY=0
[ "${1:-}" = "--relink-only" ] && RELINK_ONLY=1
```

And right after the step-1 block (the `if [ -f "$SHARED_MARKER" ] … fi` ending line ~88), before `mkdir -p "$SHARED"`:

```bash
if [ "$RELINK_ONLY" -eq 1 ]; then
  echo "install-vector-deps: --relink-only — shared tree absent/stale/broken; not proceeding (would need staging/npm)." >&2
  exit 3
fi
```

- [ ] **Step 4: session-load.sh auto-relink.** In block 0b, immediately after the `EPI_XFMR_MISSING` computation line and BEFORE the banner `if`:

```bash
  # R2.4 auto-heal (MCP-DEPS-1): a fresh version dir missing the shared-deps
  # symlink is a pure LOCAL relink — no download, no consent needed. Try it
  # before bannering; the manual banner remains for the genuinely-broken cases
  # (no shared tree / key drift / import failure → installer exits 3).
  if [ "$EPI_XFMR_MISSING" -eq 1 ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
     && [ -x "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" ] \
     && bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" --relink-only >/dev/null 2>&1; then
    EPI_XFMR_MISSING=0
    sb_append "$(printf '## ⓘ second-brain — embeddings auto-relinked\nThis plugin version was missing its shared vector-deps symlink (every cache refresh ships without node_modules); re-linked automatically — no download. Empty embeddings backfill on the next session-end extraction.\n\n')" "episodic-embed-relinked" 300
  fi
```

(The stub in the test is not executable via `bash` path-check `-x` — the test chmods it +x, fine. After a successful relink, trigger (2) `EPI_PENDING>10` could still fire the manual banner; that is correct-but-noisy for one session — acceptable: the pending count drains via the indexer repair pass. If Case 1 of the test trips on this, gate the banner condition on `EPI_XFMR_MISSING -eq 1 ||` only when no relink happened this run: set `EPI_RELINKED=1` in the success branch and add `&& [ "${EPI_RELINKED:-0}" -eq 0 ]` to the banner condition.)

- [ ] **Step 5: GREEN + neighbors**

Run: `bash tests/test-session-load-relink.sh && bash tests/test-session-load-embed-banner.sh`
Expected: ALL PASS both (the embed-banner test exercises the no-shared-tree path — its stub/fixture has no `bin/install-vector-deps.sh` or it exits non-zero; if it now fails because the auto-relink intercepts, set its sandbox stub to exit 3 — that IS the manual-banner case it pins).

- [ ] **Step 6: Commit**

```bash
git add bin/install-vector-deps.sh scripts/session-load.sh tests/test-session-load-relink.sh
git commit -m "feat(embeddings): SessionStart auto-relink via install-vector-deps --relink-only (R2.4, MCP-DEPS-1)"
```

---

### Task 7: R2.4 — embeddings coverage in /second-brain:status

**Files:** Modify `skills/status/SKILL.md`

- [ ] **Step 1:** Add to the status skill (next to its episodic/index reporting section — find the section that reads `episodic-index.json`; if none, add after the wiki stats step):

```markdown
### Embeddings coverage

One line: what fraction of indexed exchanges have vectors. 100% = healthy;
anything less means vector recall silently misses those exchanges (the next
session-end extraction backfills if the deps are linked).

```bash
EPI=${BRAIN_DIR:-$HOME/.second-brain}/episodic-index.json
if [ -f "$EPI" ]; then
  jq -r '(.exchanges|length) as $t
    | ([.exchanges[] | select((.embedding|length) > 0)] | length) as $e
    | if $t == 0 then "Embeddings: no exchanges indexed yet"
      else "Embeddings coverage: \($e)/\($t) exchanges (\(($e * 100 / $t) | floor)%)" end' "$EPI"
fi
```
```

- [ ] **Step 2: Verify the snippet works against the real index**

Run: `EPI=~/.second-brain/episodic-index.json; jq -r '(.exchanges|length) as $t | ([.exchanges[] | select((.embedding|length) > 0)] | length) as $e | if $t == 0 then "none" else "\($e)/\($t)" end' "$EPI"`
Expected: a sane `N/M` (today ~836/894).

- [ ] **Step 3: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "feat(status): embeddings-coverage line (R2.4)"
```

---

### Task 8: Release mechanics + full verification

- [ ] **Step 1:** `.claude-plugin/plugin.json` → `0.24.39`; marketplace second-brain entry → `0.24.39` (cost-router stays `0.1.1`). Migration row (above 0.24.38, same format):

> **0.24.39** — R2 search-serving. (1) Hub-proof ranking: graph/related boosts computed from frozen pre-boost base scores, capped at ≤1× each page's own base, `relates` weight 0.25; relevance floor uses base scores in BM25-only mode. Fixes exact-title pages being floor-evicted by hub-inflated scores. (2) knowledge_search output adds `score_norm` (0..1) and `tier` (when project-scoped) per candidate and `degraded:'bm25-only'` at result level; episodic_search adds `degraded:'text-only'`; raw `score` semantics unchanged (`KNOWLEDGE_MIN_SCORE` contract intact). MCP server 2.6.9. (3) Eval: hub-distractor fixture + `wiki-recall-check.sh --live-titles` probe (lint check 5). (4) Embeddings self-heal: `install-vector-deps.sh --relink-only` (never downloads) runs automatically at SessionStart when the cache symlink is missing; coverage % in /second-brain:status. No precondition — bumping the marker is sufficient; the auto-relink fires on the first session of this version.

- [ ] **Step 2: Rebuild bundle + full suite + validate**

Run: `cd mcp && npm run bundle && cd .. && bash tests/run-all.sh && bash scripts/validate-plugin.sh`
Expected: bundle rebuilt (git shows mcp/dist changes incl. knowledge-search-cli/server bundles); suite ALL GREEN; validator OK.

- [ ] **Step 3: Live-wiki headline check (the original bug, now with the fresh bundle)**

Run: `KNOWLEDGE_DIR=$HOME/knowledge SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node mcp/dist/tools/knowledge-search-cli.bundle.js "plugin hardening gap analysis" 2>/dev/null`
Expected: output includes `[[plugin-hardening-gap-analysis-2026-05-28]]` in the top-2 lines. Also run the live probe: `bash scripts/wiki-recall-check.sh --live-titles ~/knowledge --k 2` and record the recall line (expect a dramatic improvement vs the broken ranking; investigate any remaining misses before shipping — they may be legitimately ambiguous titles, note them in the PR body rather than blocking).

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json skills/upgrade/SKILL.md mcp/dist
git commit -m "release: 0.24.39 — R2 search-serving wave (hub-proof ranking, honest output, live-title eval, embeddings auto-relink)"
```

---

### Task 9: Deep-review gate + PR

- [ ] **Step 1:** Run `/second-brain:code-review-deep` on the branch (release discipline). Apply confirmed findings, re-run the suite, commit fixes.
- [ ] **Step 2:** Push + PR:

```bash
git push -u origin fix/0.24.39-r2-search-serving
gh pr create --base main --title "fix: 0.24.39 — R2 search-serving wave (deep-dive)" --body "$(cat <<'EOF'
Implements wave R2 of docs/specs/2026-06-10-plugin-deep-dive-improvements-design.md:
- R2.1 hub-proof ranking (MCP-SEARCH-1): frozen-base capped graph boost, relates 0.25, floor-on-base in BM25-only mode
- R2.2 eval that can see this class (MCP-EVAL-1): hub-distractor fixture + --live-titles probe wired into /second-brain:lint
- R2.3 honest output (MCP-SEARCH-2): score_norm + tier + degraded flags on both search tools (server 2.6.9); raw score contract unchanged
- R2.4 embeddings that stay alive (MCP-DEPS-1): SessionStart auto-relink via --relink-only (never downloads), coverage % in /status; backfill rides the existing indexer repair pass

Post-merge smoke: install 0.24.39; first session should banner "embeddings auto-relinked" (this cache is currently unlinked); after one session-end, /second-brain:status coverage should reach 100%; `knowledge_search("plugin hardening gap analysis")` must return the gap-analysis page top-2.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Plan self-review (done at authoring time)

- **Spec coverage:** R2.1 → Tasks 2-3; R2.2 → Tasks 2 (fixture) + 5 (probe); R2.3 → Task 4; R2.4 → Tasks 6-7 (backfill = existing `buildEpisodicIndex` repair pass, verified present at episodic-search.ts:238-249 — no new code needed); release discipline → Tasks 8-9. Deliberate deferral (per spec): SP-1 slot interleave — re-measure with the live probe after this ships.
- **Contract risks called out inline:** raw `score` untouched because persona-context (0.045) and forget-probe (0.1) filter on it; CLI `[[slug]]` output format unchanged (eval + persona-context parse it); existing vitest shape assertions may need additive-field tolerance (Task 4 Step 6).
- **Type consistency:** `baseScore` introduced in Task 3 Step 1, consumed in Steps 2/4 and stripped in Task 4 Step 3; `embeddingsActive` defined Task 3 Step 3, consumed Task 3 Step 4 + Task 4 Step 3; `vectorSearch` new return shape `{hits, unavailable}` matches its single caller update.
