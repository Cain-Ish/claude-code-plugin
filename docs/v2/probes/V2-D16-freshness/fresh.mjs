// V2-D16: does a map entry still say what its source says? Each entry's quote is re-found, word sequence by word
// sequence, in its own file and then in any doc file of the current tree; no model, no git rename detection. The
// three repos' full maps (D15's converter) at their pinned commits are the input; seeded edits act on the doc texts in
// memory. Private detail stays out; only counts come back here (results/).
//   node fresh.mjs selftest
//   node fresh.mjs seeds <config>    9 seed types x 20 per repo -> results/seeds.json
//   node fresh.mjs drift <config>    the scratch clones' current HEAD against the pinned commits -> results/drift.json
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { readDocs } from '../V2-D13-selection/select.mjs';
import { verbatim, sourceText } from '../V2-D15-onboarding/onboard.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PER = 20;
const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const stretches = (q) => q.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3).map((w) => w.join(' '));
const order = (k) => crypto.createHash('sha256').update(`d16${k}`).digest('hex');

// ---- the mechanism ----

export const normOf = (text) => ` ${words(text).join(' ')} `;
export function foundIn(e, norm) {
  return stretches(e.quote).every((st) => norm.includes(` ${st} `)) && (!e.context || norm.includes(` ${words(e.context).join(' ')} `));
}
// current | moved | changed | gone | unverifiable
export function stateOf(e, tree, norms) {
  if (!e.verified) return 'unverifiable';
  if (tree[e.file] !== undefined && foundIn(e, norms(e.file))) return 'current';
  if (Object.keys(tree).some((f) => f !== e.file && foundIn(e, norms(f)))) return 'moved';
  return tree[e.file] !== undefined ? 'changed' : 'gone';
}
const normCache = (tree) => { const c = new Map(); return (f) => (c.has(f) ? c.get(f) : c.set(f, normOf(tree[f])).get(f)); };

// ---- seeds: edits on the source text, in memory ----

// the raw text span of a quote stretch: its words with any non-word characters between them
const spanOf = (text, stretch) => new RegExp(stretch.split(' ').map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^\\p{L}\\p{N}]+'), 'iu').exec(text);
// a negation flip where the quote has one; otherwise "not" goes into the middle
const flip = (s) => (/\bnever\b/i.test(s) ? s.replace(/\bnever\b/i, 'always') : /\balways\b/i.test(s) ? s.replace(/\balways\b/i, 'never')
  : /\bmust\b/i.test(s) ? s.replace(/\bmust\b/i, 'may') : s.replace(/\bnot\s+/i, ''));
const insertNot = (s) => { const ws = s.split(' '); const k = ws.length >> 1; return [...ws.slice(0, k), 'not', ...ws.slice(k)].join(' '); };
const replaceSpan = (tree, file, m, s) => ({ ...tree, [file]: tree[file].slice(0, m.index) + s + tree[file].slice(m.index + m[0].length) });
const renameTo = (tree, file) => { const t = { ...tree }; t[`renamed/${file.split('/').pop()}`] = t[file]; delete t[file]; return t; };

