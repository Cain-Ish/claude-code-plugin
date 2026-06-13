import { promises as fs } from 'fs';
import { atomicWriteJson } from './atomic-write.js';
import { join } from 'path';
import { embedTexts, cosineSimilarity } from './embeddings.js';
import { estimateTokens } from './egress-budget.js';
import { loadRegistry } from './doc-sources.js';
import { loadEdges, foldToCurrent, validAt, CurrentEdge } from './graph-store.js';
import { parseAiBlock, stripAiBlock, aiBlockSnippet } from './ai-block.js';

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
     *  (tier-major ordering) that anchor may not be the first listed. */
    score_norm: number;
    /** SP-1 project-scope tier (1=active project … 4=other project). Present only when scoping is active. */
    tier?: number;
    description: string;
    tokens: number;
    source: string;
  }[];
  /** Present when ONNX embeddings were unavailable — ranking fell back to BM25(+graph) only (R2.3). */
  degraded?: 'bm25-only';
}

export interface ParsedDoc {
  title: string;
  description: string;
  type: string;
  tags: string[];
  related: string[];
  body: string;
  path: string;
  updated: string;
  created: string;
  project: string;
  area: string;
  aiBlock?: Record<string, string>;
}

interface AccessCounts { [slug: string]: { count: number; last_accessed: string } }
// R2.2 hermeticity: resolved per-call from SB_BRAIN_DIR/BRAIN_DIR (matching the
// server + embeddings conventions), NOT hardcoded to $HOME — eval/test runs were
// reading the LIVE access counts into their rankings AND writing fixture slugs
// back into the user's real state, making the "deterministic" recall gate
// flip-flop run-to-run.
function accessCountsFile(): string {
  const brain = process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR || join(process.env.HOME ?? '', '.second-brain');
  return join(brain, 'access-counts.json');
}
const ACCESS_BOOST_FACTOR = 0.1;
const ACCESS_BOOST_CAP = 10;
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
const MIN_SUBSTANTIVE_LENGTH = 100;
const AUTO_EXTRACTED_RE = /<!--\s*auto-extracted/;

export async function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult> {
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
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
    let paths: string[] = [];
    try { paths = await collectMarkdown(dir); } catch { continue; }
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

  const avgDL = allDocs.reduce((sum, { doc }) => sum + tokenize(stripAiBlock(doc.body)).length, 0) / allDocs.length || AVG_DOC_LENGTH;

  const N = allDocs.length;
  const dfMap = computeDF(queryTokens, allDocs.map(({ doc }) => doc));

  const scored = allDocs.map(({ doc, rawContent, source, tokens }) => {
    const bm25 = scoreBM25(queryTokens, doc, avgDL, N, dfMap);
    return {
      path: doc.path,
      tier: 0,   // SP-1 project-scope tier (0 = scoping inactive); set below, stripped before return
      score: bm25,
      baseScore: bm25,   // frozen pre-boost BM25 (R2.1): boost math + the floor read THIS, never the mutated score
      related: doc.related,
      description: (doc.aiBlock && Object.keys(doc.aiBlock).length)
        ? aiBlockSnippet(doc.type, doc.aiBlock).slice(0, SNIPPET_CHARS)   // shared intermediate, budget-capped (Phase 2)
        : (source === 'local-doc'
          ? doc.description
          : (doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim())),
      tokens,
      source,
    };
  });

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
    const { doc, rawContent } = allDocs[i];
    if (AUTO_EXTRACTED_RE.test(rawContent) || stripAiBlock(doc.body).trim().length < MIN_SUBSTANTIVE_LENGTH) {
      scored[i].score *= STUB_PENALTY;
    }
  }

  // Access frequency boost: pages retrieved often get a minor relevance bump
  const accessCounts = await loadAccessCounts();
  for (let i = 0; i < scored.length; i++) {
    if (scored[i].score <= 0) continue;
    const slug = slugFromPath(scored[i].path);
    const ac = accessCounts[slug];
    if (ac) {
      scored[i].score *= 1 + ACCESS_BOOST_FACTOR * Math.min(ac.count, ACCESS_BOOST_CAP);
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
  if (scopeOn) {
    const slug = args.projectSlug!;
    // Map slug→project from WIKI docs only. A local-doc carries project:'' and would
    // otherwise overwrite a same-basename wiki page's real project in this map, leaking
    // that other-project page into scope. local-docs are the active project's own files,
    // so they are tiered directly below instead of via this lookup.
    const projBySlug = new Map(
      allDocs.filter(d => d.source === 'wiki').map(d => [slugFromPath(d.doc.path), d.doc.project ?? '']));
    const anchors = allDocs.filter(d => d.source === 'wiki' && (d.doc.project ?? '') === slug)
      .map(d => slugFromPath(d.doc.path));
    const neigh = graphNeighbourhood(anchors, graphEdges, clampEnvInt('SB_SCOPE_HOPS', 2, 0, 4));
    for (const s of scored) {
      if (s.source === 'local-doc') { s.tier = 1; continue; }  // active project's own registry pages
      const sl = slugFromPath(s.path);
      const proj = projBySlug.get(sl) ?? '';
      s.tier = proj === slug ? 1 : neigh.has(sl) ? 2 : proj === '' ? 3 : 4;
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
    const inScope = scored.filter(s => s.tier <= 3);
    // Enough in-scope hits → drop other-project (tier 4). Thin → broaden (keep all; in-scope sorted first).
    pool = inScope.filter(passesFloor).length >= clampEnvInt('SB_SCOPE_MIN_HITS', 3, 0, 100) ? inScope : scored;
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
      ...(scopeOn ? { tier } : {}),
    }));

  // Record access for returned results (fire-and-forget)
  const ts = new Date().toISOString();
  for (const c of candidates) {
    if (c.source === 'local-doc') continue;
    const slug = slugFromPath(c.path);
    if (!accessCounts[slug]) accessCounts[slug] = { count: 0, last_accessed: '' };
    accessCounts[slug].count++;
    accessCounts[slug].last_accessed = ts;
  }
  saveAccessCounts(accessCounts).catch(() => {});

  return { candidates, ...(embeddingsActive ? {} : { degraded: 'bm25-only' as const }) };
}

