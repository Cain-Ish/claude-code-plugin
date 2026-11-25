// 06, section 8, 8k, group C (the trial side), check 2: each mutation of a guard group C adds must fail its tests. Each
// runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. The tests run with no claude on
// PATH, so no mutation can start a real session. Moved anchors of 8e's and 8i's lists are carried here, named so, as 8i
// did. The unmutated copy runs first and must pass, or nothing is counted. The run exits non-zero when a mutation
// survives or cannot be applied. Result: results/mutate8k-trial-<platform>.txt beside this file.
//   node mutate8k-trial.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/trial8e.mjs and test/fix8k-trial.mjs alone in place of the self-test; MUT_ONLY=<regex> runs only
// the mutations it matches, as a dry run. Until group B's PRIVATE lands, fix8k-trial's D-2 case fails on the trial
// side's copy alone, so the plugin folder given carries 8a's PRIVATE
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const T = 'scripts/trial.mjs';
const REMOVAL = "      if (copy && !clear(copy)) {\n        await new Promise((ok) => setTimeout(ok, 1000));\n        if (!clear(copy)) left.push(path.basename(copy));\n      }\n";
const M = [
  // H7: git and claude by full path
  ['H7 the git helper by full path', T, "const git = (cwd, ...args) => spawnSync(exe('git'), args", "const git = (cwd, ...args) => spawnSync('git', args"],
  ['H7 git show by full path', T, "const blob = (root, commit, rel) => spawnSync(exe('git')", "const blob = (root, commit, rel) => spawnSync('git'"],
  ['H7 git cat-file by full path', T, "spawnSync(exe('git'), ['cat-file', '--batch']", "spawnSync('git', ['cat-file', '--batch']"],
  ['H7 git hash-object by full path', T, "spawnSync(exe('git'), ['hash-object', '--stdin'", "spawnSync('git', ['hash-object', '--stdin'"],
  ['H7 claude by full path', T, "[exe('claude'), childArgs(prompt, tools)]", "['claude', childArgs(prompt, tools)]"],
  // the audit's item 7, and the small one
  ['Audit 7 committed() reads, never writes', T, "const at = git(root, 'rev-parse', '--verify', '-q', `${commit}:${rel}`); return at.status === 0 && at.stdout.trim() === git(root, 'hash-object', '--', rel).stdout.trim();",
    "return git(root, 'cat-file', '-e', `${commit}:${rel}`).status === 0 && git(root, 'diff', '--quiet', commit, '--', rel).status === 0;"],
  ['Audit the path after the first tab', T, "const t = l.indexOf('\\t'); const [mode, type, oid] = l.slice(0, t).split(' '); return { mode, type, oid, p: l.slice(t + 1) };",
    "const [meta, p] = l.split('\\t'); const [mode, type, oid] = meta.split(' '); return { mode, type, oid, p };"],
  // B-4, B-5, B-2
  ['B-4 a binary file named', T, "(e.body.includes(0) ? `The file ${e.rel} is binary (${e.body.length} bytes), so it is not shown.` : `The file ${e.rel}:\\n${quote(e.body.toString('utf8'))}`)", "`The file ${e.rel}:\\n${quote(e.body.toString('utf8'))}`"],
  ['B-5 one retry', T, "        await new Promise((ok) => setTimeout(ok, 1000));\n        if (!clear(copy)) left.push", '        left.push'],
  ['B-2 the files before the folder', T, 'for (const e of fs.readdirSync(dir)) try { fs.rmSync(path.join(dir, e), { recursive: true, force: true }); } catch {} ', ''],
  // L-14
  ['L-14 run takes the lock (carries 8i-5 "run stops while a trial runs")', T, "  const lock = take(root);\n  const c = spawn(", '  if (holder(root)) throw new Error(RUNNING);\n  const c = spawn(', [["  fs.writeFileSync(lock, String(c.pid));\n", '']]],
  ["L-14 the lock names run's child", T, "  fs.writeFileSync(lock, String(c.pid));\n", ''],
  ['L-14 exec takes the lock handed to it', T, 'token && [token, String(process.pid)].includes(held) ? lockOf(root) : take(root)', 'take(root)'],
  ['L-14 exec knows the token', T, '[token, String(process.pid)].includes(held)', '[String(process.pid)].includes(held)'],
  ['L-14 a refused exec records nothing', T, "if (e.message !== RUNNING && /^[\\w.-]+$/", "if (/^[\\w.-]+$/"],
  // X-3
  ['X-3 file tools not approved', T, "const allowed = tools.filter((t) => !FILE_TOOLS.includes(t.replace(/\\(.*$/s, '').trim()));", 'const allowed = tools;'],
  ["X-3 the session's environment an allowlist", T, '.filter(([k]) => KEEP.test(k) || cloud(k))', ''],
  ["X-3 AWS's credentials only for a Bedrock login", T, 'on(process.env.CLAUDE_CODE_USE_BEDROCK) && /^AWS_/i.test(k)', '/^AWS_/i.test(k)'],
  ["X-3 a Bedrock login keeps AWS's credentials", T, 'const cloud = (k) => (on(process.env.CLAUDE_CODE_USE_BEDROCK)', 'const cloud = (k) => false && (on(process.env.CLAUDE_CODE_USE_BEDROCK)'],
  // 8e's and 8i's, anchored again where 8k moved them
  ['(8e 1) committed as git compares, moved', T, "git(root, 'hash-object', '--', rel)", "git(root, 'hash-object', '--no-filters', '--', rel)"],
  ['(8e 1) unchanged since the commit, moved', T, "return at.status === 0 && at.stdout.trim() === git(root, 'hash-object', '--', rel).stdout.trim();", 'return at.status === 0;'],
  ['(8e 5) a stopped trial recorded, moved', T, "if (e.message !== RUNNING && /^[\\w.-]+$/.test(String(rest[0] ?? ''))) try { record(", 'if (false) try { record('],
  ['(8i-3) C-2 the text of each file beside it, moved', T, ", ...info.extras.map((e) => (e.body.includes(0) ? `The file ${e.rel} is binary (${e.body.length} bytes), so it is not shown.` : `The file ${e.rel}:\\n${quote(e.body.toString('utf8'))}`))", ''],
  ['(8i-6) K-3 a copy not removed is named, and the trial goes on, moved', T, REMOVAL, '      if (copy) fs.rmSync(copy, { recursive: true, force: true });\n'],
  ['(8e 5) the copies deleted, moved', T, REMOVAL, ''],
  // the review's findings (Gemini, 8k): a file tool with a rule, NotebookEdit, and a cloud login switched off with 0
  ['review: a file tool with a rule not approved', T, "FILE_TOOLS.includes(t.replace(/\\(.*$/s, '').trim())", 'FILE_TOOLS.includes(t.trim())'],
  ['review: NotebookEdit not approved', T, "'MultiEdit', 'NotebookEdit', ", "'MultiEdit', "],
  ['review: a login switched off with 0', T, "Boolean(v) && !/^(0|false)$/i.test(v)", 'Boolean(v)'],
  ['(8e 5) one session at a time, moved', T, '  for (const { arm, c } of jobs) {\n', '  await Promise.all(jobs.map(async ({ arm, c }) => {\n',
    [['{ failed++; continue; }', '{ failed++; return; }'], ['        if (!clear(copy)) left.push(path.basename(copy));\n      }\n    }\n  }\n', '        if (!clear(copy)) left.push(path.basename(copy));\n      }\n    }\n  }));\n']]],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['trial8e.mjs', 'fix8k-trial.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'trial8e and fix8k-trial alone' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
// no claude on PATH, in any letter case of the variable
const PATH = (process.env.PATH ?? '').split(path.delimiter).filter((d) => d && !['claude', 'claude.exe', 'claude.cmd', 'claude.com'].some((f) => fs.existsSync(path.join(d, f)))).join(path.delimiter);
const env = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^path$/i.test(k))), PATH };
const runIn = (dir) => {
  const out = tests.map((t) => spawnSync(process.execPath, [path.join(dir, 'plugin', 'test', t)], { encoding: 'utf8', env, timeout: 1_200_000 }));
  return { status: out.some((r) => r.status !== 0) ? 1 : 0, stdout: out.map((r) => r.stdout).join('\n'), stderr: out.map((r) => r.stderr).join('\n') };
};
const copy = (dir) => {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
};
const dir = path.join(work, 'm');
copy(dir);
const baseRun = runIn(dir);
if (baseRun.status !== 0) {
  console.log(`the unmutated copy fails ${tests.join(' or ')}, so no mutation is counted:\n${baseRun.stdout.split('\n').filter((l) => l.startsWith('FAIL')).join('\n')}${baseRun.stderr.slice(-600)}`);
  process.exit(2);
}
// the cases by name, from the unmutated run, so each kill names the case that made it
const cases = baseRun.stdout.split('\n').filter((l) => l.startsWith('pass  ')).map((l) => l.slice(6));
let bad = 0, ran = 0;
for (const [name, file, a, b, extra = []] of M) {
  if (only && !only.test(name)) continue;
  ran++;
  copy(dir);
  const target = path.join(dir, 'plugin', file);
  let src = fs.readFileSync(target, 'utf8');
  const pairs = [[a, b], ...extra];
  if (pairs.some(([x]) => src.split(x).length !== 2)) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  for (const [x, y] of pairs) src = src.replace(x, () => y);
  fs.writeFileSync(target, src);
  const r = runIn(dir);
  const killed = r.status !== 0;
  if (!killed) bad++;
  const by = r.stdout.split('\n').filter((l) => l.startsWith('FAIL')).map((l) => cases.find((c) => l.slice(6).startsWith(`${c}:`)) ?? l.slice(6, 60));
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${by.length ? ` (by ${by.join('; ')})` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8k-trial-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
