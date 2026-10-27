// 06, 2h (2026-10-27): each intended difference between the da81530cb1c3 library (old/) and alpha.2's. In every case
// the old code must give the old output and the new code the new one. Git's own listing is D16's two-call index()
// (map-497ba915.mjs: ls-files --cached, then ls-files --others --exclude-standard under .project-map/).
//   node differences.mjs [new plugin dir, default the repo's plugin/]     Prints and saves counts and verdicts only.
// The attempt ran against a plugin copy here, moved into plugin/ after it passed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NEW_DIR = path.resolve(process.argv[2] ?? path.join(HERE, '..', '..', '..', '..', '..', 'plugin'));
const OLD = await import(pathToFileURL(path.join(HERE, 'old', 'scripts', 'map.mjs')).href);
const NEW = await import(pathToFileURL(path.join(NEW_DIR, 'scripts', 'map.mjs')).href);
const GIT = await import(pathToFileURL(path.join(HERE, '..', '..', 'V2-D16-freshness', 'map-497ba915.mjs')).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-diff-a2-'));
const entry = (area, q, d) => `### ${area}\n> ${q}\n\n- source: the designer, ${d}\n- when: ["x"]\n`;
const g = (cwd, ...a) => assert.equal(spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd }).status, 0);
const repo = (name, files) => {
  const d = path.join(tmp, name);
  fs.mkdirSync(path.join(d, '.project-map'), { recursive: true });
  for (const [f, s] of Object.entries(files)) fs.writeFileSync(path.join(d, f), s);
  g(d, 'init', '-q');
  g(d, 'add', '-A');
  g(d, 'commit', '-q', '-m', 'init');
  return d;
};
const out = { platform: process.platform };
const check = (id, oldOld, newNew) => { out[id] = { oldGivesOldOutput: oldOld, newGivesNewOutput: newNew }; };
const last = (s) => s.trimEnd().split('\n').at(-1);
const mapLine = (s) => s.split('\n').find((l) => l.startsWith('.project-map/'));

// K1: a map file whose cut leaves one label, and one label line that does not fit at all
{
  const d = repo('k1', { 'README.md': '# r\n' });
  fs.writeFileSync(path.join(d, '.project-map', 'long.md'), Array.from({ length: 5 }, (_, i) => entry(`${i + 1}${'x'.repeat(2300)}`, 'A rule.', '2026-10-27')).join('\n'));
  const tail = '(1 more label%s not shown: treat every entry after entry 4 in this file as unreviewed and unverified.)';
  check('K1 one left', last(OLD.labels(d, '.project-map/long.md')) === tail.replace('%s', 's'), last(NEW.labels(d, '.project-map/long.md')) === tail.replace('%s', ''));
  fs.writeFileSync(path.join(d, '.project-map', 'long.md'), entry('x'.repeat(10_000), 'A rule.', '2026-10-27'));
  const none = '(1 label%s not shown: treat every entry in this file as unreviewed and unverified.)';
  check('K1 none fits', last(OLD.labels(d, '.project-map/long.md')) === none.replace('%s', 's'), last(NEW.labels(d, '.project-map/long.md')) === none.replace('%s', ''));
}

// K2: core.ignorecase set against the platform's default, a tracked captured.md renamed on disk to Captured.md; then
// the same in a linked worktree, whose .git is a file and whose config sits in the common folder
const against = ['win32', 'darwin'].includes(process.platform) ? 'false' : 'true';
out.ignorecaseSet = against;
{
  const d = repo('k2', { 'README.md': '# r\n', '.project-map/captured.md': entry('a', 'b', '2026-10-27') });
  g(d, 'worktree', 'add', '-q', path.join(tmp, 'k2-wt'));
  for (const [id, w] of [['K2', d], ['K2 worktree', path.join(tmp, 'k2-wt')]]) {
    fs.renameSync(path.join(w, '.project-map', 'captured.md'), path.join(w, '.project-map', 'Captured.md'));
    g(w, 'config', 'core.ignorecase', against);
    const git = GIT.index(w);
    out[`${id} listing`] = { git: mapLine(git), old: mapLine(OLD.index(w)), new: mapLine(NEW.index(w)) };
    check(id, OLD.index(w) !== git, NEW.index(w) === git);
  }
}

// K3: with core.ignorecase true, a tracked Ärger.md renamed to ärger.md; git does not fold a non-ASCII letter. Only
// win32 and darwin folded before, so elsewhere the old code already matched git
{
  const d = repo('k3', { 'README.md': '# r\n', '.project-map/Ärger.md': entry('a', 'b', '2026-10-27') });
  fs.renameSync(path.join(d, '.project-map', 'Ärger.md'), path.join(d, '.project-map', 'ärger.md'));
  g(d, 'config', 'core.ignorecase', 'true');
  const git = GIT.index(d);
  out['K3 listing'] = { git: mapLine(git), old: mapLine(OLD.index(d)), new: mapLine(NEW.index(d)) };
  check('K3', ['win32', 'darwin'].includes(process.platform) ? OLD.index(d) !== git : OLD.index(d) === git, NEW.index(d) === git);
}

fs.rmSync(tmp, { recursive: true, force: true });
out.pass = Object.values(out).filter((v) => v && typeof v === 'object' && 'newGivesNewOutput' in v).every((v) => v.oldGivesOldOutput && v.newGivesNewOutput);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `differences-${process.platform}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out, null, 1));
