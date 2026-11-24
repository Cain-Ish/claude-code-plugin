// Pass 2 in the same temp folder: the tracked-file edits pass 1 did not reach, and the <tmp>/data refusal.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const PLUGIN = 'C:/Workplace/Projects/claude-code-plugin-v2/plugin';
const tmp = process.argv[2];
const cfg = path.join(tmp, 'config');
const data = path.join(cfg, 'plugins', 'data', 'second-brain');
const ostemp = path.join(tmp, 'ostemp');
const envFor = (repo) => ({ ...process.env, CLAUDE_PROJECT_DIR: repo, CLAUDE_CONFIG_DIR: cfg, CLAUDE_PLUGIN_DATA: data, BRAIN_DIR: path.join(tmp, 'no-v1', '.second-brain'), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp });
const sh = (repo, cmd, args) => spawnSync(cmd, args, { cwd: repo, encoding: 'utf8', env: envFor(repo) });
const node = (repo, script, ...a) => { const r = sh(repo, 'node', [path.join(PLUGIN, 'scripts', script), ...a]); return `exit ${r.status}: ${r.stdout.trim()}${r.stderr ? ` STDERR ${r.stderr}` : ''}`; };
const st = (repo) => sh(repo, 'git', ['--no-optional-locks', 'status', '--porcelain', '--untracked-files=all', '--ignored']).stdout.trim();
const ls = (d) => { const out = []; const rec = (r) => { for (const e of fs.readdirSync(path.join(d, r), { withFileTypes: true })) { const p = r ? `${r}/${e.name}` : e.name; e.isDirectory() ? rec(p) : out.push(`${p} ${fs.statSync(path.join(d, p)).size}`); } }; try { rec(''); } catch {} return out; };
const commit = (repo) => { sh(repo, 'git', ['add', '-A']); sh(repo, 'git', ['-c', 'user.name=f', '-c', 'user.email=f@example.invalid', 'commit', '-q', '-m', 'x']); };

const repo = fs.realpathSync.native(path.join(tmp, 'repo'));
// (a) the data folder the task named: refused
fs.mkdirSync(path.join(tmp, 'data'), { recursive: true });
const before = ls(path.join(tmp, 'data')).join() + st(repo);
console.log('A prepare <tmp>/data:', node(repo, 'dream.mjs', 'prepare', path.join(tmp, 'data')), '| changed:', before !== ls(path.join(tmp, 'data')).join() + st(repo));

// (b) a second dream on committed files: an entry appended to the tracked build.md, a status line on its entry
commit(repo);
const d0 = ls(data);
console.log('B prepare:', node(repo, 'dream.mjs', 'prepare', data));
const P = path.join(repo, '.project-map', '.dream-run', 'proposals');
fs.mkdirSync(path.join(P, 'map'), { recursive: true });
fs.writeFileSync(path.join(P, 'map', 'build.md'), '### build command\n> All builds run through npm run build.\n\n- id: build-guide\n- source: docs/guide.md, 2026-11-24\n- when: ["build work"]\n');
fs.writeFileSync(path.join(P, 'status.md'), 'build-npm | - status: narrowed 2026-11-24 by build-guide: the build command still holds\n');
console.log('B finish:', node(repo, 'dream.mjs', 'finish', data));
console.log('B git status:\n' + st(repo));
console.log('B data before:', d0, '\nB data after:', ls(data));
console.log('B build.md:\n' + fs.readFileSync(path.join(repo, '.project-map', 'build.md'), 'utf8'));

// (c) setup in a repo with a committed CLAUDE.md and .gitattributes that lack setup's section and line
const r2 = path.join(tmp, 'repo2');
fs.mkdirSync(r2, { recursive: true });
sh(r2, 'git', ['init', '-q', '-b', 'main']);
fs.writeFileSync(path.join(r2, 'CLAUDE.md'), '# Project\n\nOur own rules.\n');
fs.writeFileSync(path.join(r2, '.gitattributes'), '* text=auto\n');
commit(r2);
console.log('C setup:', node(r2, 'hook.mjs', 'setup'));
console.log('C git status:\n' + st(r2));
console.log('C diff:\n' + sh(r2, 'git', ['--no-optional-locks', 'diff']).stdout);
