// V2-D22: which entries of a repo's map reach Claude for a task, within 8 KB, without a hand-made list? Three
// prompt-time arms over the full map (D15's converter), graded by a blind judge from a pooled set. Tasks, maps,
// deliveries, pools and grades stay next to the private tasks file (d22/); only counts come back here (results/).
//   node route.mjs selftest
//   node route.mjs arms   <tasks> [task-id]   (b), (d1), (d2) per task -> d22/arms/<task>.json
//   node route.mjs index  <tasks>             each repo's section index for the judges -> d22/index-<repo>.txt
//   node route.mjs pool   <tasks> <task-id>   after the judge's step 1: pooled entries, shuffled -> d22/pool-<task>.txt
//   node route.mjs native <tasks>             a D20-harness config for the native runs -> d22/native.json
//   node route.mjs score  <tasks>             grades, arms and native runs -> results/summary.json (counts only)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { index, rank, deliver } from '../V2-D13-selection/select.mjs';
import { tokensOf, keyedFor } from './keys.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CAP = 8;
const N = 300;
const MAX_SECTIONS = 20;
const MODEL = 'claude-sonnet-5-5';
export const PICK = `You select, from a project's map, the entries that someone doing the given task must follow or must know
to do it right. Input: the task, then candidate entries, one per line: [id] source | area | applies-when | text.
Output: only a JSON array of ids, most important first, no prose, no code fence. Include every entry that binds the
task and leave out the rest. If none binds, give [].`;
export const SECT = `You choose where in a project's documentation the knowledge for a task lives. Input: the task, then the
documentation's sections, one per line: [n] file › heading › subheading. Output: only a JSON array of at most ${MAX_SECTIONS}
section numbers, most relevant first, no prose, no code fence.`;
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex').slice(0, 12);

// ---- the map ----

export const shown = (e) => `${e.file}${e.heads.length ? ` › ${e.heads.join(' › ')}` : ''}\n${e.context ? `${e.context}\n` : ''}${e.quote}\n`;
export const compact = (e) => `[${e.n}] ${[e.file, ...e.heads.slice(0, 2)].join(' › ')} | ${e.area} | ${e.when.join('; ')} | ${e.context ? `${e.context} ` : ''}${e.quote.replace(/\s+/g, ' ').slice(0, 160)}`;
export const sectionKey = (file, heads) => [file, ...heads.slice(0, 2)].join(' › ');

function loadMap(raw, label) {
  const all = JSON.parse(fs.readFileSync(path.join(raw, 'd13', 'maps', `${label}.json`), 'utf8')).all;
  const dir = path.join(raw, 'd15', 'full', label);
  const runs = fs.readdirSync(dir).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')))
    .sort((a, b) => a.blocksIn[0] - b.blocksIn[0]);
  const entries = runs.flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file, heads: all[x.blocks[0]].heads })))
    .map((e, n) => ({ ...e, n }));
  const keys = [...new Set(all.map((b) => sectionKey(b.file, b.heads)))];
  return { all, entries, keys, runs };
}

// ---- the model call ----

// The first JSON array in a reply, matched bracket by bracket: a note after the array must not join it.
export function firstArray(s) {
  const i = s.indexOf('[');
  let depth = 0;
  for (let j = i; i >= 0 && j < s.length; j++) {
    if (s[j] === '[') depth++;
    else if (s[j] === ']' && --depth === 0) return s.slice(i, j + 1);
  }
  return '[]';
}

const claude = (sys, input) => new Promise((resolve) => {
  const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const t0 = Date.now();
  const p = spawn('claude', ['-p', '--model', MODEL, '--output-format', 'json', '--system-prompt', sys, '--tools', '',
    '--setting-sources', 'project', '--strict-mcp-config', '--no-session-persistence'], { cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'd22-')), env });
  let out = '';
  p.stdout.on('data', (d) => { out += d; });
  p.on('close', () => {
    try {
      const o = JSON.parse(out);
      const ids = JSON.parse(firstArray(String(o.result))).map(Number).filter(Number.isInteger);
      resolve({ ids, ms: Date.now() - t0, cost: o.total_cost_usd, tokens: (o.usage?.input_tokens ?? 0) + (o.usage?.cache_read_input_tokens ?? 0) + (o.usage?.cache_creation_input_tokens ?? 0) + (o.usage?.output_tokens ?? 0) });
    } catch (e) {
      resolve({ ids: [], ms: Date.now() - t0, cost: null, tokens: null, error: String(e).slice(0, 200) });
    }
  });
  p.stdin.end(input);
});

