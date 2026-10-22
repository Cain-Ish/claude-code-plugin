// V2-D20 check-source count (pre-registered in DECISIONS.md): can a model write a project's pattern checks from the
// rule's source document? One Sonnet call per source document, blind to the hand-written checks; scored against
// D20's correct and wrong samples. Raw model output stays next to the private config (d20-genchecks/); counts only
// come back here (results/genchecks.json).
//   node genchecks.mjs <config>            generate (skips documents already generated), then score
//   node genchecks.mjs selftest
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { check } from './check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PROMPT = `You write automatic checks for a project's own rules. Input: one document of the project. For every rule in it that a text check on a changed file can verify, output a JSON object {"rule": a short quote, "files": a regular expression for the file paths it applies to, "must": [regular expressions a correct file contains], "mustNot": [regular expressions a correct file does not contain], "message": one line}. Output only a JSON array, no prose. Leave out rules a text check cannot verify.`;

// The first JSON array in a reply, bracket by bracket, outside strings.
export function firstArray(s) {
  const i = s.indexOf('[');
  let depth = 0;
  let str = false;
  for (let j = i; i >= 0 && j < s.length; j++) {
    const ch = s[j];
    if (str) { if (ch === '\\') j++; else if (ch === '"') str = false; continue; }
    if (ch === '"') str = true;
    else if (ch === '[') depth++;
    else if (ch === ']' && --depth === 0) return s.slice(i, j + 1);
  }
  return '[]';
}

// A generated check, in check.mjs's form; null when a pattern is not a valid JavaScript regular expression.
export function asCheck(g) {
  try {
    const c = { path: String(g.files ?? '.'), must: [g.must ?? []].flat().map(String), mustNot: [g.mustNot ?? []].flat().map(String) };
    [c.path, ...c.must, ...c.mustNot].forEach((x) => new RegExp(x));
    return c;
  } catch { return null; }
}
const applies = (c, files) => Object.keys(files).some((p) => new RegExp(c.path).test(p));

const claude = (input) => new Promise((resolve) => {
  const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const p = spawn('claude', ['-p', '--model', 'claude-sonnet-5-5', '--output-format', 'json', '--system-prompt', PROMPT, '--tools', '',
    '--setting-sources', 'project', '--strict-mcp-config', '--no-session-persistence'], { cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'd20g-')), env });
  let out = '';
  p.stdout.on('data', (d) => { out += d; });
  p.on('close', () => {
    try {
      const o = JSON.parse(out);
      resolve({ checks: JSON.parse(firstArray(String(o.result))), cost: o.total_cost_usd });
    } catch (e) { resolve({ checks: [], cost: null, error: String(e).slice(0, 200) }); }
  });
  p.stdin.end(input);
});

const [mode] = process.argv.slice(2);
const cfgArg = mode; // anything but selftest is the config
if (mode === 'selftest') {
  assert.equal(firstArray('x [{"a":"]"}, [1]] note [2]'), '[{"a":"]"}, [1]]');
  assert.equal(asCheck({ files: '(?i)x', must: [] }), null);
  const c = asCheck({ files: 'a\\.tsx$', must: ['tip='], mustNot: ['bad'] });
  assert.equal(check(c, { 'src/a.tsx': '<F tip="x">' }, ''), true);
  assert.equal(check(c, { 'src/a.tsx': '<F> bad' }, ''), false);
  assert.equal(applies(c, { 'src/b.tsx': '' }), false);
  console.log('selftest ok');
} else {
  const cfgPath = path.resolve(cfgArg);
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  const RAW = path.join(path.dirname(cfgPath), 'd20-genchecks');
  fs.mkdirSync(RAW, { recursive: true });
  const out = { date: new Date().toISOString().slice(0, 10), bar: '>= 14 of 17 caught, P1 R2 among them; false alarms <= 1 in 10 of applying checks', tasks: {}, docs: 0, costUsd: 0 };
  const gen = {};
  for (const t of cfg.tasks) {
    const rules = t.rules.filter((r) => r.card?.cls === 'pattern');
    if (!rules.length) continue;
    const label = path.basename(t.repo);
    for (const src of [...new Set(rules.map((r) => r.source))]) {
      const key = `${label}::${src}`;
      if (gen[key]) continue;
      const file = path.join(RAW, `${label}-${src.replace(/[\\/]/g, '__')}.json`);
      if (!fs.existsSync(file)) {
        const text = execFileSync('git', ['-C', t.repo, 'show', `${t.commit}:${src}`], { encoding: 'utf8', maxBuffer: 1 << 28 });
        const r = await claude(`Document: ${src}\n\n${text}`);
        fs.writeFileSync(file, JSON.stringify(r, null, 1));
        console.log(key, r.checks.length, 'checks', r.error ?? '');
      }
      gen[key] = JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    const forTask = [...new Set(rules.map((r) => `${label}::${r.source}`))].flatMap((k) => gen[k].checks.map(asCheck)).filter(Boolean);
    const row = { rules: {}, falseAlarms: 0, applyingToCorrect: 0 };
    for (const r of rules) {
      const own = gen[`${label}::${r.source}`].checks.map(asCheck).filter(Boolean);
      row.rules[r.id] = own.some((c) => applies(c, r.test.pass) && check(c, r.test.pass, '') && !check(c, r.test.fail, ''));
      for (const c of forTask) if (applies(c, r.test.pass)) { row.applyingToCorrect++; if (!check(c, r.test.pass, '')) row.falseAlarms++; }
    }
    // noise on existing code: the share of the repo's current files a check would flag, among those it applies to
    const tracked = execFileSync('git', ['-C', t.repo, 'ls-tree', '-r', '--name-only', t.commit], { encoding: 'utf8', maxBuffer: 1 << 28 }).split('\n').filter(Boolean);
    row.noise = forTask.map((c) => {
      const hit = tracked.filter((p) => new RegExp(c.path).test(p)).slice(0, 200);
      const bad = hit.filter((p) => { try { return !check(c, { [p]: execFileSync('git', ['-C', t.repo, 'show', `${t.commit}:${p}`], { encoding: 'utf8', maxBuffer: 1 << 26 }) }, ''); } catch { return false; } });
      return hit.length ? +(bad.length / hit.length).toFixed(2) : null;
    }).filter((x) => x !== null);
    row.checks = forTask.length;
    out.tasks[t.id] = row;
  }
  out.docs = Object.keys(gen).length;
  out.costUsd = +Object.values(gen).reduce((a, g) => a + (g.cost ?? 0), 0).toFixed(2);
  const all = Object.values(out.tasks).flatMap((x) => Object.values(x.rules));
  const fa = Object.values(out.tasks).reduce((a, x) => a + x.falseAlarms, 0);
  const ap = Object.values(out.tasks).reduce((a, x) => a + x.applyingToCorrect, 0);
  out.caught = `${all.filter(Boolean).length} of ${all.length}`;
  out.falseAlarmShare = ap ? +(fa / ap).toFixed(2) : null;
  out.pass = all.filter(Boolean).length >= 14 && out.tasks['P1-build']?.rules.R2 === true && (out.falseAlarmShare ?? 0) <= 0.1;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'genchecks.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ caught: out.caught, falseAlarmShare: out.falseAlarmShare, pass: out.pass, perTask: Object.fromEntries(Object.entries(out.tasks).map(([k, v]) => [k, v.rules])) }, null, 1));
}
