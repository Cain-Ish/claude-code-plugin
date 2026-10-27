// V2-D18 reopened (2026-10-27, 06 step 2g attempt 3): each intended difference between the 61964f9bbb40 hooks (old/)
// and the fixed ones, run as Claude Code runs them. The old code must show the defect and the new must not.
//   node differences.mjs [new plugin dir, default the repo's plugin/]     Prints and saves counts and verdicts only.
// The attempt ran against a plugin copy here, moved into plugin/ after it passed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OLD = path.join(HERE, 'old', 'scripts', 'hook.mjs');
const NEW = path.join(path.resolve(process.argv[2] ?? path.join(HERE, '..', '..', '..', '..', '..', 'plugin')), 'scripts', 'hook.mjs');
const NAME_START = 'When you finish, name each';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-diff-'));
const run = (hook, which, input, dir, env = {}) => {
  const r = spawnSync('node', [hook, which], { input: JSON.stringify({ cwd: dir, session_id: `diff-${process.pid}`, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: dir, ...env } });
  let ctx = '';
  try { ctx = JSON.parse(r.stdout).hookSpecificOutput.additionalContext; } catch {}
  spawnSync('node', [hook, 'prompt'], { input: JSON.stringify({ session_id: `diff-${process.pid}` }), encoding: 'utf8' });
  return { status: r.status, ctx };
};
const repo = (name, files, after = {}) => {
  const d = path.join(tmp, name);
  const put = (f, s) => { fs.mkdirSync(path.dirname(path.join(d, f)), { recursive: true }); fs.writeFileSync(path.join(d, f), s); };
  fs.mkdirSync(d);
  const git = (...a) => assert.equal(spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.autocrlf=false', ...a], { cwd: d }).status, 0);
  git('init', '-q');
  for (const [f, s] of Object.entries(files)) put(f, s);
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  for (const [f, s] of Object.entries(after)) put(f, s);
  return d;
};
const entry = (area, q, src) => `### ${area}\n> ${q}\n\n- source: ${src}\n- when: ["x"]\n`;
const out = {};
const check = (id, oldDefect, newFixed) => { out[id] = { oldShowsDefect: oldDefect, newFixed }; };

// I1: a session started in a subdirectory
{
  const d = repo('i1', { 'docs/a.md': '# a\n', 'README.md': '# r\n', '.project-map/captured.md': entry('one', 'First rule here.', 'the lead, 2026-10-20') },
    { '.project-map/captured.md': `${entry('one', 'First rule here.', 'the lead, 2026-10-20')}\n${entry('two', 'Second rule here.', 'the lead, 2026-10-27')}` });
  const sub = path.join(d, 'docs');
  const read = { tool_input: { file_path: path.join(d, '.project-map', 'captured.md') } };
  const atRoot = run(NEW, 'read', read, d).ctx;
  const o = run(OLD, 'read', read, sub), n = run(NEW, 'read', read, sub);
  const os1 = run(OLD, 'session-start', {}, sub), ns1 = run(NEW, 'session-start', {}, sub), nr1 = run(NEW, 'session-start', {}, d);
  // the index line, not the instruction's own mention of the folder
  check('I1', o.ctx === '' && !os1.ctx.includes('.project-map/: '), n.ctx === atRoot && n.ctx.includes('unreviewed') && ns1.ctx === nr1.ctx);
}
// I4: one cited source that exists but cannot be read (Windows: a deny ACE; elsewhere: mode 000)
{
  const d = repo('i4', { 'docs/locked.md': 'Locked text that is cited here.\n', 'docs/open.md': 'Open text that is cited here.\n' },
    { '.project-map/captured.md': `${entry('open', 'Open text that is cited here.', 'docs/open.md, 2026-10-27')}\n${entry('locked', 'Locked text that is cited here.', 'docs/locked.md, 2026-10-27')}` });
  const f = path.join(d, 'docs', 'locked.md');
  const lock = process.platform === 'win32'
    ? () => spawnSync('icacls', [f, '/deny', `${os.userInfo().username}:(R)`], { encoding: 'utf8' })
    : () => fs.chmodSync(f, 0);
  const unlock = process.platform === 'win32' ? () => spawnSync('icacls', [f, '/remove:d', os.userInfo().username]) : () => fs.chmodSync(f, 0o644);
  lock();
  let readable = true;
  try { fs.readFileSync(f); } catch { readable = false; }
  const read = { tool_input: { file_path: path.join(d, '.project-map', 'captured.md') } };
  const o = run(OLD, 'read', read, d), n = run(NEW, 'read', read, d);
  unlock();
  out.I4lockWorked = !readable;
  check('I4', o.ctx === '' && o.status !== 0, n.status === 0 && n.ctx.includes('1. open: unreviewed, not yet committed') && n.ctx.includes('2. locked: unreviewed, not yet committed; cannot read docs/locked.md'));
}
// I4, the read hook as a whole: a map path the library cannot read (here a folder named like a map file)
{
  const d = repo('i4b', { 'README.md': '# r\n' });
  fs.mkdirSync(path.join(d, '.project-map', 'folder.md'), { recursive: true });
  const read = { tool_input: { file_path: path.join(d, '.project-map', 'folder.md') } };
  const o = run(OLD, 'read', read, d), n = run(NEW, 'read', read, d);
  check('I4-file', o.ctx === '', n.ctx.includes('could not be computed') && n.ctx.includes('unreviewed'));
}
// I9: no writable TEMP for the forced decision's marker
{
  const d = repo('i9', { 'README.md': '# r\n' });
  const gone = path.join(tmp, 'no-such-temp');
  const env = { TEMP: gone, TMP: gone, TMPDIR: gone };
  const o = run(OLD, 'session-start', {}, d, env), n = run(NEW, 'session-start', {}, d, env), ok = run(NEW, 'session-start', {}, d);
  check('I9', o.status !== 0 && o.ctx === '', n.status === 0 && n.ctx === ok.ctx);
}
// I11: a tracked map file renamed on disk only in letter case (win32 and darwin, where the file system ignores case)
if (['win32', 'darwin'].includes(process.platform)) {
  const d = repo('i11', { '.project-map/Decisions.md': entry('a', 'b', 'x, 2026-10-20') });
  fs.renameSync(path.join(d, '.project-map', 'Decisions.md'), path.join(d, '.project-map', 'decisions.md'));
  const count = (ctx) => (ctx.match(/ecisions\.md/g) ?? []).length;
  const o = run(OLD, 'session-start', {}, d), n = run(NEW, 'session-start', {}, d);
  check('I11', count(o.ctx) === 2, count(n.ctx) === 1);
}
// I13: a byte-order mark at the start of an uncommitted map file
{
  const d = repo('i13', { 'README.md': '# r\n' }, { '.project-map/captured.md': `﻿${entry('first', 'A rule.', 'the lead, 2026-10-27')}\n${entry('second', 'Another rule.', 'the lead, 2026-10-27')}` });
  const read = { tool_input: { file_path: path.join(d, '.project-map', 'captured.md') } };
  const o = run(OLD, 'read', read, d), n = run(NEW, 'read', read, d);
  check('I13', !o.ctx.includes('first'), n.ctx.includes('1. first: unreviewed') && n.ctx.includes('2. second: unreviewed'));
}
// I2: an index past Claude Code's 10,000-character cap on one hook output
{
  const files = Object.fromEntries(Array.from({ length: 350 }, (_, i) => [`packages/package-${String(i).padStart(3, '0')}/README.md`, '# p\n']));
  const d = repo('i2', files);
  const o = run(OLD, 'session-start', {}, d), n = run(NEW, 'session-start', {}, d);
  out.I2sizes = { old: o.ctx.length, new: n.ctx.length };
  check('I2', o.ctx.length > 10_000, n.ctx.length <= 10_000 && n.ctx.includes(NAME_START) && /\(\d+ more directories not listed/.test(n.ctx));
}

fs.rmSync(tmp, { recursive: true, force: true });
out.pass = out.I4lockWorked && Object.values(out).filter((v) => v && typeof v === 'object' && 'newFixed' in v).every((v) => v.oldShowsDefect && v.newFixed);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `differences-${process.platform}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
