import { promises as fs } from 'fs';
import { join } from 'path';

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
    first_lines: rawContent.slice(0, SNIPPET_CHARS),
  }));

  scored.sort((a, b) => b.score - a.score);
  return { candidates: scored.filter(c => c.score > 0).slice(0, TOP_K) };
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

async function collectMarkdown(dir: string, acc: string[] = []): Promise<string[]> {
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await collectMarkdown(p, acc);
    else if (e.isFile() && e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
  }
  return acc;
}
