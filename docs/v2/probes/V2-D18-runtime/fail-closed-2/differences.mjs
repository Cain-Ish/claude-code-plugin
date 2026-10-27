// V2-D18 reopened by the second release review (2026-10-27, 06 step 2g attempt 4): each intended difference between
// the a84a31665af3 library (old/) and the fixed one. The old code must show the defect and the new must not.
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
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-diff2-'));
const entry = (area, q, d) => `### ${area}\n> ${q}\n\n- source: the designer, ${d}\n- when: ["x"]\n`;
const repo = (name) => {
  const d = path.join(tmp, name);
  fs.mkdirSync(path.join(d, '.project-map'), { recursive: true });
  fs.writeFileSync(path.join(d, 'README.md'), '# r\n');
  const git = (...a) => assert.equal(spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: d }).status, 0);
  git('init', '-q');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  return d;
};
const out = {};
const check = (id, oldDefect, newFixed) => { out[id] = { oldShowsDefect: oldDefect, newFixed }; };
const dirs = (n) => `${OLD.HEADER}\n${Array.from({ length: n }, (_, i) => `packages/package-${i}/: README.md`).join('\n')}\n`;

// J1: the cut on 10,000 directories
{
  const huge = dirs(10_000);
  const time = (f) => { const t = performance.now(); f(huge); return performance.now() - t; };
  const o = time(OLD.startText), n = time(NEW.startText);
  out.J1ms = { old: Math.round(o), new: Math.round(n) };
  check('J1', o >= 100, n < 100);
}
// J2: past the cap, an uncommitted map folder's line (the last line of the index) stays listed
{
  const withMap = dirs(400).replace(/\n$/, '\n.project-map/: captured.md\n');
  check('J2', !OLD.startText(withMap).text.includes('.project-map/: captured.md'), NEW.startText(withMap).text.includes('.project-map/: captured.md'));
}
// J3: the labels of 301 entries, the last one uncommitted
{
  const d = repo('j3');
  const f = path.join(d, '.project-map', 'captured.md');
  fs.writeFileSync(f, Array.from({ length: 300 }, (_, i) => entry(`decision ${i + 1}`, `Rule ${i + 1} applies here.`, '2026-10-20')).join('\n'));
  spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qam', 'map'], { cwd: d });
  spawnSync('git', ['add', '-A'], { cwd: d });
  spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'map'], { cwd: d });
  fs.appendFileSync(f, `\n${entry('decision 301', 'Rule 301 applies here.', '2026-10-27')}`);
  const o = OLD.labels(d, '.project-map/captured.md'), n = NEW.labels(d, '.project-map/captured.md');
  out.J3chars = { old: o.length, new: n.length };
  check('J3', o.length > 10_000 && o.trimEnd().endsWith('301: unreviewed, not yet committed; unverified quote, captured 2026-10-27'),
    n.length <= 10_000 && /treat every entry after entry \d+ in this file as unreviewed and unverified\.\)\n$/.test(n));
}
// J4: a UTF-16LE map file, as Windows PowerShell 5.1 writes it
{
  const d = repo('j4');
  const text = `${entry('first', 'A rule.', '2026-10-27')}\n${entry('second', 'Another rule.', '2026-10-27')}`;
  fs.writeFileSync(path.join(d, '.project-map', 'wide.md'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]));
  const o = OLD.labels(d, '.project-map/wide.md'), n = NEW.labels(d, '.project-map/wide.md');
  check('J4', o === '', n.includes('1. first: unreviewed, not yet committed') && n.includes('2. second: unreviewed, not yet committed'));
}

fs.rmSync(tmp, { recursive: true, force: true });
out.pass = Object.values(out).filter((v) => v && typeof v === 'object' && 'newFixed' in v).every((v) => v.oldShowsDefect && v.newFixed);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `differences-${process.platform}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
