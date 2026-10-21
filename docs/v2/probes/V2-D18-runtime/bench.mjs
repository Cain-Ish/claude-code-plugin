// V2-D18 bench: the hook scripts as separate processes against P2's full map, timed wall-clock with the spawn, at 1
// and 8 concurrent (Windows); plus the label, boundary, nested-converter and missing-runtime checks. The bench repo is a
// worktree of the scratch clone at the pinned commit, with the map rendered as committed Markdown; it stays outside
// this repo. Only counts come back here (results/).
//   node bench.mjs build  <config> <bench-dir>
//   node bench.mjs load   <config> <bench-dir> [calls=200]
//   node bench.mjs checks <config> <bench-dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { render } from '../V2-D15-onboarding/onboard.mjs';
import { buildCache, deliver, shard, MAP } from './lib.mjs';
import { sections } from '../V2-D15-onboarding/onboard.mjs';
import { convert } from '../V2-D13-selection/convert.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, cfgArg, benchArg, callsArg] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
const RAW = path.dirname(path.resolve(cfgArg));
const BENCH = path.resolve(benchArg);
const task = cfg.tasks.find((t) => t.id.startsWith('P2-'));
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=bench', '-c', 'user.email=bench@example.invalid', ...a], { cwd, encoding: 'utf8' });
const write = (name, obj) => { fs.mkdirSync(path.join(HERE, 'results'), { recursive: true }); fs.writeFileSync(path.join(HERE, 'results', name), `${JSON.stringify(obj, null, 1)}\n`); };
const q = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };

const loadEntries = () => {
  const all = JSON.parse(fs.readFileSync(path.join(RAW, 'd13', 'maps', 'P2.json'), 'utf8')).all;
  const dir = path.join(RAW, 'd15', 'full', 'P2');
  return fs.readdirSync(dir).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')))
    .flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file, heads: all[x.blocks[0]].heads })));
};