// ---- the arms ----

const take = (entries, order) => {
  const valid = [...new Set(order)].filter((n) => entries[n]);
  return deliver(entries.map((e) => ({ file: e.file, heads: e.heads, text: `${e.context ? `${e.context}\n` : ''}${e.quote}` })), valid.map((i) => ({ i })), CAP);
};

export async function arms(map, prompt, only = null) {
  const { entries, keys } = map;
  const t0 = performance.now();
  const ix = index(entries.map((e) => ({ file: e.file, heads: e.heads, text: `${e.area} ${e.when.join(' ')} ${e.context ?? ''} ${e.quote}` })));
  const buildMs = Math.round(performance.now() - t0);
  const t1 = performance.now();
  const ranked = rank(ix, prompt).map((r) => r.i);
  const b = take(entries, ranked);
  const bMs = Math.round(performance.now() - t1);

  const cand = ranked.slice(0, N);
  // only = 'd2': rerun that arm alone after a harness failure (the other arms' saved results stand)
  const p1 = only === 'd2' ? { ids: [], ms: 0 } : await claude(PICK, `Task: ${prompt}\n\nCandidate entries:\n${cand.map((i) => compact(entries[i])).join('\n')}`);
  const d1 = take(entries, p1.ids.filter((i) => cand.includes(i)));

  const s = await claude(SECT, `Task: ${prompt}\n\nSections:\n${keys.map((k, n) => `[${n}] ${k}`).join('\n')}`);
  const picked = new Set(s.ids.slice(0, MAX_SECTIONS).map((n) => keys[n]).filter(Boolean));
  const inSec = entries.filter((e) => picked.has(sectionKey(e.file, e.heads))).map((e) => e.n);
  const p2 = inSec.length ? await claude(PICK, `Task: ${prompt}\n\nCandidate entries:\n${inSec.map((i) => compact(entries[i])).join('\n')}`) : { ids: [], ms: 0, cost: 0, tokens: 0 };
  const d2 = take(entries, p2.ids.filter((i) => inSec.includes(i)));
  const sum = (...c) => c.reduce((t, x) => t + (x ?? 0), 0);
  return {
    buildMs,
    b: { ids: b.out, bytes: b.used, ms: bMs, calls: 0 },
    d1: { ids: d1.out, bytes: d1.used, ms: p1.ms, calls: 1, cost: p1.cost, tokens: p1.tokens, picked: p1.ids.length, error: p1.error },
    d2: { ids: d2.out, bytes: d2.used, ms: s.ms + p2.ms, calls: 2, cost: sum(s.cost, p2.cost), tokens: sum(s.tokens, p2.tokens),
      sections: [...picked], candidates: inSec.length, picked: p2.ids.length, error: s.error ?? p2.error },
  };
}

// ---- modes ----

const [mode, tasksArg, taskId] = process.argv.slice(2);
const ARM = process.argv.find((a) => /^--arm=/.test(a))?.slice(6) ?? 'r';
const TASKS = tasksArg ? JSON.parse(fs.readFileSync(tasksArg, 'utf8')).tasks : [];
const D22 = tasksArg ? path.dirname(path.resolve(tasksArg)) : null;
const RAW = D22 ? path.dirname(D22) : null;
const maps = {};
const mapOf = (label) => (maps[label] ??= loadMap(RAW, label));
const shuffle = (xs, seed) => [...xs].sort((a, b) => sha(`${seed}${a}`).localeCompare(sha(`${seed}${b}`)));

