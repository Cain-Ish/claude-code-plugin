// 06, section 6, check 1: each mutation of setup.mjs's update path must fail the self-test. Each runs in a copy of
// plugin/ under <work>/m, with the product-hash pin off (any edit trips it). Result: results/mutate6.txt.
//   node mutate6.mjs <repo root> <work folder>
// The last run's results/mutate6.txt was made before the self-test's second-run assertion was added (06, section 6).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const [repo, work] = process.argv.slice(2);
const M = [
  ['hash match', '!earlier.includes(sum(read(to)))', 'false'],
  ['guard on update', 'if (safe(to)) try {', 'if (true) try {'],
  ['write error caught', 'continue; } catch {}', 'continue; } finally {}'],
  ['stuck apart from differ', ' && !stuck.includes(to) &&', ' &&'],
  ['the stuck line', 'if (stuck.length) out.push(', 'if (0) out.push('],
  ['single link', 's.isFile() && s.nlink === 1;', 's.isFile();'],
  ['the write', 'fs.writeFileSync(path.join(root, to), ', '((a, b) => b)(path.join(root, to), '],
  ['line ending', '.join(eolOf(read(to))));', ".join('\\n'));"],
  ['wrote counts updates', 'const wrote = created.length || added.size || updated.length;', 'const wrote = created.length || added.size;'],
  ['closing line', "out.push(wrote ? 'Nothing is committed: review the new files in the diff, and commit them.' : 'Nothing was written.');", "out.push('Nothing is committed: review the new files in the diff, and commit them.');"],
  ['tracked', "git(root, 'ls-files', '-v', '--', f).stdout === `H ${f}\\n`", 'true'],
  ['unchanged', '&& unchanged(f);\n  };', ';\n  };'],
  ['kept excludes updated', ' && !updated.includes(f));', ');'],
  ['ran, not written', "${wrote ? 'Written' : 'Ran'}", 'Written'],
  ['the diff in the report', '    if (at < 0) continue;', '    continue;'],
  ['a listed hash',"'ee1a057e8299bc76'", "'ee1a057e8299bc77'"],
];
const src = fs.readFileSync(path.join(repo, 'plugin/scripts/setup.mjs'), 'utf8');
let survived = 0;
for (const [name, a, b] of M) {
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(path.join(repo, 'plugin'), path.join(dir, 'plugin'), { recursive: true });
  if (!src.includes(a)) { console.log(`MISSING ${name}`); survived++; continue; }
  fs.writeFileSync(path.join(dir, 'plugin/scripts/setup.mjs'), src.replace(a, b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [t], { encoding: 'utf8', timeout: 600000 });
  const killed = r.status !== 0;
  if (!killed) survived++;
  console.log(`${killed ? 'killed  ' : 'SURVIVED'} ${name}${killed ? `: ${(r.stderr.match(/selftest\.mjs:(\d+)/) ?? [])[0] ?? ''}` : ''}`);
}
console.log(`survived ${survived} of ${M.length}`);
