// 06, section 3, S6, check 3 (attempt 2): D18's bar measured fairly. Empty Node, the control's hook and the
// candidate's hook are interleaved call by call in ONE pool, at 1 and at 8 concurrent, so all three see the same load
// (a sequential candidate-then-control bench drifts with the machine). Added p95 = a build's p95 minus empty Node's.
//   BENCH_DATA=<data> BENCH_TRANSCRIPTS=<dir> node pairbench.mjs <repo> <control plugin> <candidate plugin> [calls]
// The candidate gets the plugin data folder (the nudge's work); the control, 2.2.0, ignores it.
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const [repo, ctl, cand, calls = '200'] = process.argv.slice(2).map((a, i) => (i < 3 ? path.resolve(a) : a));
const N = Number(calls);
const TDIR = process.env.BENCH_TRANSCRIPTS;
const envOf = (data) => ({ ...process.env, CLAUDE_PROJECT_DIR: repo, ...(data ? { CLAUDE_PLUGIN_DATA: data } : {}) });
const doc = path.join(repo, fs.readdirSync(repo).find((f) => /\.md$/i.test(f)) ?? 'README.md');
let tail20 = '';
try { tail20 = `${fs.readFileSync(path.join(repo, '.project-map', 'captured.md'), 'utf8').replace(/\n$/, '').split('\n').slice(-20).join('\n')}\n`; } catch {}
const KINDS = {
  'session-start': (i) => ['session-start', { session_id: `pb-${i}`, source: 'startup', ...(TDIR ? { transcript_path: path.join(TDIR, `pb-${i}.jsonl`) } : {}) }],
  prompt: () => ['prompt', { session_id: 'pb-none' }],
  'read-other': () => ['read', { tool_input: { file_path: doc } }],
  'read-map': () => ['read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }],
  'bash-map': () => ['bash', { tool_input: { command: 'tail -20 .project-map/captured.md' }, tool_response: { stdout: tail20, stderr: '', interrupted: false, isImage: false } }],
  'bash-other': () => ['bash', { tool_input: { command: 'echo $HOME' }, tool_response: { stdout: `${os.homedir()}\n`, stderr: '', interrupted: false, isImage: false } }],
  // 06, 8o: every Grep starts the hook (no if filter); one that names the map by its path, and one that does not
  'grep-map': () => ['bash', { tool_name: 'Grep', tool_input: { pattern: 'status', path: '.project-map' }, tool_response: { mode: 'content', content: tail20 } }],
  'grep-other': () => ['bash', { tool_name: 'Grep', tool_input: { pattern: 'status', path: 'src' }, tool_response: { mode: 'files_with_matches', filenames: [] } }],
};
const time = (args, input, env) => new Promise((resolve) => {
  const t = performance.now();
  const c = spawn('node', args, { cwd: repo, env });
  c.stdout.resume();
  c.on('close', (code) => resolve({ ms: performance.now() - t, code }));
  c.stdin.on('error', () => {});
  c.stdin.end(input);
});
const p95 = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.ceil(0.95 * s.length) - 1)]; };
async function pool(jobs, c) { const out = new Array(jobs.length); let next = 0; await Promise.all(Array.from({ length: c }, async () => { while (next < jobs.length) { const i = next++; out[i] = await jobs[i](); } })); return out; }

const result = { calls: N, cores: os.cpus().length };
for (const c of [1, 8]) {
  for (const [kind, make] of Object.entries(KINDS)) {
    const jobs = [];
    for (let i = 0; i < N; i++) {
      const [which, input] = make(i);
      const body = JSON.stringify({ cwd: repo, ...input });
      jobs.push(() => time(['-e', ''], '', envOf()).then((r) => ['empty', r]));
      jobs.push(() => time([path.join(ctl, 'scripts', 'hook.mjs'), which], body, envOf()).then((r) => ['control', r]));
      jobs.push(() => time([path.join(cand, 'scripts', 'hook.mjs'), which], body, envOf(process.env.BENCH_DATA)).then((r) => ['candidate', r]));
    }
    const rs = await pool(jobs, c);
    const ms = (k) => rs.filter(([b]) => b === k).map(([, r]) => r.ms);
    const e = p95(ms('empty'));
    result[`${kind}@${c}`] = { emptyP95: +e.toFixed(1), controlAdded: +(p95(ms('control')) - e).toFixed(1), candidateAdded: +(p95(ms('candidate')) - e).toFixed(1),
      errors: rs.filter(([b, r]) => b !== 'empty' && r.code !== 0).length };
  }
}
for (const f of fs.readdirSync(os.tmpdir())) if (/^project-map-pb-\d+\.pending$/.test(f)) fs.rmSync(path.join(os.tmpdir(), f), { force: true });
console.log(JSON.stringify(result, null, 1));
process.exitCode = Object.values(result).some((v) => v.errors || (v.candidateAdded > 100)) ? 1 : 0;