export const SEEDS = {
  // drift: must end changed or gone
  delete: { drift: true, ok: () => true, apply: (t, e) => { const x = { ...t }; delete x[e.file]; return x; } },
  wordChange: { drift: true, ok: () => true, apply: (t, e, m) => { const s = m[0]; const c = /\b(never|always|must|not)\b/i.test(s) ? flip(s) : insertNot(s); return replaceSpan(t, e.file, m, c); } },
  number: { drift: true, ok: (e, m) => /\d/.test(m[0]), apply: (t, e, m) => replaceSpan(t, e.file, m, m[0].replace(/\d+/, (d) => String(Number(d) + 1))) },
  renameEdit: { drift: true, ok: () => true, apply: (t, e, m) => renameTo(replaceSpan(t, e.file, m, insertNot(m[0])), e.file) },
  headerChange: { drift: true, ok: (e) => /^\|/.test(e.context ?? ''), apply: (t, e) => ({ ...t, [e.file]: t[e.file].replace(e.context, e.context.replace(/[\p{L}\p{N}]+/u, (w) => `${w}x`)) }) },
  // controls: must end current or moved
  rename: { drift: false, ok: () => true, apply: (t, e) => renameTo(t, e.file) },
  otherEdit: { drift: false, ok: () => true, apply: (t, e, m) => { const s = t[e.file]; const end = s.indexOf('\n', m.index + m[0].length); const at = end < 0 ? s.length : end; return { ...t, [e.file]: `${s.slice(0, at)}\n\nUnrelated note added in review.${s.slice(at)}` }; } },
  moveBlock: { drift: false, ok: (e, m, t) => !e.context && stretches(e.quote).length === 1, apply: (t, e, m) => { const s = t[e.file]; const a = s.lastIndexOf('\n\n', m.index) + 1; const bEnd = s.indexOf('\n\n', m.index + m[0].length); const b = bEnd < 0 ? s.length : bEnd; return { ...t, [e.file]: `${s.slice(0, a)}${s.slice(b)}\n\n## Moved\n\n${s.slice(a, b).trim()}\n` }; } },
  reformat: { drift: false, ok: (e, m) => m[0].includes(' '), apply: (t, e, m) => replaceSpan(t, e.file, m, m[0].replace(' ', '\n').replace(/([\p{L}]{4,})/u, '**$1**')) },
};

// ---- loading the maps ----

function loadRepo(raw, label, cfg) {
  const all = JSON.parse(fs.readFileSync(path.join(raw, 'd13', 'maps', `${label}.json`), 'utf8')).all;
  const dir = path.join(raw, 'd15', 'full', label);
  const entries = fs.readdirSync(dir).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')))
    .flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file })))
    .map((e) => ({ ...e, verified: verbatim(e.quote, sourceText(all, e.blocks)).ok }));
  const t = cfg.tasks.find((x) => x.id.startsWith(`${label}-`));
  return { entries, repo: t.repo, commit: t.commit, tree: readDocs(t.repo, t.commit) };
}

const [mode, cfgArg] = process.argv.slice(2);
const cfg = cfgArg ? JSON.parse(fs.readFileSync(cfgArg, 'utf8')) : null;
const RAW = cfgArg ? path.dirname(path.resolve(cfgArg)) : null;
const LABELS = cfg ? [...new Set(cfg.tasks.map((t) => t.id.split('-')[0]))] : [];
const write = (name, obj) => { fs.mkdirSync(path.join(HERE, 'results'), { recursive: true }); fs.writeFileSync(path.join(HERE, 'results', name), `${JSON.stringify(obj, null, 1)}\n`); };

