import { promises as fs } from 'fs';
import { atomicWriteJson } from './atomic-write.js';
import { join } from 'path';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';
import { embedTexts, cosineSimilarity } from './embeddings.js';
import { estimateTokens } from './egress-budget.js';
import { loadRegistry } from './doc-sources.js';
import { loadEdges, foldToCurrent, validAt, CurrentEdge } from './graph-store.js';
import { stripAiBlock, aiBlockSnippet } from './ai-block.js';
import { projectFamily } from './project-registry.js';
import { parseDoc, ParsedDoc } from './frontmatter.js';
import { walkWiki } from './walk-wiki.js';

// Frontmatter parsing lives in ./frontmatter.ts (single source); re-exported here for back-compat.
export { parseDoc, extractYamlValue, extractYamlList } from './frontmatter.js';
export type { ParsedDoc } from './frontmatter.js';

/** Concatenated ai-block field VALUES for BM25 tokenization (the proposition-level unit). */
function aiBlockText(doc: ParsedDoc): string { return doc.aiBlock ? Object.values(doc.aiBlock).join(' ') : ''; }

/** Parse an env int with a default + clamp; tolerant of unset/garbage. (SP-1 scoping knobs.) */
function clampEnvInt(name: string, def: number, lo: number, hi: number): number {
  const n = parseInt(process.env[name] ?? '', 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : def;
}

/** Slugs reachable within `hops` UNDIRECTED graph hops from any seed slug (seeds included; the
 *  caller classifies seeds tier-1 regardless). Empty when no graph. (SP-1 project neighbourhood.) */
function graphNeighbourhood(seeds: string[], edges: CurrentEdge[], hops: number): Set<string> {
  const adj = new Map<string, string[]>();
  for (const e of edges) for (const [a, b] of [[e.from, e.to], [e.to, e.from]] as [string, string][]) {
    if (!adj.has(a)) adj.set(a, []);
    adj.get(a)!.push(b);
  }
  const reached = new Set<string>(seeds);
  let frontier = [...seeds];
  for (let h = 0; h < hops; h++) {
    const next: string[] = [];
    for (const node of frontier) for (const to of adj.get(node) ?? []) if (!reached.has(to)) { reached.add(to); next.push(to); }
    frontier = next;
  }
  return reached;
}

export interface KnowledgeSearchArgs { query: string; scope?: string; knowledgeDir?: string; brainDir?: string; projectSlug?: string; }
export interface KnowledgeSearchResult {
  candidates: {
    path: string;
    /** Raw engine score — BM25(+capped boosts) or RRF scale depending on mode. Filterable via KNOWLEDGE_MIN_SCORE (contract preserved). */
    score: number;
    /** Rank-normalized to (0,1] on ONE scale regardless of mode (R2.3). The
     *  highest-scored RETURNED candidate is exactly 1; under project scoping
     *  (tier-major ordering) that anchor may not be the first listed.
     *  NOTE (cross-project reservation): when a tier-5 page is reserved it outscores every
     *  in-scope candidate BY CONSTRUCTION, so it becomes the 1.0 anchor and every in-scope
     *  result is normalized below it — including what would otherwise have been the top
     *  in-scope hit. Consumers using score_norm as an in-scope confidence heuristic must
     *  account for an anchor that is deliberately OUTSIDE the requested scope. */
    score_norm: number;
    /** Frozen pre-boost BM25 — the ABSOLUTE relevance signal. RELEVANCE GATES MUST READ
     *  THIS, NEVER `score`. In hybrid mode `score` is rank-derived RRF: its maximum is
     *  2/(RRF_K+1) = 0.0328, ×1.3 recency = a 0.0426 ceiling, and it carries no relevance
     *  information at all because EVERY query has a rank-1 document. Measured on the live
     *  372-page wiki: nonsense queries reach RRF 0.0371 while genuine queries bottom out
     *  at 0.0282 (fully overlapping), but the two separate cleanly on this field
     *  (nonsense ≤28.5, genuine ≥48.6). A gate on `score` at 0.045 sat ABOVE the
     *  mathematical ceiling and made per-prompt wiki injection dead for every hybrid-mode
     *  session — measured 0 reads over 83 injected items. */
    relevance: number;
    /** How many DISTINCT query terms occur in title/description/tags — the "is this page
     *  ABOUT the query" signal. Body matches deliberately do NOT count: incidental body
     *  overlap is exactly what lets an off-topic page score. Pair it with `relevance` as a
     *  conjunction; each covers the other's blind spot (relevance kills junk that happens
     *  to share a title word, grounding kills the lexically-adjacent-but-off-topic page). */
    grounded: number;
    /** Distinct query terms after tokenization. Callers gating on `grounded` must clamp
     *  their threshold to this (`min(threshold, query_terms)`), or a one-word query becomes
     *  unsatisfiable — the same class of bug as gating `score` above its own ceiling. */
    query_terms?: number;
    /** SP-1 project-scope tier (1=active project, 2=monorepo family, 3=graph-neighbour,
     *  4=global/no facet, 5=other project). Present only when scoping is active. */
    tier?: number;
    description: string;
    tokens: number;
    source: string;
  }[];
  /** Present when ONNX embeddings were unavailable — ranking fell back to BM25(+graph) only (R2.3). */
  degraded?: 'bm25-only';
  /** Present when project scoping was active: the slug it keyed on. */
  scoped_to?: string;
  /** Present with scoped_to: how many wiki pages carry project:<scoped_to> exactly.
   *  0 means tier-1 anchoring collapsed for this slug — an unpopulated facet, an
   *  unknown/mistyped slug, or a genuinely new project. Family (tier 2) and graph
   *  (tier 3) scoping may still be active; this counts direct facets only. */
  anchors?: number;
}

interface AccessCounts { [slug: string]: { count: number; last_accessed: string } }
// R2.2 hermeticity: resolved per-call from SB_BRAIN_DIR/BRAIN_DIR (matching the
// server + embeddings conventions), NOT hardcoded to $HOME — eval/test runs were
// reading the LIVE access counts into their rankings AND writing fixture slugs
// back into the user's real state, making the "deterministic" recall gate
// flip-flop run-to-run.
function accessCountsFile(): string {
  return join(resolveBrainDir(), 'access-counts.json');
}
// P4b (spec 2026-06-26 §6): the access-frequency SEARCH BOOST was cut — it is the recsys
// "rich-get-richer" hub bias (the ~10,000x corruption class). Access counts now survive ONLY
// as `acc=` telemetry in wiki-forget-score.sh (recorded below, never folded into ranking).
const ACCESS_PRUNE_DAYS = 90;

async function loadAccessCounts(): Promise<AccessCounts> {
  try { return JSON.parse(await fs.readFile(accessCountsFile(), 'utf-8')); }
  catch { return {}; }
}

async function saveAccessCounts(counts: AccessCounts): Promise<void> {
  const cutoff = new Date(Date.now() - ACCESS_PRUNE_DAYS * 86400000).toISOString();
  const pruned: AccessCounts = {};
  for (const [k, v] of Object.entries(counts)) {
    if (v.last_accessed >= cutoff) pruned[k] = v;
  }
  await atomicWriteJson(accessCountsFile(), pruned);
}

const TOP_K = 8;
const SNIPPET_CHARS = 200;
const BM25_K1 = 1.2;
const BM25_B = 0.75;
const AVG_DOC_LENGTH = 200;
const DATE_TOKEN_RE = /^\d{4}$|^\d{2}$/;
const MIN_SCORE_RATIO = 0.15;
const STUB_PENALTY = 0.5;
// A query term occurring in more than this share of the corpus is non-discriminative for
// GROUNDING only (never for BM25 itself) — the stopword filter `tokenize` does not have.
// Swept on the live 372-page wiki, 6 genuine vs 6 nonsense queries, no BM25 floor at all:
//   0.15 → 4/6 genuine, 0/6 nonsense      (over-filters: a single-project wiki uses its own
//   0.25 → 5/6 genuine, 0/6 nonsense       vocabulary constantly — "guard", "dream", "accept"
//   0.4  → 6/6 genuine, 0/6 nonsense       are common HERE yet still discriminative)
//   0.5  → 6/6 genuine, 0/6 nonsense   ← shipped, middle of the plateau
//   0.7  → 6/6 genuine, 0/6 nonsense
//   1.0  → 6/6 genuine, 3/6 nonsense      (no filtering — "best way to grill vegetables"
//                                          grounds on "best"/"way" and injects a random page)
// A SHARE, not a count, so it is corpus-size invariant: an absolute BM25 floor tested cleanly
// here but dies on a small wiki, where df→N drives IDF→0 and every score collapses regardless
// of match quality. That is the same "gate above its own ceiling" bug this whole change fixes,
// so it must not be reintroduced as the default.
// Minimum corpus size for a document-frequency SHARE to carry information. Below this the
// grounding filter is skipped entirely (see discriminativeTerms). Chosen so real wikis (hundreds
// of pages) always filter, while small fixtures and a first-install wiki never do.
const MIN_CORPUS_FOR_DF = 8;
// Words that can never establish that a page is ABOUT something. Used ONLY by grounding
// (discriminativeTerms) — never by BM25, which keeps scoring them exactly as before, so ranking
// is unchanged and this cannot resurrect or evict anything. Deliberately small and boring:
// English function words plus the generic verbs/qualifiers that dominate casual prompts
// ("what is the best way to do this"). Extending it is safe; it can only make grounding
// stricter, and a term wrongly listed here just means one fewer way to ground a page.
const GROUNDING_STOPWORDS = new Set([
  'the', 'a', 'an', 'and', 'or', 'but', 'if', 'then', 'than', 'that', 'this', 'these', 'those',
  'is', 'are', 'was', 'were', 'be', 'been', 'being', 'am',
  'do', 'does', 'did', 'doing', 'done', 'have', 'has', 'had', 'having',
  'can', 'could', 'will', 'would', 'should', 'shall', 'may', 'might', 'must',
  'i', 'you', 'we', 'they', 'he', 'she', 'it', 'me', 'my', 'our', 'your', 'their', 'its',
  'to', 'of', 'in', 'on', 'at', 'by', 'for', 'with', 'from', 'into', 'onto', 'about', 'as',
  'what', 'when', 'where', 'which', 'who', 'whom', 'why', 'how',
  'not', 'no', 'yes', 'so', 'up', 'down', 'out', 'off', 'over', 'under', 'again', 'here', 'there',
  'best', 'better', 'good', 'bad', 'way', 'ways', 'thing', 'things', 'stuff',
  'get', 'got', 'make', 'made', 'use', 'used', 'using', 'need', 'want', 'like', 'please', 'help',
  'some', 'any', 'all', 'more', 'most', 'much', 'many', 'very', 'just', 'only', 'also', 'now',
]);
const COMMON_TERM_DF_SHARE = (() => {
  const v = parseFloat(process.env.SB_GROUNDING_DF_SHARE ?? '');
  return Number.isFinite(v) && v > 0 && v <= 1 ? v : 0.5;
})();
const MIN_SUBSTANTIVE_LENGTH = 100;
const AUTO_EXTRACTED_RE = /<!--\s*auto-extracted/;

export async function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult> {
  const knowledgeDir = resolveKnowledgeDir(args.knowledgeDir);
  const wikiRoot = join(knowledgeDir, 'wiki');

  let scopeDirs: string[];
  if (args.scope && args.scope !== 'all') {   // 'all' = explicit no-category + no-project scope (search everything)
    scopeDirs = [join(wikiRoot, args.scope)];
  } else {
    try {
      const entries = await fs.readdir(wikiRoot, { withFileTypes: true });
      scopeDirs = entries.filter(d => d.isDirectory()).map(d => join(wikiRoot, d.name));
    } catch {
      scopeDirs = [];
    }
  }

  const queryTokens = tokenize(args.query).filter(t => !isDateToken(t));
  if (queryTokens.length === 0) return { candidates: [] };

  const allDocs: { doc: ParsedDoc; rawContent: string; source: 'wiki' | 'local-doc'; tokens: number }[] = [];

  for (const dir of scopeDirs) {
    const paths = await walkWiki(dir, { posix: true });   // posix: result paths are the /-separated contract
    for (const filePath of paths) {
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const doc = parseDoc(content, filePath);
        allDocs.push({ doc, rawContent: content, source: 'wiki', tokens: estimateTokens(content) });
      } catch { continue; }
    }
  }

  if (args.brainDir && args.projectSlug) {
    const reg = await loadRegistry(args.brainDir, args.projectSlug);
    for (const e of reg?.entries ?? []) {
      const doc: ParsedDoc = {
        title: '', description: e.gist, type: 'local-doc', tags: [],
        related: [], body: e.headings.join('\n'), path: e.path,
        updated: e.mtime, created: e.mtime, project: '', area: '',
      };
      allDocs.push({ doc, rawContent: `${e.gist}\n${e.headings.join('\n')}`, source: 'local-doc', tokens: Math.ceil(e.size / 4) });
    }
  }

  if (allDocs.length === 0) return { candidates: [] };

  // Tokenize each doc ONCE into per-field token-count maps (the old hot path
  // re-tokenized every doc for every query token — O(Q×N×L)). Reused for
  // avgDL, DF, BM25 scoring, and the stub check; the math is identical to the
  // per-call tokenization it replaces (locked by the ranking-regression test).
  const indexed = allDocs.map(({ doc }) => indexDoc(doc));

  const avgDL = indexed.reduce((sum, d) => sum + d.bodyLen, 0) / allDocs.length || AVG_DOC_LENGTH;

  const N = allDocs.length;
  const dfMap = computeDF(queryTokens, indexed);

  const scored = allDocs.map(({ doc, rawContent, source, tokens }, i) => {
    const bm25 = scoreBM25(queryTokens, indexed[i], avgDL, N, dfMap);
    return {
      path: doc.path,
      tier: 0,   // SP-1 project-scope tier (0 = scoping inactive); set below, stripped before return
      score: bm25,
      baseScore: bm25,   // frozen pre-boost BM25 (R2.1): boost math + the floor read THIS, never the mutated score
      grounded: groundedCount(queryTokens, indexed[i], dfMap, N),   // head-field term overlap; see KnowledgeSearchResult.grounded
      related: doc.related,
      description: (doc.aiBlock && Object.keys(doc.aiBlock).length)
        ? aiBlockSnippet(doc.type, doc.aiBlock).slice(0, SNIPPET_CHARS)   // shared intermediate, budget-capped
        : (source === 'local-doc'
          ? doc.description
          : (doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim())),
      tokens,
      source,
    };
  });

  // Load the typed relationship graph once: used by BOTH the (opt-in) ranking boost below AND the
  // project-scoping neighbourhood inclusion further down (knowledge_neighbors-style — NOT demoted).
  let graphEdges: CurrentEdge[] = [];
  try {
    const recs = await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
    if (recs.length > 0) {
      const nowIso = new Date().toISOString();
      graphEdges = foldToCurrent(recs).filter(e => validAt(e, nowIso));
    }
  } catch { /* no graph — legacy path below */ }

  // Graph ranking boost — DEMOTED to off-by-default (P7, 2026-06-28). Measured net-zero on the real
  // corpus (6 gold-page ranks improved / 6 degraded / 80 unchanged of 92) while displacing exact
  // title-matches, and it provably cannot improve recall (a zero-base page receives zero boost).
  // The project-scoping neighbourhood + bi-temporal supersedes are unaffected. Opt in: SB_GRAPH_RANKING_BOOST=1.
  const GRAPH_RANKING_BOOST = process.env.SB_GRAPH_RANKING_BOOST === '1' || process.env.SB_GRAPH_RANKING_BOOST === 'true';
  if (!GRAPH_RANKING_BOOST) {
    for (const s of scored) s.score = s.baseScore;
  } else {
  // Graph boost: propagate relevance through the typed relationship graph.
  // R2.1 (MCP-SEARCH-1): contributions are computed from FROZEN pre-boost base
  // scores and accumulated separately, then capped at <=1x each page's own
  // base. The previous in-place `target.score +=` compounded geometrically
  // through hub pages (~10,000x observed live) and corrupted every ranking;
  // a page with zero text relevance can no longer ride the graph at all.
  const GRAPH_BOOST = 0.3;
  const slugScoreMap = new Map(scored.map(s => [slugFromPath(s.path), s]));
  // Keyed by basename slug — slug uniqueness across categories is a wiki
  // invariant (knowledge_validate flags duplicates); a collision would share
  // one accumulator (each page's cap still bounds its own application).
  const boostAccum = new Map<string, number>();
  if (graphEdges.length > 0) {
    // Multi-hop typed propagation (depth 2). requires/affects propagate full,
    // relates much weaker (90% of real graphs are migration-generated relates).
    const TYPE_W: Record<string, number> = { requires: 1, affects: 1, part_of: 0.8, supersedes: 0.6, relates: 0.25 };
    const adj = new Map<string, { to: string; w: number }[]>();
    for (const e of graphEdges) {
      for (const [a, b] of [[e.from, e.to], [e.to, e.from]] as [string, string][]) {
        if (!adj.has(a)) adj.set(a, []);
        adj.get(a)!.push({ to: b, w: TYPE_W[e.type] ?? 0.25 });  // unknown types deliberately get the weakest weight
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
  } // end SB_GRAPH_RANKING_BOOST opt-in block

  // Hybrid search: if ONNX embeddings are available, fuse BM25 + cosine via RRF
  const RRF_K = 60;
  let embeddingsActive = false;
  try {
    const docTexts = allDocs.map(({ doc }) => `${doc.title} ${doc.description} ${doc.body}`.slice(0, 512));
    const docPaths = allDocs.map(({ doc }) => doc.path);
    const allTexts = [args.query, ...docTexts];
    const allPaths = ['', ...docPaths];
    const embeddings = await embedTexts(allTexts, wikiRoot, allPaths);

    if (embeddings) {
      embeddingsActive = true;
      const bm25Only = scored.map(s => s.score);
      const queryVec = embeddings[0];
      const cosineScores = embeddings.slice(1).map(v => cosineSimilarity(queryVec, v));

      const bm25Ranked = scored.map((s, i) => ({ i, score: s.score })).sort((a, b) => b.score - a.score);
      const cosineRanked = cosineScores.map((s, i) => ({ i, score: s })).sort((a, b) => b.score - a.score);

      const rrfScores = new Array(scored.length).fill(0);
      for (let rank = 0; rank < bm25Ranked.length; rank++) {
        rrfScores[bm25Ranked[rank].i] += 1 / (RRF_K + rank + 1);
      }
      for (let rank = 0; rank < cosineRanked.length; rank++) {
        rrfScores[cosineRanked[rank].i] += 1 / (RRF_K + rank + 1);
      }

      for (let i = 0; i < scored.length; i++) {
        scored[i].score = bm25Only[i] > 0
          ? Math.round(rrfScores[i] * 10000) / 10000
          : 0;
      }
    }
  } catch { /* ONNX unavailable — continue with BM25 + graph scores */ }

  // Stub penalty: auto-extracted skeletons and very short pages rank below real content
  for (let i = 0; i < scored.length; i++) {
    if (allDocs[i].source === 'local-doc') continue;
    const { rawContent } = allDocs[i];
    if (AUTO_EXTRACTED_RE.test(rawContent) || indexed[i].strippedBody.trim().length < MIN_SUBSTANTIVE_LENGTH) {
      scored[i].score *= STUB_PENALTY;
    }
  }

  // Recency boost: recently-updated pages get a linear-decay bonus
  const RECENCY_BOOST_MAX = 0.3;
  const RECENCY_WINDOW_DAYS = 90;
  const now = Date.now();
  for (let i = 0; i < scored.length; i++) {
    if (scored[i].score <= 0) continue;
    const dateStr = allDocs[i].doc.updated || allDocs[i].doc.created;
    if (!dateStr) continue;
    const updated = new Date(dateStr).getTime();
    if (isNaN(updated)) continue;
    const daysSince = (now - updated) / (86400000);
    scored[i].score *= 1 + RECENCY_BOOST_MAX * Math.max(0, 1 - daysSince / RECENCY_WINDOW_DAYS);
  }

  // --- SP-1 project-scoped serving (scoped-first, auto-broaden). Pure reorder + filter. ---
  const scopeOn = !!args.projectSlug && process.env.SB_PROJECT_SCOPE !== 'off' && args.scope !== 'all';
  let anchorCount = 0;
  if (scopeOn) {
    const slug = args.projectSlug!;
    // Family = the monorepo root + siblings + self (reads projects.jsonl truth, not the graph).
    // Standalone projects → {slug}, so the family tier collapses to "own project" (today's behavior).
    const family = args.brainDir ? projectFamily(args.brainDir, slug) : new Set<string>([slug]);
    // Map slug→project from WIKI docs only. A local-doc carries project:'' and would
    // otherwise overwrite a same-basename wiki page's real project in this map, leaking
    // that other-project page into scope. local-docs are the active project's own files,
    // so they are tiered directly below instead of via this lookup.
    const projBySlug = new Map(
      allDocs.filter(d => d.source === 'wiki').map(d => [slugFromPath(d.doc.path), d.doc.project ?? '']));
    const anchors = allDocs.filter(d => d.source === 'wiki' && (d.doc.project ?? '') === slug)
      .map(d => slugFromPath(d.doc.path));
    anchorCount = anchors.length;
    const neigh = graphNeighbourhood(anchors, graphEdges, clampEnvInt('SB_SCOPE_HOPS', 2, 0, 4));
    for (const s of scored) {
      if (s.source === 'local-doc') { s.tier = 1; continue; }  // active project's own registry pages
      const sl = slugFromPath(s.path);
      const proj = projBySlug.get(sl) ?? '';
      s.tier = proj === slug ? 1
             : (proj !== '' && family.has(proj)) ? 2   // a family-member project's page
             : neigh.has(sl) ? 3                        // graph-neighbour
             : proj === '' ? 4                          // global
             : 5;                                       // other project
    }
  }

  scored.sort((a, b) => (scopeOn ? (a.tier - b.tier) || (b.score - a.score) : b.score - a.score));
  const topScore = scored.reduce((m, s) => Math.max(m, s.score), 0);
  const topBase = scored.reduce((m, s) => Math.max(m, s.baseScore), 0);
  // R2.1: in BM25-only mode the floor compares FROZEN base scores — the boost
  // can no longer inflate the cutoff and evict honestly-scored pages. RRF
  // scores are rank-derived (inflation-proof), so the floor stays on final
  // scores in hybrid mode.
  const passesFloor = (c: { score: number; baseScore: number }) => embeddingsActive
    ? c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO)
    : c.score > 0 && (topBase === 0 || c.baseScore >= topBase * MIN_SCORE_RATIO);

  let pool = scored;
  if (scopeOn) {
    const inScope = scored.filter(s => s.tier <= 4);
    const inScopePassing = inScope.filter(passesFloor);
    if (inScopePassing.length < clampEnvInt('SB_SCOPE_MIN_HITS', 3, 0, 100)) {
      pool = scored;   // thin in-scope → broaden (keep all; in-scope sorted first)
    } else {
      // CROSS-PROJECT RESERVATION. Enough in-scope hits, so tier-5 is dropped — EXCEPT for
      // pages that outscore EVERY in-scope candidate. Without this, a lesson learned in one
      // repo is unreachable from another: measured live, "ansible replace regexp double
      // substitution" returned the correct page at rank 1 unscoped (0.04152) and NOTHING
      // relevant when scoped to a different project, because the right page was dropped
      // before ranking. Cross-project transfer is the whole reason this is a *second* brain
      // rather than a per-repo README.
      //
      // Why "outscores everything in scope" and not a margin or a plain slot: it is the
      // condition that keeps the existing scoping contract intact. The suppression tests
      // (`C1 local-docs…`, `SP-1 family…`) use fixtures whose other-project page scores
      // EQUAL to the in-scope pages, so a strict > leaves them dropped exactly as before —
      // the rule only fires when the outside page is genuinely better than anything local,
      // which is precisely the case scoping was never meant to hide. A multiplicative margin
      // was rejected: it is a threshold on a mode-dependent scale, the bug class that killed
      // the injection gate (see KnowledgeSearchResult.relevance).
      //
      // Placed FIRST, not appended: consumers take the top 1-2 candidates (persona-context
      // injects 2), so a reserved slot at the tail is the same as no slot at all. Ranking it
      // first is also score-consistent — by construction it beats every in-scope page.
      // Precision is still enforced downstream: the injection CLIs apply the grounding gate
      // to every candidate, reserved or not. SB_SCOPE_CROSS_SLOTS=0 restores the old drop.
      const slots = clampEnvInt('SB_SCOPE_CROSS_SLOTS', 1, 0, TOP_K);
      const bestInScope = inScopePassing.reduce((m, s) => Math.max(m, s.score), 0);
      const cross = slots > 0
        ? scored.filter(s => s.tier === 5 && passesFloor(s) && s.score > bestInScope).slice(0, slots)
        : [];
      pool = cross.length ? [...cross, ...inScopePassing] : inScope;
    }
  }

  const returned = pool.filter(passesFloor).slice(0, TOP_K);
  // Normalize against the max of the RETURNED set (deep-review C1): exactly one
  // returned candidate is always 1; under tier-major (scoped) ordering that
  // anchor may not be the first listed.
  const topFinal = returned.reduce((m, s) => Math.max(m, s.score), 0);
  const candidates = returned
    .map(({ related, baseScore, tier, ...rest }) => ({
      ...rest,
      score_norm: topFinal > 0 ? Math.round((rest.score / topFinal) * 10000) / 10000 : 0,
      // baseScore surfaces as `relevance`: callers gating on relevance need the frozen
      // pre-boost BM25, not the mode-dependent `score` (see the field doc).
      relevance: Math.round(baseScore * 1000) / 1000,
      query_terms: new Set(queryTokens).size,
      ...(scopeOn ? { tier } : {}),
    }));

  // Record access for returned results (fire-and-forget) — telemetry only (see ACCESS_PRUNE_DAYS).
  const accessCounts = await loadAccessCounts();
  const ts = new Date().toISOString();
  for (const c of candidates) {
    if (c.source === 'local-doc') continue;
    const slug = slugFromPath(c.path);
    if (!accessCounts[slug]) accessCounts[slug] = { count: 0, last_accessed: '' };
    accessCounts[slug].count++;
    accessCounts[slug].last_accessed = ts;
  }
  saveAccessCounts(accessCounts).catch(() => {});

  return {
    candidates,
    ...(embeddingsActive ? {} : { degraded: 'bm25-only' as const }),
    // Scoping telemetry: anchors=0 with scoping on means tier-1 anchoring collapsed
    // for this slug (see the interface doc for what that can mean).
    ...(scopeOn ? { scoped_to: args.projectSlug!, anchors: anchorCount } : {}),
  };
}

interface FieldIndex { counts: Map<string, number>; len: number; weight: number }
interface DocIndex { fields: FieldIndex[]; terms: Set<string>; strippedBody: string; bodyLen: number }

function toCounts(s: string): { counts: Map<string, number>; len: number } {
  const toks = tokenize(s);
  const counts = new Map<string, number>();
  for (const t of toks) counts.set(t, (counts.get(t) ?? 0) + 1);
  return { counts, len: toks.length };
}

/** One-pass per-doc index over the same 5 fields/weights scoreBM25 always used. */
function indexDoc(doc: ParsedDoc): DocIndex {
  const strippedBody = stripAiBlock(doc.body);
  const fields = [
    { text: doc.title, weight: 3.0 },
    { text: doc.description, weight: 2.0 },
    { text: doc.tags.join(' '), weight: 2.0 },
    { text: aiBlockText(doc), weight: 1.5 },   // proposition-level shared intermediate
    { text: strippedBody, weight: 1.0 },       // prose body (block excluded → no double-count)
  ].map(({ text, weight }) => ({ ...toCounts(text), weight }));
  const terms = new Set<string>();
  for (const f of fields) for (const t of f.counts.keys()) terms.add(t);
  return { fields, terms, strippedBody, bodyLen: fields[4].len };
}

/** Distinct DISCRIMINATIVE query terms present in the HEAD fields (title/description/tags) —
 *  fields 0-2 of indexDoc's fixed layout.
 *
 *  Body and ai-block are excluded on purpose: a page that merely MENTIONS the terms is not a
 *  page ABOUT them, and that distinction is what an absolute score cannot make.
 *
 *  Common terms are excluded too, and that part is load-bearing: `tokenize` has NO stopword
 *  list, so without this, "best way to grill vegetables" grounds on "best"/"way" and injects a
 *  random page. Discriminativeness is measured by document frequency — corpus-ADAPTIVE, unlike
 *  an absolute BM25 floor, which silently dies on a small wiki (with few docs, df→N, IDF→0 and
 *  every score collapses toward 0 no matter how good the match). The max(2, …) floor keeps
 *  every term usable on a tiny corpus, where a df/N share carries no information.
 *
 *  Cheap: reuses the per-field token counts and the df map the BM25 pass already built. */
function groundedCount(queryTokens: string[], idx: DocIndex, dfMap: Map<string, number>, N: number): number {
  const head = idx.fields.slice(0, 3);
  let n = 0;
  for (const t of discriminativeTerms(queryTokens, dfMap, N)) {
    if (head.some(f => f.counts.has(t))) n++;
  }
  return n;
}

/** The query terms worth grounding on: those NOT occurring corpus-wide.
 *
 *  Corpus-size gated, and above that gate it fails CLOSED.
 *
 *  A df SHARE means nothing on a handful of pages: with N=4 and every page mentioning the query
 *  terms, df=N for all of them, and filtering them all would ground every page at 0 and inject
 *  nothing — the same "gate nothing can satisfy" failure this whole change removes, reached from
 *  the other side. So below MIN_CORPUS_FOR_DF the filter is skipped entirely and grounding falls
 *  back to raw overlap; on a corpus that small, "this term is everywhere" carries no information.
 *
 *  Above the gate there is deliberately NO fallback. An earlier revision returned every term when
 *  the filter emptied the list, and review proved that reopened the precision hole: on a
 *  topically-narrow wiki, a casual prompt made ENTIRELY of connector words ("what is the best way
 *  to…") has every term corpus-common, the fallback handed the filler back, and an off-topic page
 *  grounded on "the"/"way" in its title and was injected. On a corpus large enough to judge,
 *  "every term is common" is itself the signal that the query is filler — ground nothing, inject
 *  nothing. */
function discriminativeTerms(queryTokens: string[], dfMap: Map<string, number>, N: number): string[] {
  // Stopwords first, and independently of corpus size. The df filter alone is not enough:
  // measured on the live 372-page wiki, "what is the best way to do this" still injected an
  // off-topic page, because "best"/"way" appear in perhaps 50 of 372 pages — common in English
  // but nowhere near the corpus SHARE. df catches project jargon that has gone generic; only a
  // stopword list catches words that were never content-bearing to begin with. Grounding only —
  // BM25 itself is untouched, so these words still contribute to ranking as they always did.
  const distinct = [...new Set(queryTokens)].filter(t => !GROUNDING_STOPWORDS.has(t));
  if (N < MIN_CORPUS_FOR_DF) return distinct;
  const maxDf = Math.max(2, N * COMMON_TERM_DF_SHARE);
  return distinct.filter(t => (dfMap.get(t) ?? 0) <= maxDf);
}

function computeDF(queryTokens: string[], docs: DocIndex[]): Map<string, number> {
  const dfMap = new Map<string, number>();
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    let df = 0;
    for (const d of docs) if (d.terms.has(qt)) df++;
    dfMap.set(qt, df);
  }
  return dfMap;
}

function scoreBM25(queryTokens: string[], doc: DocIndex, avgDL: number, N: number, dfMap: Map<string, number>): number {
  let score = 0;
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    const df = dfMap.get(qt) ?? 0;
    const idf = Math.log((N - df + 0.5) / (df + 0.5) + 1);
    for (const field of doc.fields) {
      const tf = field.counts.get(qt) ?? 0;
      if (tf === 0) continue;
      const dl = field.len || 1;
      const tfNorm = (tf * (BM25_K1 + 1)) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / avgDL));
      score += idf * tfNorm * field.weight;
    }
  }
  return Math.round(score * 100) / 100;
}

function tokenize(s: string): string[] {
  return s.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}

function isDateToken(t: string): boolean {
  return DATE_TOKEN_RE.test(t);
}

function slugFromPath(p: string): string {
  return p.replace(/^.*[\\/]/, '').replace(/\.md$/, '');
}
