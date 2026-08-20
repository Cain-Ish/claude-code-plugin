import { it } from 'vitest';
import { readFileSync } from 'fs';
import { knowledgeSearch } from './knowledge-search.js';
const REAL = ['jq windows crlf stdout','dream accept guards','bm25 rrf fusion ranking','symlink guard denies writes into ssh','pagerank code map token budget','ansible replace regexp multiline','how does the drainer defer under oauth'];
const JUNK = ['banana smoothie recipe','olympic swimming lane etiquette','what colour is the sky today','xyzzy plugh frotz','my cat keeps knocking things off the table','best way to grill vegetables'];
const STOP = new Set(['the','a','an','is','how','does','what','to','of','in','on','my','best','way','keeps','things','off','it','and','under','into']);
const toks = (s: string) => s.toLowerCase().match(/[a-z0-9]+/g)?.filter(t => t.length > 2 && !STOP.has(t)) ?? [];
it('gate designs', async () => {
  const row = async (q: string, label: string) => {
    const r: any = await knowledgeSearch({ query: q, knowledgeDir: 'C:/Users/curst/knowledge', brainDir: process.env.BRAIN_DIR!, projectSlug: 'claude-code-plugin' });
    const c = r.candidates[0];
    if (!c) { console.log(label, 'NOHIT  overlap=-  ratio=-  |', q); return; }
    const raw = readFileSync(c.path, 'utf8');
    const fm = raw.slice(0, raw.indexOf('---', 3));
    const head = (fm.match(/^(title|description|tags):.*$/gmi) ?? []).join(' ').toLowerCase();
    const qt = toks(q);
    const hit = qt.filter(t => head.includes(t));
    const scores = r.candidates.map((x: any) => x.score).sort((a: number, b: number) => b - a);
    const med = scores[Math.floor(scores.length / 2)] ?? 0;
    const ratio = med > 0 ? c.score / med : 99;
    console.log(label, `overlap=${hit.length}/${qt.length}`, `ratio=${ratio.toFixed(2)}`, '|', q, '->', c.path.replace(/^.*[\/]/, ''));
  };
  for (const q of REAL) await row(q, 'REAL');
  for (const q of JUNK) await row(q, 'JUNK');
}, 300000);