if (mode === 'build') {
  git(task.repo, 'worktree', 'remove', '--force', BENCH);
  fs.rmSync(BENCH, { recursive: true, force: true });
  const r = git(task.repo, 'worktree', 'add', '-q', '--detach', BENCH, task.commit);
  if (r.status !== 0) throw new Error(r.stderr);
  const byFile = Map.groupBy(loadEntries().sort((a, b) => a.blocks[0] - b.blocks[0]), (e) => e.file);
  for (const [file, es] of byFile) {
    const f = path.join(BENCH, MAP, `${file}.md`);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, render(file, es));
  }
  git(BENCH, 'add', MAP);
  git(BENCH, 'commit', '-q', '-m', 'map');
  const t0 = performance.now();
  buildCache(BENCH);
  console.log(`bench at ${byFile.size} map files; cache built in ${Math.round(performance.now() - t0)} ms`);
} else if (mode === 'load') {
  const calls = Number(callsArg ?? 200);
  const files = git(BENCH, 'ls-files').stdout.split('\n').filter((f) => f && !f.startsWith(MAP));
  const pickFiles = files.sort((a, b) => crypto.createHash('sha1').update(a).digest('hex').localeCompare(crypto.createHash('sha1').update(b).digest('hex'))).slice(0, 40);
  const someDoc = Object.keys(JSON.parse(fs.readFileSync(path.join(BENCH, MAP, '.cache', 'keys.json'), 'utf8')).reduce((o, [id]) => ({ ...o, [id.slice(0, id.lastIndexOf('#'))]: 1 }), {}))[0];
  const input = (which, k) => (which === 'session-start' ? { hook_event_name: 'SessionStart', cwd: BENCH }
    : which === 'deliver30' ? { hook_event_name: 'UserPromptSubmit', cwd: BENCH, source: someDoc }
      : { hook_event_name: 'PostToolUse', tool_name: which === 'on-read' ? 'Read' : 'Write', cwd: BENCH, tool_input: { file_path: path.join(BENCH, pickFiles[k % pickFiles.length]) } });
  const one = (which, k) => new Promise((resolve) => {
    const t0 = performance.now();
    const p = spawn('node', [path.join(HERE, 'hooks.mjs'), which], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.on('close', (code) => resolve({ ms: performance.now() - t0, code, bytes: out.length }));
    p.stdin.end(JSON.stringify(input(which, k)));
  });
  const res = {};
  for (const which of ['session-start', 'on-read', 'on-write', 'deliver30']) {
    res[which] = {};
    for (const conc of [1, 8]) {
      const times = [];
      let next = 0;
      let errors = 0;
      await Promise.all(Array.from({ length: conc }, async () => { while (next < calls) { const k = next++; const r = await one(which, k); times.push(r.ms); errors += r.code ? 1 : 0; } }));
      res[which][conc] = { p50: Math.round(q(times, 0.5)), p95: Math.round(q(times, 0.95)), max: Math.round(Math.max(...times)), errors };
    }
    console.log(which, JSON.stringify(res[which]));
  }
  const pass = Object.values(res).every((r) => r[8].p95 <= 100 && r[8].errors === 0);
  write('load.json', { date: new Date().toISOString().slice(0, 10), os: `${os.platform()} ${os.release()}`, node: process.version, calls, entries: 14119, budgetMs: 100, pass, scripts: res });
  console.log('pass', pass);
} else if (mode === 'checks') {
  const res = {};
  // 2. labels: one map file changed and left uncommitted; only its entries carry the label
  const mapFile = git(BENCH, 'ls-files', MAP).stdout.split('\n').find((f) => f.endsWith('.md'));
  const source = mapFile.slice(MAP.length + 1, -3);
  const other = git(BENCH, 'ls-files', MAP).stdout.split('\n').filter((f) => f.endsWith('.md'))[1].slice(MAP.length + 1, -3);
  fs.appendFileSync(path.join(BENCH, mapFile), '\n### probe\n> An uncommitted entry added for the label check.\n\n- source: probe, 2026-10-22\n- when: []\n');
  buildCache(BENCH);
  const a = deliver(BENCH, shard(BENCH, source));
  const b = deliver(BENCH, shard(BENCH, other));
  res.labels = { uncommittedLabelled: a.every((o) => o.labels.includes('unreviewed, not yet committed')), committedClean: b.every((o) => !o.labels.includes('unreviewed, not yet committed')) };
  git(BENCH, 'checkout', '--', mapFile);
  buildCache(BENCH);
  // every delivery path goes through deliver()
  const hooksSrc = fs.readFileSync(path.join(HERE, 'hooks.mjs'), 'utf8');
  res.labels.allPathsGuarded = (hooksSrc.match(/emit\(/g) ?? []).length - 1 === (hooksSrc.match(/deliver\(/g) ?? []).length;
  res.labels.pass = Object.values(res.labels).every(Boolean);
  // 3. boundary: hook code spawns only git; no eval, Function or exec
  const src = ['lib.mjs', 'hooks.mjs'].map((f) => fs.readFileSync(path.join(HERE, f), 'utf8')).join('\n');
  const spawns = [...src.matchAll(/spawn(?:Sync)?\(\s*'([^']+)'/g)].map((m) => m[1]);
  res.boundary = { spawns: [...new Set(spawns)], noEval: !/\beval\(|new Function\(|\bexec(?:Sync)?\(/.test(src) };
  res.boundary.pass = res.boundary.spawns.every((s) => s === 'git') && res.boundary.noEval;
  // 4. nested converter: the prototype hooks are active in the bench repo; one window converted with V2_NESTED=1
  const log = path.join(os.tmpdir(), `d18-hooklog-${Date.now()}.txt`);
  const logger = path.join(os.tmpdir(), 'd18-logger.mjs');
  fs.writeFileSync(logger, `import fs from 'node:fs';\nconst i = JSON.parse(fs.readFileSync(0, 'utf8'));\nfs.appendFileSync(${JSON.stringify(log)}, (process.env.V2_NESTED === '1' ? 'nested ' : 'outer ') + i.hook_event_name + '\\n');\nif (process.env.V2_NESTED === '1') process.exit(0);\n`);
  fs.mkdirSync(path.join(BENCH, '.claude'), { recursive: true });
  const cmd = `node "${logger.replace(/\\/g, '/')}"`;
  fs.writeFileSync(path.join(BENCH, '.claude', 'settings.local.json'), JSON.stringify({ hooks: Object.fromEntries(['SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Stop'].map((ev) => [ev, [{ hooks: [{ type: 'command', command: cmd }] }]])) }));
  const doc = fs.readFileSync(path.join(BENCH, source), 'utf8').slice(0, 3500);
  const win = { file: source, part: [{ i: 0, e: { heads: [], text: doc } }], k: 0, bytes: Buffer.byteLength(doc) };
  console.log(`nested converter: one window of ${win.bytes} bytes, estimated cost under 0.05 USD`);
  process.env.V2_NESTED = '1';
  const conv = await convert(win, BENCH);
  delete process.env.V2_NESTED;
  const lines = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [];
  res.nested = { converted: !conv.error && conv.entries.length > 0, entries: conv.entries.length, costUsd: conv.cost, hookCalls: lines.length, outerCalls: lines.filter((l) => l.startsWith('outer')).length };
  res.nested.pass = res.nested.converted && res.nested.outerCalls === 0;
  fs.rmSync(path.join(BENCH, '.claude', 'settings.local.json'));
  // 5. runtime missing: a SessionStart hook naming a binary that does not exist; the session must complete
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'd18-noruntime-'));
  spawnSync('git', ['init', '-q', tmp]);
  fs.mkdirSync(path.join(tmp, '.claude'));
  fs.writeFileSync(path.join(tmp, '.claude', 'settings.local.json'), JSON.stringify({ hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'nodex-missing-runtime hooks.mjs session-start' }] }] } }));
  const env = { ...process.env, DISABLE_AUTOUPDATER: '1', MSYS_NO_PATHCONV: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const r = spawnSync('claude', ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
    { cwd: tmp, input: 'Say hello in one word.', encoding: 'utf8', env, timeout: 300_000 });
  const evs = (r.stdout ?? '').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
  const result = evs.findLast((e) => e.type === 'result');
  const hookEv = evs.filter((e) => /hook/i.test(e.subtype ?? e.type ?? ''));
  res.noRuntime = { completed: result?.subtype === 'success', hookEvents: hookEv.length, shown: hookEv.map((e) => String(e.stderr ?? e.output ?? e.error ?? '').slice(0, 120)).filter(Boolean).slice(0, 2) };
  res.noRuntime.pass = res.noRuntime.completed;
  write('checks.json', { date: new Date().toISOString().slice(0, 10), ...res, pass: res.labels.pass && res.boundary.pass && res.nested.pass && res.noRuntime.pass });
  console.log(JSON.stringify(res, null, 1));
}
