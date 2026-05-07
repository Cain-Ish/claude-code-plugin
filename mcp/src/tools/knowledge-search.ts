import { promises as fs } from 'fs';
import { join } from 'path';
import { embedTexts, cosineSimilarity } from './embeddings.js';

export interface KnowledgeSearchArgs { query: string; scope?: string; knowledgeDir?: string; }
export interface KnowledgeSearchResult { candidates: { path: string; score: number; first_lines: string }[]; }

export interface ParsedDoc {
  title: string;
  description: string;
  type: string;
  tags: string[];
  related: string[];
  body: string;
  path: string;
}

const TOP_K = 8;
const SNIPPET_CHARS = 300;
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
  if (args.scope) {
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

  const allDocs: { doc: ParsedDoc; rawContent: string }[] = [];

  for (const dir of scopeDirs) {
    let paths: string[] = [];
    try { paths = await collectMarkdown(dir); } catch { continue; }
    for (const filePath of paths) {
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const doc = parseDoc(content, filePath);
        allDocs.push({ doc, rawContent: content });
      } catch { continue; }
    }
  }

  if (allDocs.length === 0) return { candidates: [] };

  const avgDL = allDocs.reduce((sum, { doc }) => sum + tokenize(doc.body).length, 0) / allDocs.length || AVG_DOC_LENGTH;

  const scored = allDocs.map(({ doc, rawContent }) => ({
    path: doc.path,
    score: scoreBM25(queryTokens, doc, avgDL),
    related: doc.related,
    first_lines: rawContent.slice(0, SNIPPET_CHARS),
  }));

  // Graph boost: pages referenced by high-scoring pages get a relevance bump
  const slugScoreMap = new Map(scored.map(s => [slugFromPath(s.path), s]));
  const GRAPH_BOOST = 0.3;
  for (const entry of scored) {
    if (entry.score <= 0) continue;
    for (const rel of entry.related) {
      const target = slugScoreMap.get(rel);
      if (target && target !== entry) {
        target.score += entry.score * GRAPH_BOOST;
      }
    }
  }

  // Hybrid search: if ONNX embeddings are available, fuse BM25 + cosine via RRF
  const RRF_K = 60;
  try {
    const docTexts = allDocs.map(({ doc }) => `${doc.title} ${doc.description} ${doc.body}`.slice(0, 512));
    const docPaths = allDocs.map(({ doc }) => doc.path);
    const allTexts = [args.query, ...docTexts];
    const allPaths = ['', ...docPaths];
    const embeddings = await embedTexts(allTexts, wikiRoot, allPaths);

    if (embeddings) {
      const queryVec = embeddings[0];
      const cosineScores = embeddings.slice(1).map(v => cosineSimilarity(queryVec, v));

      // Build RRF ranks
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
        scored[i].score = Math.round(rrfScores[i] * 10000) / 10000;
      }
    }
  } catch { /* ONNX unavailable — continue with BM25 + graph scores */ }

  // Stub penalty: auto-extracted skeletons and very short pages rank below real content
  for (let i = 0; i < scored.length; i++) {
    const { doc, rawContent } = allDocs[i];
    if (AUTO_EXTRACTED_RE.test(rawContent) || doc.body.trim().length < MIN_SUBSTANTIVE_LENGTH) {
      scored[i].score *= STUB_PENALTY;
    }
  }

  scored.sort((a, b) => b.score - a.score);
  const topScore = scored[0]?.score ?? 0;
  return {
    candidates: scored
      .filter(c => c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO))
      .slice(0, TOP_K)
      .map(({ related, ...rest }) => rest),
  };
}

function scoreBM25(queryTokens: string[], doc: ParsedDoc, avgDL: number): number {
  const fields = [
    { tokens: tokenize(doc.title), weight: 3.0 },
    { tokens: tokenize(doc.description), weight: 2.0 },
    { tokens: tokenize(doc.tags.join(' ')), weight: 2.0 },
    { tokens: tokenize(doc.body), weight: 1.0 },
  ];

  let score = 0;
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    for (const field of fields) {
      const tf = field.tokens.filter(t => t === qt).length;
      if (tf === 0) continue;
      const dl = field.tokens.length || 1;
      const tfNorm = (tf * (BM25_K1 + 1)) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / avgDL));
      score += tfNorm * field.weight;
    }
  }
  return Math.round(score * 100) / 100;
}

export function parseDoc(content: string, filePath: string): ParsedDoc {
  const doc: ParsedDoc = {
    title: '', description: '', type: '', tags: [], related: [], body: content, path: filePath,
  };

  const fmMatch = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fmMatch) {
    const fm = fmMatch[1];
    doc.body = fmMatch[2];
    doc.title = extractYamlValue(fm, 'title');
    doc.description = extractYamlValue(fm, 'description');
    doc.type = extractYamlValue(fm, 'type');
    doc.tags = extractYamlList(fm, 'tags');
    doc.related = extractYamlList(fm, 'related');
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

  if (doc.related.length === 0) {
    const wikiLinks = doc.body.match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map(l => l.slice(2, -2)))];
    }
  }

  return doc;
}

function extractYamlValue(yaml: string, key: string): string {
  const re = new RegExp(`^${key}:\\s*['"]?(.+?)['"]?\\s*$`, 'm');
  const m = yaml.match(re);
  return m ? m[1].trim() : '';
}

function extractYamlList(yaml: string, key: string): string[] {
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
