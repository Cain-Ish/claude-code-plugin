// 06, 2h (2026-10-27): which letter-case renames git's core.ignorecase folds. A scratch repo commits captured.md and
// Ärger.md under .project-map/, renames them on disk to Captured.md and ärger.md, and asks git for the untracked map
// files with the setting true, then false. Prints and saves the listings.   node git-case-probe.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-case-'));
const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.quotepath=false', ...a], { cwd: repo, encoding: 'utf8' });
git('init', '-q');
const out = { platform: process.platform, git: git('--version').stdout.trim(), initIgnorecase: git('config', '--local', 'core.ignorecase').stdout.trim() || '(unset)' };
fs.mkdirSync(path.join(repo, '.project-map'));
for (const f of ['captured.md', 'Ärger.md']) fs.writeFileSync(path.join(repo, '.project-map', f), 'x\n');
git('add', '-A');
git('commit', '-q', '-m', 'init');
fs.renameSync(path.join(repo, '.project-map', 'captured.md'), path.join(repo, '.project-map', 'Captured.md'));
fs.renameSync(path.join(repo, '.project-map', 'Ärger.md'), path.join(repo, '.project-map', 'ärger.md'));
out.onDisk = fs.readdirSync(path.join(repo, '.project-map')).sort();
for (const ic of ['true', 'false']) {
  git('config', 'core.ignorecase', ic);
  out[`untracked, ignorecase ${ic}`] = git('ls-files', '-z', '--others', '--exclude-standard', '--', '.project-map').stdout.split('\0').filter(Boolean);
}
fs.rmSync(repo, { recursive: true, force: true });
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `git-case-probe-${process.platform}.json`), `${JSON.stringify(out, null, 2)}\n`);
console.log(JSON.stringify(out, null, 2));
