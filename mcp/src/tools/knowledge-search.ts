import { promises as fs } from 'fs';
import { join } from 'path';

export type Scope = 'concepts' | 'issues' | 'entities' | 'learnings' | 'decisions';
export interface KnowledgeSearchArgs { query: string; scope?: Scope; knowledgeDir?: string; }
export interface KnowledgeSearchResult { candidates: { path: string; score: number; first_lines: string }[]; }

const SNIPPET_CHARS = 200;
const TOP_K = 5;
const FIRST_N_LINES = 10;

export async function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult> {
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
  const wikiRoot = join(knowledgeDir, 'wiki');
  const scopeDirs = args.scope
    ? [join(wikiRoot, args.scope)]
    : (['concepts','issues','entities','learnings','decisions'] as Scope[]).map(s => join(wikiRoot, s));

  const queryTokens = tokenize(args.query);
  const candidates: KnowledgeSearchResult['candidates'] = [];

  for (const dir of scopeDirs) {
    let entries: string[] = [];
    try { entries = await collectMarkdown(dir); } catch { continue; }
    for (const path of entries) {
      const head = await firstLines(path, FIRST_N_LINES);
      const score = scoreTokens(queryTokens, head + ' ' + path);
      if (score > 0) candidates.push({ path, score, first_lines: head.slice(0, SNIPPET_CHARS) });
    }
  }
  candidates.sort((a, b) => b.score - a.score);
  return { candidates: candidates.slice(0, TOP_K) };
}

function tokenize(s: string): string[] { return s.toLowerCase().match(/[a-z0-9]+/g) ?? []; }
function scoreTokens(query: string[], text: string): number {
  const t = new Set(tokenize(text));
  return query.filter(q => t.has(q)).length;
}
async function collectMarkdown(dir: string, acc: string[] = []): Promise<string[]> {
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await collectMarkdown(p, acc);
    else if (e.isFile() && e.name.endsWith('.md')) acc.push(p.split(/[\\/]/).join('/'));
  }
  return acc;
}
async function firstLines(path: string, n: number): Promise<string> {
  const content = await fs.readFile(path, 'utf-8');
  return content.split('\n').slice(0, n).join('\n');
}