function computeDF(queryTokens: string[], docs: ParsedDoc[]): Map<string, number> {
  const dfMap = new Map<string, number>();
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    let df = 0;
    for (const doc of docs) {
      const allTokens = [
        ...tokenize(doc.title), ...tokenize(doc.description),
        ...tokenize(doc.tags.join(' ')), ...tokenize(stripAiBlock(doc.body)), ...tokenize(aiBlockText(doc)),
      ];
      if (allTokens.includes(qt)) df++;
    }
    dfMap.set(qt, df);
  }
  return dfMap;
}

function scoreBM25(queryTokens: string[], doc: ParsedDoc, avgDL: number, N: number, dfMap: Map<string, number>): number {
  const fields = [
    { tokens: tokenize(doc.title), weight: 3.0 },
    { tokens: tokenize(doc.description), weight: 2.0 },
    { tokens: tokenize(doc.tags.join(' ')), weight: 2.0 },
    { tokens: tokenize(aiBlockText(doc)), weight: 1.5 },          // proposition-level shared intermediate
    { tokens: tokenize(stripAiBlock(doc.body)), weight: 1.0 },    // prose body (block excluded → no double-count)
  ];

  let score = 0;
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    const df = dfMap.get(qt) ?? 0;
    const idf = Math.log((N - df + 0.5) / (df + 0.5) + 1);
    for (const field of fields) {
      const tf = field.tokens.filter(t => t === qt).length;
      if (tf === 0) continue;
      const dl = field.tokens.length || 1;
      const tfNorm = (tf * (BM25_K1 + 1)) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / avgDL));
      score += idf * tfNorm * field.weight;
    }
  }
  return Math.round(score * 100) / 100;
}