if (mode === 'selftest') {
  const es = [{ file: 'a.md', heads: ['A', 'B', 'C'], area: 'x', when: ['w'], quote: 'q '.repeat(10), n: 0 }, { file: 'a.md', heads: [], area: 'y', when: [], context: '| H |', quote: 'r', n: 1 }];
  assert.match(compact(es[0]), /^\[0\] a\.md › A › B \| x \| w \| q q/);
  assert.equal(shown(es[1]), 'a.md\n| H |\nr\n');
  assert.deepEqual(take(es, [1, 1, 0, 9]).out, [1, 0]);
  assert.deepEqual(shuffle([1, 2, 3], 's'), shuffle([3, 2, 1], 's'));
  assert.equal(firstArray('```json\n[1, [2], 3]\n```\nNote: see [4]'), '[1, [2], 3]');
  console.log('selftest ok', 'pick', sha(PICK), 'sect', sha(SECT));
} else if (mode === 'arms') {
  fs.mkdirSync(path.join(D22, 'arms'), { recursive: true });
  const only = process.argv[5] ?? null;
  for (const t of TASKS.filter((x) => !taskId || x.id === taskId)) {
    const file = path.join(D22, 'arms', `${t.id}.json`);
    let r = await arms(mapOf(t.repo), t.prompt, only);
    if (only) r = { ...JSON.parse(fs.readFileSync(file, 'utf8')), [only]: { ...r[only], rerun: 'after a harness parse failure' } };
    fs.writeFileSync(file, JSON.stringify(r));
    console.log(t.id, ['b', 'd1', 'd2'].map((a) => `${a}: ${r[a].ids.length} entries ${Math.round(r[a].bytes / 1024)} KB ${r[a].ms} ms${r[a].error ? ' ERROR' : ''}`).join(' | '));
  }
} else if (mode === 'index') {
  // the index needs only the document blocks, not the converted entries
  for (const label of [...new Set(TASKS.map((t) => t.repo))]) {
    const all = JSON.parse(fs.readFileSync(path.join(RAW, 'd13', 'maps', `${label}.json`), 'utf8')).all;
    const keys = [...new Set(all.map((b) => sectionKey(b.file, b.heads)))];
    fs.writeFileSync(path.join(D22, `index-${label}.txt`), keys.map((k, n) => `[${n}] ${k}`).join('\n'));
    console.log(label, keys.length, 'sections');
  }
} else if (mode === 'pool') {
  const t = TASKS.find((x) => x.id === taskId);
  const { entries, keys } = mapOf(t.repo);
  const deep = JSON.parse(fs.readFileSync(path.join(D22, 'judge', `${t.id}-sections.json`), 'utf8')).map(Number);
  const deepKeys = new Set(deep.map((n) => keys[n]).filter(Boolean));
  const deepIds = entries.filter((e) => deepKeys.has(sectionKey(e.file, e.heads))).map((e) => e.n);
  const a = JSON.parse(fs.readFileSync(path.join(D22, 'arms', `${t.id}.json`), 'utf8'));
  const ids = shuffle([...new Set([...deepIds, ...a.b.ids, ...a.d1.ids, ...a.d2.ids])].filter((i) => i !== null), t.id);
  const pool = Object.fromEntries(ids.map((i, k) => [`P${k + 1}`, i]));
  fs.writeFileSync(path.join(D22, `pool-${t.id}.json`), JSON.stringify({ pool, deep: deepIds }));
  fs.writeFileSync(path.join(D22, `pool-${t.id}.txt`), Object.entries(pool).map(([p, i]) => `${p}: ${shown(entries[i])}`).join('\n'));
  console.log(t.id, 'pool', ids.length, 'entries, deep', deepIds.length);
} else if (mode === 'prep') {
  // the user's route per task: (d2)'s saved pick as the push, its sections as pointers, every file's entries in
  // source order for on-read delivery; and the harness config for arm r
  // --keyed (run 3): also every entry's path tokens from its applies-when terms, written to route3/
  const keyedRun = process.argv.includes('--keyed');
  const rdir = keyedRun ? 'route3' : 'route';
  fs.mkdirSync(path.join(D22, rdir), { recursive: true });
  for (const t of TASKS) {
    const { entries } = mapOf(t.repo);
    const a = JSON.parse(fs.readFileSync(path.join(D22, 'arms', `${t.id}.json`), 'utf8'));
    const byFile = {};
    for (const e of [...entries].sort((x, y) => x.blocks[0] - y.blocks[0])) (byFile[e.file] ??= []).push(e.n);
    const keyed = keyedRun ? entries.flatMap((e) => [...new Set(e.when.flatMap(tokensOf))].map((tk) => [e.n, tk])) : undefined;
    fs.writeFileSync(path.join(D22, rdir, `${t.id}.json`), JSON.stringify({ push: a.d2.ids, pointers: a.d2.sections,
      entries: Object.fromEntries(entries.map((e) => [e.n, { text: shown(e) }])), byFile, keyed }));
    if (keyedRun) console.log(t.id, 'path tokens', keyed.length, 'on', new Set(keyed.map(([n]) => n)).size, 'entries');
  }
  const nat = JSON.parse(fs.readFileSync(path.join(D22, 'native.json'), 'utf8'));
  for (const x of nat.tasks) x.route = path.join(D22, rdir, `${x.id.replace(/^D22-/, '')}.json`);
  fs.writeFileSync(path.join(D22, `${rdir}-native.json`), JSON.stringify(nat, null, 1));
  console.log('route prepared for', TASKS.length, 'tasks');
} else if (mode === 'reach') {
  // run 2: essential entries (attempt 1's judged set) that reached Claude by either channel, per session
  const res = {};
  for (const t of TASKS) {
    const { entries } = mapOf(t.repo);
    const bytes = (ids) => ids.reduce((s, i) => s + Buffer.byteLength(shown(entries[i])), 0);
    const { pool } = JSON.parse(fs.readFileSync(path.join(D22, `pool-${t.id}.json`), 'utf8'));
    const grades = JSON.parse(fs.readFileSync(path.join(D22, 'judge', `${t.id}-grades.json`), 'utf8'));
    const gradeOf = new Map(Object.entries(pool).map(([p, i]) => [i, grades[p]]));
    const E = [...gradeOf].filter(([, g]) => g === 'essential').map(([i]) => i);
    const runsDir = path.join(D22, 'd20-stage2', ARM, `D22-${t.id}`);
    const runs = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).filter((d) => /^run[1-9]/.test(d)) : [];
    const per = runs.map((d) => {
      const log = fs.readFileSync(path.join(runsDir, d, 'deliveries.jsonl'), 'utf8').trim().split('\n').flatMap((l) => (l ? [JSON.parse(l)] : []));
      const push = log.filter((l) => l.ev === 'UserPromptSubmit').flatMap((l) => l.ids ?? []);
      const read = log.filter((l) => l.ev === 'PostToolUse').flatMap((l) => l.ids ?? []);
      const all = [...new Set([...push, ...read])];
      const graded = all.filter((i) => gradeOf.has(i));
      return { reach: E.length ? +(E.filter((i) => all.includes(i)).length / E.length).toFixed(2) : 1,
        reachByPush: E.length ? +(E.filter((i) => push.includes(i)).length / E.length).toFixed(2) : 1,
        kb: +(bytes(all) / 1024).toFixed(1), pushKb: +(bytes(push) / 1024).toFixed(1), readKb: +(bytes(read) / 1024).toFixed(1),
        filesDelivered: log.filter((l) => l.ev === 'PostToolUse' && l.file).length, readCalls: log.filter((l) => l.ev === 'PostToolUse').length,
        gradedBytesShare: +(bytes(graded) / (bytes(all) || 1)).toFixed(2),
        relevantShareOfGraded: +(bytes(graded.filter((i) => gradeOf.get(i) !== 'no')) / (bytes(graded) || 1)).toFixed(2),
        hookMsMax: Math.max(0, ...log.map((l) => l.ms ?? 0)) };
    });
    const mean = per.length ? per.reduce((s, r) => s + r.reach, 0) / per.length : null;
    res[t.id] = { essential: E.length, runs: per, meanReach: mean === null ? null : +mean.toFixed(2), pass: mean !== null && mean >= 0.8 };
  }
  const sum = { date: new Date().toISOString().slice(0, 10), route: ARM === 'r' ? 'pick + pointers, then on read' : 'pick + pointers, then on read keyed to the file read',
    tasks: Object.fromEntries(Object.entries(res).map(([k, v], n) => [`${k.split('-')[0]}-task${(n % 2) + 1}`, v])),
    pass: Object.values(res).every((r) => r.pass) };
  fs.writeFileSync(path.join(HERE, 'results', ARM === 'r' ? 'reach.json' : `reach-${ARM}.json`), `${JSON.stringify(sum, null, 1)}\n`);
} else if (mode === 'simulate') {
  // run 3's free check: the files run 2's sessions actually read, replayed through the keyed hook offline
  for (const t of TASKS) {
    const { entries } = mapOf(t.repo);
    const route = JSON.parse(fs.readFileSync(path.join(D22, 'route3', `${t.id}.json`), 'utf8'));
    const { pool } = JSON.parse(fs.readFileSync(path.join(D22, `pool-${t.id}.json`), 'utf8'));
    const grades = JSON.parse(fs.readFileSync(path.join(D22, 'judge', `${t.id}-grades.json`), 'utf8'));
    const E = Object.entries(pool).filter(([p]) => grades[p] === 'essential').map(([, i]) => i);
    const runsDir = path.join(D22, 'd20-stage2', 'r', `D22-${t.id}`);
    const out = fs.readdirSync(runsDir).filter((d) => /^run[1-9]/.test(d)).map((d) => {
      const log = fs.readFileSync(path.join(runsDir, d, 'deliveries.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
      const got = new Set(log.filter((l) => l.ev === 'UserPromptSubmit').flatMap((l) => l.ids ?? []));
      for (const f of [...new Set(log.filter((l) => l.read).map((l) => l.read))]) {
        let used = 0;
        for (const id of [...new Set([...(route.byFile[f] ?? []), ...keyedFor(route.keyed, f)])]) {
          const b = Buffer.byteLength(shown(entries[id]));
          if (!got.has(id) && used + b <= CAP * 1024) { got.add(id); used += b; }
        }
      }
      return E.length ? E.filter((i) => got.has(i)).length / E.length : 1;
    });
    console.log(t.id, 'simulated reach on run 2 reads:', out.map((x) => x.toFixed(2)).join(', '));
  }
  console.log(JSON.stringify(Object.fromEntries(Object.entries(sum.tasks).map(([k, v]) => [k, v.meanReach]))), 'pass', sum.pass);
} else if (mode === 'native') {
  const d20 = JSON.parse(fs.readFileSync(path.join(RAW, 'd20-stage2.json'), 'utf8'));
  const repoOf = (label) => d20.tasks.find((x) => x.id.startsWith(`${label}-`));
  const cfg = { model: d20.model, smokeModel: d20.smokeModel,
    tasks: TASKS.map((t) => ({ id: `D22-${t.id}`, repo: repoOf(t.repo).repo, commit: repoOf(t.repo).commit, kind: 'plan', prompt: t.prompt, rules: [] })) };
  fs.writeFileSync(path.join(D22, 'native.json'), JSON.stringify(cfg, null, 1));
  console.log('native config', cfg.tasks.length, 'tasks');
} else if (mode === 'score') {
  const res = {};
  for (const t of TASKS) {
    if (!fs.existsSync(path.join(D22, 'judge', `${t.id}-grades.json`))) continue; // not graded yet: the summary says partial
    const { entries } = mapOf(t.repo);
    const bytes = (ids) => ids.reduce((s, i) => s + Buffer.byteLength(shown(entries[i])), 0);
    const { pool, deep } = JSON.parse(fs.readFileSync(path.join(D22, `pool-${t.id}.json`), 'utf8'));
    const grades = JSON.parse(fs.readFileSync(path.join(D22, 'judge', `${t.id}-grades.json`), 'utf8'));
    const E = new Set(Object.entries(pool).filter(([p]) => grades[p] === 'essential').map(([, i]) => i));
    const U = new Set(Object.entries(pool).filter(([p]) => grades[p] === 'useful').map(([, i]) => i));
    const a = JSON.parse(fs.readFileSync(path.join(D22, 'arms', `${t.id}.json`), 'utf8'));
    const eKb = bytes([...E]) / 1024;
    const deepE = [...E].filter((i) => deep.includes(i));
    const r = { pooled: Object.keys(pool).length, deep: deep.length, essential: E.size, useful: U.size, essentialKb: +eKb.toFixed(1), usefulKb: +(bytes([...U]) / 1024).toFixed(1), buildMs: a.buildMs, arms: {} };
    for (const arm of ['b', 'd1', 'd2']) {
      const d = a[arm].ids.filter((i) => i !== null);
      const db = bytes(d) || 1;
      const hitE = d.filter((i) => E.has(i));
      const recallE = E.size ? hitE.length / E.size : 1;
      const essBytes = bytes(hitE) / db;
      const relBytes = bytes(d.filter((i) => E.has(i) || U.has(i))) / db;
      const pass = (eKb <= CAP ? recallE >= 0.8 : essBytes >= 0.8) && relBytes >= 0.6;
      r.arms[arm] = { delivered: d.length, kb: +(db / 1024).toFixed(1), recallEssential: +recallE.toFixed(2), recallEssentialDeep: deepE.length ? +(d.filter((i) => deepE.includes(i)).length / deepE.length).toFixed(2) : null,
        essentialBytesShare: +essBytes.toFixed(2), relevantBytesShare: +relBytes.toFixed(2), pass, ms: a[arm].ms, calls: a[arm].calls, cost: a[arm].cost ?? 0, tokens: a[arm].tokens ?? 0 };
    }
    // native: essential entries whose source file a run opened with Read
    const runsDir = path.join(D22, 'd20-stage1', `D22-${t.id}`);
    if (fs.existsSync(runsDir)) {
      // run0 is the Haiku plumbing smoke; the registered runs are run1 and run2
      const cov = fs.readdirSync(runsDir).filter((d) => /^run[1-9]/.test(d)).map((d) => {
        const ev = fs.readFileSync(path.join(runsDir, d, 'stream.jsonl'), 'utf8').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
        const read = new Set(ev.flatMap((e) => (e.type === 'assistant' ? (e.message?.content ?? []) : [])).filter((c) => c.type === 'tool_use' && c.name === 'Read')
          .map((c) => String(c.input?.file_path ?? '').replace(/\\/g, '/').replace(/^.*?\/wt-D22-[^/]+\//, '')));
        return E.size ? [...E].filter((i) => read.has(entries[i].file)).length / E.size : 1;
      });
      r.native = { runs: cov.length, coverage: cov.map((c) => +c.toFixed(2)) };
    }
    res[t.id] = r;
  }
  const passed = (arm) => Object.values(res).every((r) => r.arms[arm].pass);
  const sum = { date: new Date().toISOString().slice(0, 10), cap: CAP, prompts: { pick: sha(PICK), sect: sha(SECT) },
    maps: Object.fromEntries(Object.keys(maps).map((l) => [l, { entries: maps[l].entries.length, kb: Math.round(maps[l].entries.reduce((s, e) => s + Buffer.byteLength(shown(e)), 0) / 1024),
      sections: maps[l].keys.length, failedWindows: maps[l].runs.filter((r) => r.error).length, costUsd: +maps[l].runs.reduce((s, r) => s + (r.cost ?? 0), 0).toFixed(2) }])),
    tasks: Object.fromEntries(Object.entries(res).map(([k, v], n) => [`${k.split('-')[0]}-task${(n % 2) + 1}`, v])),
    graded: `${Object.keys(res).length} of ${TASKS.length}`, pass: { b: passed('b'), d1: passed('d1'), d2: passed('d2') } };
  sum.locks = ['b', 'd1', 'd2'].find((a) => sum.pass[a]) ?? null;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'summary.json'), `${JSON.stringify(sum, null, 1)}\n`);
  console.log(JSON.stringify(sum.pass), 'locks', sum.locks);
} else {
  console.error('usage: node route.mjs selftest | arms|index|native|score <tasks> | pool <tasks> <task-id>');
  process.exit(2);
}
