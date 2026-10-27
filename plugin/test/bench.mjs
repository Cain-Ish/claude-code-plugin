// The skeleton's load bench (06, step 2a; D18's bar): each hook against an empty Node process, paired in one pool so
// both see the same load, at 1 and 8 concurrent. Prints counts only.   node plugin/test/bench.mjs <repo> [calls]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOOK = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'hook.mjs');
const [repo, calls = '200'] = process.argv.slice(2);
const N = Number(calls);
const env = { ...process.env, CLAUDE_PROJECT_DIR: repo };
const doc = path.join(repo, (fs.readdirSync(repo).find((f) => /\.md$/i.test(f)) ?? 'README.md'));
const KINDS = {
  'session-start': (i) => ['session-start', { session_id: `bench-${i}`, source: 'startup' }],
  prompt: () => ['prompt', { session_id: 'bench-none' }],
  'read-other': () => ['read', { tool_input: { file_path: doc } }],
  'read-map': () => ['read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }],
};

const time = (args, input) => new Promise((resolve) => {
  const t = performance.now();
  const c = spawn('node', args, { cwd: repo, env });
  c.stdout.resume();
  c.on('close', (code) => resolve({ ms: performance.now() - t, code }));
  c.stdin.end(input);
});
const p = (a, q) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)]; };

async function pool(jobs, c) {
  const out = new Array(jobs.length);
  let next = 0;
  await Promise.all(Array.from({ length: c }, async () => { while (next < jobs.length) { const i = next++; out[i] = await jobs[i](); } }));
  return out;
}

const result = { calls: N, platform: process.platform, node: process.version, cores: os.cpus().length };
// BENCH_CONCURRENCY adds levels to report (D18 reopened, 2026-10-27); the bar below stays keyed to 8
for (const c of (process.env.BENCH_CONCURRENCY ?? '1,8').split(',').map(Number)) {
  for (const [kind, make] of Object.entries(KINDS)) {
    const jobs = [];
    for (let i = 0; i < N; i++) {
      const [which, input] = make(i);
      jobs.push(() => time(['-e', ''], '').then((r) => ({ empty: r })));
      jobs.push(() => time([HOOK, which], JSON.stringify({ cwd: repo, ...input })).then((r) => ({ hook: r })));
    }
    const rs = await pool(jobs, c);
    const hook = rs.filter((r) => r.hook).map((r) => r.hook);
    const empty = rs.filter((r) => r.empty).map((r) => r.empty.ms);
    const ms = hook.map((r) => r.ms);
    result[`${kind}@${c}`] = { errors: hook.filter((r) => r.code !== 0).length, p50: +p(ms, 0.5).toFixed(1), p95: +p(ms, 0.95).toFixed(1),
      emptyP95: +p(empty, 0.95).toFixed(1), addedP95: +(p(ms, 0.95) - p(empty, 0.95)).toFixed(1) };
  }
}
for (const f of fs.readdirSync(os.tmpdir())) if (/^project-map-bench-\d+\.pending$/.test(f)) fs.rmSync(path.join(os.tmpdir(), f), { force: true });
console.log(JSON.stringify(result, null, 1));
// D18's bar, as the Windows lane checks it (PM3): no failed call, and added p95 at most 100 ms at 8 concurrent
process.exitCode = Object.entries(result).some(([k, v]) => v.errors || (k.endsWith('@8') && v.addedP95 > 100)) ? 1 : 0;
