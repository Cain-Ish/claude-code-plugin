// 06, section 8, 8i, check 2: each mutation of a guard 8i adds must fail the self-test (which runs test/trial8e.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. Case (8i-6) runs on Windows
// only (a folder that is a working folder cannot be deleted there), so its mutation is killed on Windows and skipped
// elsewhere. The last four are 8e's mutations whose anchors 8i moved, anchored again. The run exits non-zero when a
// mutation survives or cannot be applied. Result: results/mutate8i-<platform>.txt beside this file.
//   node mutate8i.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/trial8e.mjs alone; MUT_ONLY=<regex> only the mutations it matches, a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const TR = 'scripts/trial.mjs';
const M = [
  // 1, X-1
  ['(8i-1) X-1: the main file by its exact name', TR, '!names.includes(main) || ', ''],
  ['(8i-1) X-1: nothing beside it named as the main file or a draft', TR, '  if (odd) throw', '  if (false) throw'],
  // 2, P-1, C-3, K-2
  ['(8i-2) P-1: artifactBlob of the text that ran', TR, 'hash, artifactBlob, casesBlob, date', "hash, artifactBlob: git(root, 'hash-object', '--', t.spec.artifact).stdout.trim(), casesBlob, date"],
  ["(8i-2) P-1: casesBlob at the trial's commit", TR, 'hash, artifactBlob, casesBlob, date', "hash, artifactBlob, casesBlob: git(root, 'hash-object', '--', t.rel).stdout.trim(), date"],
  // 3, C-1, C-2
  ['(8i-3) C-1: a fenced ! block whole', TR, ' fenced = fenced ? !/^\\s*```\\s*$/.test(l) : /^\\s*```!/.test(l);', ''],
  ["(8i-3) C-2: the artifact's whole text", TR, '    `Its whole text, which "with" runs:\\n${quote(info.text)}`,\n', ''],
  ['(8i-3) C-2: the text of each file beside it', TR, ", ...info.extras.map((e) => (e.body.includes(0) ? `The file ${e.rel} is binary (${e.body.length} bytes), so it is not shown.` : `The file ${e.rel}:\\n${quote(e.body.toString('utf8'))}`))", ''],
  // 4, C-7
  ['(8i-4) C-7: no staging folder in a copy', TR, ' && !`${e.p}/`.startsWith(`${MAP}/drafts/`)', ''],
  // 5, C-8, K-7, P-15
  ['(8i-5) C-8: run stops while a trial runs', TR, 'const lock = take(root);', 'const lock = lockOf(root);'],
  ['(8i-5) C-8: exec never takes a held lock', TR, "String(process.pid), { flag: 'wx' }", 'String(process.pid)'],
  ['(8i-5) C-8: a lock whose process ended is taken over', TR, '  if (!holder(root)) fs.rmSync(lock, { force: true });\n', ''],
  ['(8i-5) C-8: only a live process holds the lock', TR, 'pid > 0 && process.kill(pid, 0) ? pid : 0', 'pid'],
  ['(8i-5) C-8: the lock gone when the verdict lands', TR, '  record(root, name, out);\n  fs.rmSync(lock, { force: true });\n', '  record(root, name, out);\n'],
  ['(8i-5) C-8: the lock git-ignored', TR, "const lock = path.join(put(root, []), '.lock');", 'const lock = lockOf(root); fs.mkdirSync(path.dirname(lock), { recursive: true });'],
  // 6, K-3
  ['(8i-6) K-3: a copy not removed is named, and the trial goes on', TR, 'if (!clear(copy)) left.push(path.basename(copy));', "if (!clear(copy)) throw new Error('copy left');"],
  // 7, K-4
  ['(8i-7) K-4: a YAML block list', TR, '(?:\\\\S|\\\\r?\\\\n[ \\\\t]*-[ \\\\t]+\\\\S)', '\\\\S'],
  // 8, K-8
  ['(8i-8) K-8: a session that cannot start says why', TR, 'fail({ why: `claude could not be started', 'done(false, { why: `claude could not be started'],
  // 9, X-7
  ['(8i-9) X-7: a failed read stops the copy', TR, '    if (body.length !== size) throw', '    if (false) throw'],
  // 10, amended: no project folder left
  ["(8i-10) the copy's project folder removed", TR, '      if (copy) forget(copy);\n', ''],
  ['(8i-10) never a project folder holding a transcript', TR, "if (!fs.readdirSync(dir, { recursive: true }).some((f) => String(f).endsWith('.jsonl'))) fs.rmSync(dir", 'if (true) fs.rmSync(dir'],
  // 8e's, anchored again where 8i moved them
  ['(8e 5) the blob ids recorded', TR, 'hash, artifactBlob, casesBlob, date', 'hash, casesBlob, date'],
  ['(8e 5) the copies deleted', TR, 'if (copy && !clear(copy)) {', 'if (false) {'],
  ['(8e 5) one session at a time', TR, '  for (const { arm, c } of jobs) {\n', '  await Promise.all(jobs.map(async ({ arm, c }) => {\n',
    [['{ failed++; continue; }', '{ failed++; return; }'], ['        if (!clear(copy)) left.push(path.basename(copy));\n      }\n    }\n  }\n', '        if (!clear(copy)) left.push(path.basename(copy));\n      }\n    }\n  }));\n']]],
  ['(8e 6) an empty field is no value', TR, '`^${k}:[ \\\\t]*(?:', '`^${k}:\\\\s*(?:'],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const lines = [`platform ${process.platform}, copy ${path.basename(plugin)}, ${fast ? 'trial8e.mjs alone' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
let bad = 0, ran = 0;
// a mutation may carry more [from, to] pairs, applied with it; each must occur once
for (const [name, file, a, b, more = []] of M) {
  if (only && !only.test(name)) continue;
  // case (8i-6) holds a folder open, which only Windows refuses to delete
  if (/^\(8i-6\)/.test(name) && process.platform !== 'win32') { lines.push(`skipped   ${name} (Windows only)`); console.log(lines.at(-1)); continue; }
  ran++;
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  const pairs = [[a, b], ...more];
  if (pairs.some(([x]) => src.split(x).length !== 2)) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, pairs.reduce((s, [x, y]) => s.replace(x, () => y), src));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'trial8e.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${killed ? `: ${(r.stdout.match(/^FAIL {2}(\([^)]+\)[^:\n]*)/gm) ?? ['(no case named)']).map((l) => l.slice(6)).join('; ')}` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8i-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
