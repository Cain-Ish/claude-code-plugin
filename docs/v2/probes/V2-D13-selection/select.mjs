// V2-D13: does a lexical ranker, over a map built blind from a repo's own doc files, bring Claude the rules that
// bind a task? `map` reads only the repos and commits of the private config, never its tasks or the cards, so the
// map cannot be fitted to them. Private detail goes next to the config (d13/); only counts come back here.
//   node select.mjs selftest
//   node select.mjs map   <config>           each repo's map at its pinned commit
//   node select.mjs score <config> <cards>   ranks each task's prompt; writes results/summary.json (counts only)
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const MD = /\.(md|mdx|markdown)$/i;
const INSTR = /(^|\/)(CLAUDE|CLAUDE\.local|AGENTS)\.md$|^\.claude\/(rules|skills|commands|agents)\//i;
const CAPS = [2, 4, 8, 16, 32];
const PASS_CAP = 8;
const BLOCK_MAX = 1200;
const STOP = new Set(('a an and are as at be but by can do does for from has have if in into is it its of on or so that ' +
  'the their them then there these this those to was were what when where which who will with you your we our us i ' +
  'me my he she they how why than too very just also').split(' '));

// ---- the map: a repo's doc files split into blocks, each with its source ----

function readDocs(repo, commit) {
  const git = (args, input) => spawnSync('git', ['-c', 'core.longpaths=true', '-C', repo, ...args], { input, maxBuffer: 1 << 30 });
  const paths = git(['ls-tree', '-r', '-z', '--name-only', commit]).stdout.toString('utf8').split('\0').filter((p) => DOC.test(p));
  const buf = git(['cat-file', '--batch'], paths.map((p) => `${commit}:${p}\n`).join('')).stdout;
  const files = {};
  let i = 0;
  for (const p of paths) {
    const nl = buf.indexOf(10, i);
    const [, type, size] = buf.toString('utf8', i, nl).split(' ');
    i = nl + 1;
    if (type !== 'blob') continue;
    files[p] = buf.toString('utf8', i, i + Number(size));
    i += Number(size) + 1;
  }
  return files;
}