export function parseDoc(content: string, filePath: string): ParsedDoc {
  const doc: ParsedDoc = {
    title: '', description: '', type: '', tags: [], related: [], body: content, path: filePath,
    updated: '', created: '', project: '', area: '',
  };

  let hasRelatedKey = false;   // P1: distinguish an explicit `related: []` from an ABSENT key
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fmMatch) {
    const fm = fmMatch[1];
    doc.body = fmMatch[2];
    doc.title = extractYamlValue(fm, 'title');
    doc.description = extractYamlValue(fm, 'description');
    doc.type = extractYamlValue(fm, 'type');
    doc.tags = extractYamlList(fm, 'tags');
    doc.related = extractYamlList(fm, 'related');
    hasRelatedKey = /^related:/m.test(fm);
    doc.updated = extractYamlValue(fm, 'updated');
    doc.created = extractYamlValue(fm, 'created');
    doc.project = extractYamlValue(fm, 'project');
    doc.area = extractYamlValue(fm, 'area');
  }

  if (!doc.title) {
    const headingMatch = doc.body.match(/^#\s+(.+)/m);
    if (headingMatch) doc.title = headingMatch[1].trim();
  }

  if (!doc.type) {
    const rel = filePath.split('/');
    const wikiIdx = rel.lastIndexOf('wiki');
    if (wikiIdx >= 0 && wikiIdx + 1 < rel.length) {
      doc.type = rel[wikiIdx + 1];
    }
  }

  doc.aiBlock = parseAiBlock(content) ?? undefined;

  if (!hasRelatedKey) {
    // P1: scrape body [[links]] ONLY when the related: KEY is ABSENT — an explicit
    // `related: []` is authoritative (it is the projector's canonical cleaned form
    // for an edgeless page; re-filling it from body links would resurrect false
    // related_drift + phantom boosts on exactly the pages the projector just cleaned).
    // Strip the ai-block first (block values are plain slugs; a stray bracket there
    // must not pollute related:).
    const wikiLinks = stripAiBlock(doc.body).match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map(l => l.slice(2, -2)))];
    }
  }

  return doc;
}

export function extractYamlValue(yaml: string, key: string): string {
  // `(.*?)` not `(.+?)`: an empty quoted value `key: ""` must parse to '' — with
  // `.+?` the opening quote is eaten by `['"]?` and the closing quote becomes the
  // captured value (`"`), which then leaks into MOC descriptions and breaks reindex
  // idempotency once a page carries `description: ""`.
  const re = new RegExp(`^${key}:\\s*['"]?(.*?)['"]?\\s*$`, 'm');
  const m = yaml.match(re);
  return m ? m[1].trim() : '';
}

export function extractYamlList(yaml: string, key: string): string[] {
  // The wiki uses a non-standard `related: [[slug]], [[other]]` convention for
  // wiki-links in frontmatter. The naive `^key:\s*\[(.+?)\]` regex misparses
  // these as YAML inline lists, capturing `[slug` (with leading bracket) and
  // breaking every link-validity check. Detect the wikilink convention first
  // and extract `[[slug]]` tokens directly; only fall through to the standard
  // YAML inline / block parsers if no wikilinks are present on the line.
  const lineMatch = yaml.match(new RegExp(`^${key}:[ \\t]+(\\S.*?)\\s*$`, 'm'));
  if (lineMatch) {
    const value = lineMatch[1];
    const wikiLinks = value.match(/\[\[([^\]\[]+)\]\]/g);
    if (wikiLinks && wikiLinks.length > 0) {
      return [...new Set(
        wikiLinks.map(l => l.slice(2, -2).trim()).filter(Boolean)
      )];
    }
  }
  const inline = yaml.match(new RegExp(`^${key}:\\s*\\[(.+?)\\]`, 'm'));
  if (inline) {
    return inline[1].split(',').map(s => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  }
  const items: string[] = [];
  const lines = yaml.split('\n');
  let collecting = false;
  for (const line of lines) {
    if (line.match(new RegExp(`^${key}:`))) { collecting = true; continue; }
    if (collecting) {
      const itemMatch = line.match(/^\s+-\s+(.+)/);
      if (itemMatch) { items.push(itemMatch[1].trim().replace(/^['"]|['"]$/g, '')); }
      else { collecting = false; }
    }
  }
  return items;
}

function tokenize(s: string): string[] {
  return s.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}

function isDateToken(t: string): boolean {
  return DATE_TOKEN_RE.test(t);
}

function slugFromPath(p: string): string {
  return p.replace(/.*\//, '').replace(/\.md$/, '');
}

async function collectMarkdown(dir: string, acc: string[] = []): Promise<string[]> {
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await collectMarkdown(p, acc);
    else if (e.isFile() && e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
  }
  return acc;
}