if (mode === 'selftest') {
  const tree = { 'a.md': '# A\n\n- Never write to home.\n- Use the shared helper for every path.\n\n| Skill | STR |\n|---|---|\n| Box | 3 |\n', 'b.md': 'other' };
  const e = { file: 'a.md', quote: 'Use the shared helper for every path.', verified: true };
  const n = normCache(tree);
  assert.equal(stateOf(e, tree, n), 'current');
  assert.equal(stateOf({ ...e, verified: false }, tree, n), 'unverifiable');
  const m = spanOf(tree['a.md'], stretches(e.quote)[0]);
  for (const [k, s] of Object.entries(SEEDS)) {
    if (k === 'headerChange' || k === 'number') continue;
    const t2 = s.apply(tree, e, m);
    assert.equal(['changed', 'gone'].includes(stateOf(e, t2, normCache(t2))), s.drift, k);
  }
  const h = { file: 'a.md', quote: 'Box 3', context: '| Skill | STR |', verified: true };
  const t3 = SEEDS.headerChange.apply(tree, h);
  assert.equal(stateOf(h, t3, normCache(t3)), 'changed');
  const neg = { ...e, quote: 'Never write to home.' };
  const t4 = SEEDS.wordChange.apply(tree, neg, spanOf(tree['a.md'], 'never write to home'));
  assert.equal(stateOf(neg, t4, normCache(t4)), 'changed');
  console.log('selftest ok');
} else if (mode === 'seeds') {
  const res = {};
  for (const label of LABELS) {
    const R = loadRepo(RAW, label, cfg);
    const norms = normCache(R.tree);
    const files = Object.keys(R.tree);
    const pool = R.entries.filter((e) => e.verified && R.tree[e.file] !== undefined).sort((a, b) => order(a.quote + a.file).localeCompare(order(b.quote + b.file)));
    const unique = (e) => files.filter((f) => foundIn(e, norms(f))).length === 1 && foundIn(e, norms(e.file));
    res[label] = { entries: R.entries.length, verified: R.entries.filter((e) => e.verified).length, types: {} };
    for (const [k, s] of Object.entries(SEEDS)) {
      let n = 0; let flagged = 0; const states = {};
      for (const e of pool) {
        if (n >= PER) break;
        const m = spanOf(R.tree[e.file], stretches(e.quote)[0] ?? '');
        if (!m || !s.ok(e, m, R.tree) || !unique(e)) continue;
        const t2 = s.apply(R.tree, e, m);
        const st = stateOf(e, t2, normCache(t2));
        states[st] = (states[st] ?? 0) + 1;
        flagged += ['changed', 'gone'].includes(st) ? 1 : 0;
        n++;
      }
      res[label].types[k] = { drift: s.drift, seeds: n, flagged, states, pass: s.drift ? flagged === n && n > 0 : flagged === 0 && n > 0 };
    }
    // unchanged tree: every verified entry current or moved (a tautology given the field) and the sweep time
    const t0 = performance.now();
    const states = {};
    for (const e of R.entries) { const st = stateOf(e, R.tree, normCache(R.tree)); states[st] = (states[st] ?? 0) + 1; }
    const sweepMs = Math.round(performance.now() - t0);
    const sample = R.entries.slice(0, 30);
    const t1 = performance.now();
    const n2 = normCache(R.tree);
    for (const e of sample) stateOf(e, R.tree, n2);
    res[label].unchanged = { states, flagged: (states.changed ?? 0) + (states.gone ?? 0), sweepMs, deliveryCheckMs: +(performance.now() - t1).toFixed(1) };
  }
  const pass = Object.values(res).every((r) => Object.values(r.types).every((t) => t.pass) && r.unchanged.flagged === 0);
  write('seeds.json', { date: new Date().toISOString().slice(0, 10), perType: PER, pass, repos: res });
  console.log(JSON.stringify(Object.fromEntries(Object.entries(res).map(([l, r]) => [l, Object.fromEntries(Object.entries(r.types).map(([k, t]) => [k, `${t.flagged}/${t.seeds}`]))]))), '\nunchanged', JSON.stringify(Object.fromEntries(Object.entries(res).map(([l, r]) => [l, r.unchanged]))), '\npass', pass);
} else if (mode === 'drift') {
  const res = {};
  for (const label of LABELS) {
    const R = loadRepo(RAW, label, cfg);
    const head = (await import('node:child_process')).spawnSync('git', ['-C', R.repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
    const tree = readDocs(R.repo, head);
    const norms = normCache(tree);
    const states = {};
    for (const e of R.entries) { const st = stateOf(e, tree, norms); states[st] = (states[st] ?? 0) + 1; }
    const commits = Number((await import('node:child_process')).spawnSync('git', ['-C', R.repo, 'rev-list', '--count', `${R.commit}..${head}`], { encoding: 'utf8' }).stdout.trim());
    res[label] = { commitsSincePinned: commits, states };
  }
  write('drift.json', { date: new Date().toISOString().slice(0, 10), repos: res });
  console.log(JSON.stringify(res));
} else {
  console.error('usage: node fresh.mjs selftest | seeds <config> | drift <config>');
  process.exit(2);
}