const scopeOf = (fm) => {
  const i = fm.findIndex((l) => /^paths:/.test(l));
  if (i < 0) return null;
  const unq = (s) => s.trim().replace(/^["']|["']$/g, '');
  const inline = fm[i].slice(6).trim();
  if (inline) return inline.replace(/^\[|\]$/g, '').split(',').map(unq).filter(Boolean);
  const out = [];
  for (let j = i + 1; j < fm.length && /^\s+-/.test(fm[j]); j++) out.push(unq(fm[j].replace(/^\s+-/, '')));
  return out;
};

const splitBig = (t) => {
  if (Buffer.byteLength(t) <= BLOCK_MAX) return [t];
  const parts = [];
  let cur = '';
  for (const l of t.split('\n')) {
    if (cur && Buffer.byteLength(`${cur}\n${l}`) > BLOCK_MAX) { parts.push(cur); cur = l; } else cur = cur ? `${cur}\n${l}` : l;
  }
  return cur ? [...parts, cur] : parts;
};

// One entry per block: a paragraph, a top-level list item with what is indented under it, a table, a code fence.
export function chunk(file, text) {
  const lines = text.replace(/\r/g, '').split('\n');
  let start = 0;
  let scope = null;
  if (lines[0] === '---') {
    const end = lines.indexOf('---', 1);
    if (end > 0) { scope = scopeOf(lines.slice(1, end)); start = end + 1; }
  }
  const heads = [];
  const out = [];
  let cur = [];
  let fence = null;
  const flush = () => {
    const t = cur.join('\n').trim();
    cur = [];
    if (t) for (const part of splitBig(t)) out.push({ file, heads: heads.filter(Boolean), text: part, scope });
  };
  for (const l of lines.slice(start)) {
    if (fence) { cur.push(l); if (l.trimStart().startsWith(fence)) fence = null; continue; }
    const f = /^\s*(```|~~~)/.exec(l);
    if (f) { cur.push(l); fence = f[1]; continue; }
    const h = MD.test(file) && /^(#{1,6})\s+(.*?)[\s#]*$/.exec(l);
    if (h) {
      flush();
      const lv = h[1].length;
      while (heads.length < lv - 1) heads.push('');
      heads.splice(lv - 1, Infinity, h[2]);
      continue;
    }
    if (!l.trim()) { flush(); continue; }
    if (/^([-*+]|\d+[.)])\s/.test(l)) flush();
    cur.push(l);
  }
  flush();
  return out;
}

// Instruction files plus every doc file they name by path, transitively.
export function pointed(files) {
  const set = new Set(Object.keys(files).filter((p) => INSTR.test(p)));
  const queue = [...set];
  while (queue.length) {
    const p = queue.pop();
    for (const m of files[p].matchAll(/[\w./@~-]+\.(?:md|mdx|markdown|txt|rst)\b/gi)) {
      const ref = m[0].replace(/^@/, '');
      for (const q of [path.posix.normalize(path.posix.join(path.posix.dirname(p), ref)), path.posix.normalize(ref.replace(/^\.?\//, ''))]) {
        if (Object.hasOwn(files, q) && !set.has(q)) { set.add(q); queue.push(q); }
      }
    }
  }
  return set;
}

const dedupe = (entries) => {
  const seen = new Set();
  return entries.filter((e) => {
    const k = e.text.toLowerCase().replace(/\s+/g, ' ');
    return !seen.has(k) && seen.add(k);
  });
};

// ---- the ranker ----

export function tokens(s) {
  const out = [];
  for (const w of String(s).match(/[\p{L}\p{N}]+/gu) ?? []) {
    const parts = w.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').split(' ');
    for (const t of parts.length > 1 ? [w, ...parts] : [w]) {
      let x = t.toLowerCase();
      if (STOP.has(x)) continue;
      if (x.length > 3 && x.endsWith('s')) x = x.slice(0, -1);
      out.push(x);
    }
  }
  return out;
}

export function index(entries) {
  const df = new Map();
  const docs = entries.map((e) => {
    const d = tokens(`${e.file} ${e.heads.join(' ')} ${e.text}`);
    const tf = new Map();
    for (const t of d) tf.set(t, (tf.get(t) ?? 0) + 1);
    for (const t of tf.keys()) df.set(t, (df.get(t) ?? 0) + 1);
    return { tf, len: d.length };
  });
  return { docs, df, avg: docs.reduce((s, d) => s + d.len, 0) / (docs.length || 1) };
}

// BM25, k1 1.2, b 0.75; each distinct prompt term counts once; ties keep corpus order.
export function rank(ix, prompt) {
  const N = ix.docs.length;
  const q = [...new Set(tokens(prompt))];
  return ix.docs.map((d, i) => ({
    i,
    s: q.reduce((s, t) => {
      const f = d.tf.get(t);
      if (!f) return s;
      const n = ix.df.get(t);
      return s + Math.log(1 + (N - n + 0.5) / (n + 0.5)) * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * d.len / ix.avg));
    }, 0),
  })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s || a.i - b.i);
}

export const shown = (e) => `${e.file}${e.heads.length ? ` › ${e.heads.join(' › ')}` : ''}\n${e.text}\n`;

export function deliver(entries, ranked, capKb) {
  let used = 0;
  const out = [];
  for (const { i } of ranked) {
    const b = Buffer.byteLength(shown(entries[i]));
    if (used + b <= capKb * 1024) { used += b; out.push(i); }
  }
  return { out, used };
}

// ---- held: the delivered entries cover >= 80% of a card's word trigrams ----

const words = (s) => s.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const grams = (ws) => ws.slice(2).map((_, i) => `${ws[i]} ${ws[i + 1]} ${ws[i + 2]}`);
export const cardGrams = (text) => new Set(text.split(/…|\.\.\./).flatMap((seg) => grams(words(seg))));
export const entryGrams = (e) => new Set(grams(words(shown(e))));
export function cover(want, sets) {
  let n = 0;
  for (const g of want) if (sets.some((s) => s.has(g))) n++;
  return want.size ? n / want.size : 0;
}

// ---- modes ----

// imported (by a diagnostic) rather than run: no mode
const [mode, cfgArg, cardsArg] = path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url) ? process.argv.slice(2) : ['lib'];
const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex').slice(0, 12);
const repoOf = (t) => t.id.split('-')[0];

if (mode === 'selftest') {
  const md = ['---', 'paths:', '  - "src/**"', '---', '# Top', 'Intro line', 'still intro', '', '## Rules',
    '- first rule', '  - nested under first', '- second rule', '', '```', 'code', '', 'more code', '```', '',
    '#### Deep', 'deep text'].join('\r\n');
  const e = chunk('docs/a.md', md);
  assert.deepEqual(e.map((x) => x.text), ['Intro line\nstill intro', '- first rule\n  - nested under first', '- second rule',
    '```\ncode\n\nmore code\n```', 'deep text']);
  assert.deepEqual(e[1].heads, ['Top', 'Rules']);
  assert.deepEqual(e[4].heads, ['Top', 'Rules', 'Deep']);
  assert.deepEqual(e[0].scope, ['src/**']);
  assert.equal(chunk('a.txt', '# not a heading\nx')[0].heads.length, 0);
  assert.ok(chunk('b.md', Array.from({ length: 60 }, (_, i) => `line ${i} ${'x'.repeat(40)}`).join('\n')).length > 1);
  assert.deepEqual(tokens('HeroChipList hooks the'), ['herochiplist', 'hero', 'chip', 'list', 'hook']);
  const files = { 'CLAUDE.md': 'see @docs/x.md', 'docs/x.md': 'and [y](./y.md#top)', 'docs/y.md': 'end', 'z.md': 'alone' };
  assert.deepEqual([...pointed(files)].sort(), ['CLAUDE.md', 'docs/x.md', 'docs/y.md']);
  const es = [{ file: 'a.md', heads: [], text: 'brain dir must come from lib sh' }, { file: 'b.md', heads: [], text: 'unrelated words' }];
  const r = rank(index(es), 'where is the brain dir');
  assert.deepEqual(r.map((x) => x.i), [0]);
  assert.deepEqual(deliver(es, r, 0.001).out, []);
  assert.equal(cover(cardGrams('brain dir must come … from lib sh'), [entryGrams(es[0])]), 1);
  assert.equal(cover(cardGrams('brain dir must come'), [entryGrams(es[1])]), 0);
  assert.deepEqual(dedupe([{ text: 'A  b' }, { text: 'a b' }]).length, 1);
  console.log('selftest ok');
} else if (mode === 'map') {
  const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
  const out = path.join(path.dirname(path.resolve(cfgArg)), 'd13', 'maps');
  fs.mkdirSync(out, { recursive: true });
  const done = new Set();
  for (const t of cfg.tasks) {
    const label = repoOf(t);
    if (done.has(label)) continue;
    done.add(label);
    const files = readDocs(t.repo, t.commit);
    const pt = pointed(files);
    const all = Object.keys(files).sort().flatMap((p) => chunk(p, files[p]));
    const map = { commit: t.commit, all: dedupe(all), pointed: dedupe(all.filter((e) => pt.has(e.file))) };
    fs.writeFileSync(path.join(out, `${label}.json`), JSON.stringify(map));
    const kb = (es) => Math.round(es.reduce((s, e) => s + Buffer.byteLength(shown(e)), 0) / 1024);
    console.log(`${label}: ${Object.keys(files).length} doc files (${pt.size} pointed); entries all ${map.all.length} (${kb(map.all)} KB), ` +
      `pointed ${map.pointed.length} (${kb(map.pointed)} KB), scoped ${map.all.filter((e) => e.scope).length}`);
  }
} else if (mode === 'score') {
  const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
  const cards = JSON.parse(fs.readFileSync(cardsArg, 'utf8'));
  const dir = path.join(path.dirname(path.resolve(cfgArg)), 'd13');
  const s1 = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'V2-D20-adherence', 'results', 'summary.json'), 'utf8'));
  let inCtx = 0;
  let ruleRuns = 0;
  let allRuns = 0;
  for (const v of Object.values(s1.tasks)) {
    for (const r of Object.values(v.rules)) {
      inCtx += r.inContextBeforeFirstWrite;
      ruleRuns += v.validRuns;
      allRuns += r.inContextBeforeFirstWrite === v.validRuns ? 1 : 0;
    }
  }
  const native = { ruleRunShare: +(inCtx / ruleRuns).toFixed(2), rulesInAllRuns: allRuns };
  const maps = {};
  const sum = { date: new Date().toISOString().slice(0, 10), config: sha(cfgArg), cards: sha(cardsArg), native, maps: {}, tasks: {} };
  const detail = {};
  for (const t of cfg.tasks) {
    const label = repoOf(t);
    maps[label] ??= JSON.parse(fs.readFileSync(path.join(dir, 'maps', `${label}.json`), 'utf8'));
    const m = maps[label];
    const want = Object.entries(cards[t.id]).map(([id, c]) => [id, cardGrams(c.text)]);
    sum.tasks[t.id] = { rules: want.length };
    detail[t.id] = {};
    for (const corpus of ['all', 'pointed']) {
      const es = m[corpus];
      const t0 = performance.now();
      const ix = index(es);
      const t1 = performance.now();
      const ranked = rank(ix, t.prompt);
      const t2 = performance.now();
      const allSets = es.map(entryGrams);
      const res = { buildMs: Math.round(t1 - t0), queryMs: Math.round(t2 - t1), scored: ranked.length, held: {}, bytes: {}, cardBytesShare: {}, perRule: {} };
      for (const [id, g] of want) res.perRule[id] = { wholeCorpus: +cover(g, allSets).toFixed(2), heldAt: [] };
      for (const cap of CAPS) {
        const d = deliver(es, ranked, cap);
        const sets = d.out.map((i) => allSets[i]);
        let held = 0;
        for (const [id, g] of want) if (cover(g, sets) >= 0.8) { held++; res.perRule[id].heldAt.push(cap); }
        // an entry holds part of a card when at least 3 of the card's trigrams occur in it
        const part = d.out.filter((i) => want.some(([, g]) => [...g].filter((x) => allSets[i].has(x)).length >= Math.min(3, g.size)));
        res.held[cap] = held;
        res.bytes[cap] = d.used;
        res.cardBytesShare[cap] = d.used ? +(part.reduce((s, i) => s + Buffer.byteLength(shown(es[i])), 0) / d.used).toFixed(2) : 0;
        if (cap === PASS_CAP) detail[t.id][corpus] = d.out.map((i) => ({ file: es[i].file, heads: es[i].heads, bytes: Buffer.byteLength(shown(es[i])) }));
      }
      sum.tasks[t.id][corpus] = res;
    }
  }
  for (const [label, m] of Object.entries(maps)) {
    const kb = (es) => Math.round(es.reduce((s, e) => s + Buffer.byteLength(shown(e)), 0) / 1024);
    sum.maps[label] = { entries: m.all.length, kb: kb(m.all), pointedEntries: m.pointed.length, pointedKb: kb(m.pointed), scopedEntries: m.all.filter((e) => e.scope).length };
  }
  const tasks = Object.values(sum.tasks);
  const heldAll = tasks.reduce((s, x) => s + x.all.held[PASS_CAP], 0);
  const total = tasks.reduce((s, x) => s + x.rules, 0);
  sum.pass = {
    cap: PASS_CAP,
    perTask: Object.fromEntries(Object.entries(sum.tasks).map(([k, x]) => [k, `${x.all.held[PASS_CAP]}/${x.rules}`])),
    share: +(heldAll / total).toFixed(2),
    passed: tasks.every((x) => x.all.held[PASS_CAP] >= 0.8 * x.rules) && heldAll / total > native.ruleRunShare,
  };
  fs.writeFileSync(path.join(dir, 'delivered.json'), JSON.stringify(detail, null, 1));
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'summary.json'), `${JSON.stringify(sum, null, 1)}\n`);
  console.log(JSON.stringify(sum.pass), '\nheld by cap (all docs):',
    Object.entries(sum.tasks).map(([k, x]) => `${k} ${CAPS.map((c) => x.all.held[c]).join('/')}`).join(' | '));
} else if (mode !== 'lib') {
  console.error('usage: node select.mjs selftest | map <config> | score <config> <cards>');
  process.exit(2);
}
