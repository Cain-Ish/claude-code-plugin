// 06, section 9, AU-7's check: the Bash hook on a command that names a map of 8 topic files with entries, against an
// empty Node, 30 paired runs at 1 session, for each plugin folder given. Prints the added time's median and p95 (ms).
//   node bench7.mjs <plugin folder> [<plugin folder> ...]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const plugins = process.argv.slice(2).map((p) => path.resolve(p));
const r = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-bench7-'));
const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r });
g('init', '-q');
fs.mkdirSync(path.join(r, '.project-map'));
const entry = (k, i) => `### topic ${k} rule ${i}\n> Topic ${k} holds rule ${i} for the work here.\n\n- id: t${k}-${i}\n- source: the lead developer, 2026-11-0${1 + (i % 9)}\n- when: ["work"]\n`;
for (let k = 0; k < 8; k++) fs.writeFileSync(path.join(r, '.project-map', `t${k}.md`), Array.from({ length: 6 }, (_, i) => entry(k, i)).join('\n'));
g('add', '-A');
g('commit', '-qm', 'map');
const input = JSON.stringify({ cwd: r, session_id: 'bench7', tool_name: 'Bash', tool_input: { command: 'grep -n rule .project-map/*.md' }, tool_response: { stdout: '.project-map/t3.md:1:### topic 3 rule 0\n', stderr: '' } });
const env = { ...process.env, CLAUDE_PROJECT_DIR: r };
const ms = (f) => { const t = process.hrtime.bigint(); f(); return Number(process.hrtime.bigint() - t) / 1e6; };
const q = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)]; };
for (const plugin of plugins) {
  const hook = path.join(plugin, 'scripts', 'hook.mjs');
  const out = spawnSync(process.execPath, [hook, 'bash'], { input, env, encoding: 'utf8' }).stdout;
  if (!out.includes('t3.md')) throw new Error(`${plugin}: no labels in the output`);
  const added = [];
  for (let k = 0; k < 30; k++) {
    const empty = ms(() => spawnSync(process.execPath, ['-e', '0'], { input, env }));
    const h = ms(() => spawnSync(process.execPath, [hook, 'bash'], { input, env }));
    added.push(h - empty);
  }
  console.log(`${path.basename(path.dirname(plugin))}/${path.basename(plugin)}: added median ${q(added, 0.5).toFixed(1)} ms, p95 ${q(added, 0.95).toFixed(1)} ms (30 paired runs, 8 files)`);
}
fs.rmSync(r, { recursive: true, force: true });
