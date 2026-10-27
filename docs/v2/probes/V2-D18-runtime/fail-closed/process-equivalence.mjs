// V2-D18 reopened (2026-10-27, 06 step 2g attempt 3), the process half of the equivalence: the 61964f9bbb40 hooks (old/)
// and the fixed ones, run as Claude Code runs them, at each repo's root, with and without benchmap.mjs's map. Their
// stdout must be byte-identical. Takes worktrees of P1, P2 and R0 at their pinned commits; prints counts only.
//   node process-equivalence.mjs <new plugin dir> <p1> <p2> <r0>
// PE_OLD (another old plugin dir) and PE_OUT (a results name) compare another pair: 06, 2g attempt 4.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [newDir, ...repos] = process.argv.slice(2);
const OLD_DIR = process.env.PE_OLD ? path.resolve(process.env.PE_OLD) : path.join(HERE, 'old');
const HOOKS = { old: path.join(OLD_DIR, 'scripts', 'hook.mjs'), new: path.join(path.resolve(newDir), 'scripts', 'hook.mjs') };
const BENCHMAP = path.join(path.resolve(newDir), 'test', 'benchmap.mjs');
const call = (hook, which, input, repo) => spawnSync('node', [hook, which], { input: which === 'onboard' ? '' : JSON.stringify({ cwd: repo, ...input }),
  encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: repo } });
const out = { compared: 0, differing: [] };
for (const [label, repo] of ['P1', 'P2', 'R0'].map((l, i) => [l, repos[i]])) {
  const doc = spawnSync('git', ['ls-files'], { cwd: repo, encoding: 'utf8' }).stdout.split('\n').find((f) => /\.md$/i.test(f));
  for (const withMap of [false, true]) {
    fs.rmSync(path.join(repo, '.project-map'), { recursive: true, force: true });
    if (withMap) spawnSync('node', [BENCHMAP, repo]);
    const cases = [
      ['session-start', { source: 'startup' }], ['prompt', {}], ['prompt', {}],
      ['read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }],
      ['read', { tool_input: { file_path: path.join(repo, doc) } }],
      ['onboard', {}],
    ];
    const result = {};
    for (const [k, hook] of Object.entries(HOOKS)) result[k] = cases.map(([which, input]) => {
      const r = call(hook, which, { session_id: `eq-${k}-${process.pid}`, ...input }, repo);
      return `${r.status}\n${r.stdout}`;
    });
    cases.forEach(([which], i) => { out.compared++; if (result.old[i] !== result.new[i]) out.differing.push(`${label} ${withMap ? 'map' : 'no map'} ${which} #${i}`); });
  }
  fs.rmSync(path.join(repo, '.project-map'), { recursive: true, force: true });
}
out.differences = out.differing.length;
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `${process.env.PE_OUT ?? 'process-equivalence'}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
