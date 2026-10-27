// V2-D18 reopened (2026-10-27, 06 2h attempt 3): does alpha.2 cost time? The old (old/, da81530cb1c3) and new
// (plugin/) session-start and map-read hooks, interleaved one call at a time with an empty Node, so both builds see the
// same runner. The cost is the new median minus the old. Prints counts only.
//   node paired.mjs <repo with benchmap.mjs's map> [calls, default 200] [new plugin dir, default plugin/]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [repo, calls = '200', newDir = path.join(HERE, '..', '..', '..', '..', '..', 'plugin')] = process.argv.slice(2);
const N = Number(calls);
const HOOKS = { old: path.join(HERE, 'old', 'scripts', 'hook.mjs'), new: path.join(path.resolve(newDir), 'scripts', 'hook.mjs') };
const env = { ...process.env, CLAUDE_PROJECT_DIR: repo };
const map = path.join(repo, '.project-map', 'captured.md');
if (!fs.existsSync(map)) throw new Error('no map: run plugin/test/benchmap.mjs on the repo first');
const time = (args, input) => {
  const t = performance.now();
  const r = spawnSync('node', args, { cwd: repo, env, input, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`${args.join(' ')} exited ${r.status}`);
  return { ms: performance.now() - t, out: r.stdout };
};
const KINDS = {
  'session-start': (i, b) => ['session-start', { cwd: repo, session_id: `paired-${b}-${i}`, source: 'startup' }],
  'read-map': () => ['read', { cwd: repo, tool_input: { file_path: map } }],
};
const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return +s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)].toFixed(1); };
const result = { calls: N, platform: process.platform, node: process.version, cores: os.cpus().length };
for (const [kind, make] of Object.entries(KINDS)) {
  const t = { old: [], new: [], empty: [] };
  const outs = { old: new Set(), new: new Set() };
  for (let i = 0; i < N; i++) {
    // alternate which build goes first, so neither always follows the empty Node
    for (const b of i % 2 ? ['old', 'new', 'empty'] : ['new', 'old', 'empty']) {
      if (b === 'empty') { t.empty.push(time(['-e', ''], '').ms); continue; }
      const [which, input] = make(i, b);
      const r = time([HOOKS[b], which], JSON.stringify(input));
      t[b].push(r.ms);
      outs[b].add(r.out);
    }
  }
  result[kind] = {
    old: { p50: q(t.old, 0.5), p95: q(t.old, 0.95) },
    new: { p50: q(t.new, 0.5), p95: q(t.new, 0.95) },
    empty: { p50: q(t.empty, 0.5), p95: q(t.empty, 0.95) },
    costP50: +(q(t.new, 0.5) - q(t.old, 0.5)).toFixed(1),
    sameOutput: outs.old.size === 1 && outs.new.size === 1 && [...outs.old][0] === [...outs.new][0],
  };
}
for (const f of fs.readdirSync(os.tmpdir())) if (/^project-map-paired-/.test(f)) fs.rmSync(path.join(os.tmpdir(), f), { force: true });
console.log(JSON.stringify(result, null, 1));
