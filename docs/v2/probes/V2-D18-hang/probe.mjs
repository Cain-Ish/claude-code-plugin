// 06, section 4, 4a: the hang's diagnosis probe, registered in 06 before it ran. Seven arms, called in turn, each
// call limited to 15 seconds; watch.mjs, started beside it, captures any call that waits.
//   node probe.mjs <calls per arm> <out dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOOK = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', 'plugin', 'scripts', 'hook.mjs');
const N = Number(process.argv[2] ?? 150);
const out = process.argv[3] ?? fs.mkdtempSync(path.join(os.tmpdir(), 'hang-out-'));
fs.mkdirSync(out, { recursive: true });
const LIMIT = 15_000;

// a small map: two committed entries and one uncommitted, as the self-test's repo has
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'hang-repo-'));
const git = (...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo, encoding: 'utf8' }); if (r.status !== 0) throw new Error(r.stderr); };
const entry = (area, q) => `### ${area}\n> ${q}\n\n- source: the lead developer, 2026-11-23\n- when: ["components"]\n`;
git('init', '-q');
fs.mkdirSync(path.join(repo, '.project-map'));
fs.writeFileSync(path.join(repo, '.project-map', 'captured.md'), `${entry('components', 'Each component keeps its files in its own folder.')}\n${entry('avatars', 'Avatars load locally.')}`);
git('add', '-A');
git('commit', '-q', '-m', 'map');
fs.appendFileSync(path.join(repo, '.project-map', 'captured.md'), `\n${entry('migrations', 'Migrations run before deploys.')}`);

const env = { ...process.env, CLAUDE_PROJECT_DIR: repo, BRAIN_DIR: path.join(repo, 'no-v1') };
const input = (stdout) => JSON.stringify({ cwd: repo, tool_input: { command: 'cat .project-map/captured.md' }, tool_response: { stdout, stderr: '', interrupted: false, isImage: false } });
const lines80 = (n) => { let s = ''; while (s.length < n) s += `${'x'.repeat(79)}\n`; return s.slice(0, n); };
const READER = "/*PROBE_READER*/ const s = require('fs').readFileSync(0, 'utf8'); process.stdout.write(JSON.stringify({ n: s.length }));";

const viaSync = (args, inp) => {
  const t = Date.now();
  const r = spawnSync(process.execPath, args, { input: inp, encoding: 'utf8', env, timeout: LIMIT, killSignal: 'SIGKILL' });
  return { ms: Date.now() - t, timeout: r.error?.code === 'ETIMEDOUT', status: r.status };
};
const viaAsync = (args, inp) => new Promise((resolve) => {
  const t = Date.now();
  const c = spawn(process.execPath, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let timeout = false;
  const timer = setTimeout(() => { timeout = true; c.kill('SIGKILL'); }, LIMIT);
  c.stdout.resume();
  c.stderr.resume();
  c.stdin.on('error', () => {});
  c.on('close', (status) => { clearTimeout(timer); resolve({ ms: Date.now() - t, timeout, status }); });
  c.stdin.end(inp);
});

const ARMS = {
  S: () => viaSync([HOOK, 'bash'], input('x'.repeat(100))),
  H21: () => viaSync([HOOK, 'bash'], input('x'.repeat(21_000))),
  H25: () => viaSync([HOOK, 'bash'], input('x'.repeat(25_000))),
  H25n: () => viaSync([HOOK, 'bash'], input(lines80(25_000))),
  H100: () => viaSync([HOOK, 'bash'], input('x'.repeat(100_000))),
  T25: () => viaSync(['-e', READER], input('x'.repeat(25_000))),
  A25: () => viaAsync([HOOK, 'bash'], input('x'.repeat(25_000))),
};
const res = Object.fromEntries(Object.keys(ARMS).map((k) => [k, { calls: 0, ok: 0, timeouts: 0, failed: 0, maxMs: 0 }]));
for (let i = 0; i < N; i++) {
  for (const [k, call] of Object.entries(ARMS)) {
    const r = await call();
    const a = res[k];
    a.calls++;
    a.maxMs = Math.max(a.maxMs, r.ms);
    if (r.timeout) { a.timeouts++; fs.appendFileSync(path.join(out, 'timeouts.txt'), `${new Date().toISOString()} ${k} call ${i}\n`); }
    else if (r.status === 0) a.ok++;
    else a.failed++;
  }
}
fs.writeFileSync(path.join(out, 'results.json'), `${JSON.stringify(res, null, 1)}\n`);
console.table(res);
fs.rmSync(repo, { recursive: true, force: true });
