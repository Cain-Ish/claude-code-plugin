// 06, section 8, 8e, check 2: each mutation of a guard 8e adds must fail the self-test (which runs test/trial8e.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. Every case runs on every
// system. The run exits non-zero when a mutation survives or cannot be applied. Result:
// results/mutate8e-<platform>.txt beside this file.
//   node mutate8e.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/trial8e.mjs alone, and MUT_ONLY=<regex> only the mutations it matches: each a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const TR = 'scripts/trial.mjs', TL = 'skills/tailor/SKILL.md', MR = 'templates/claude/skills/map-review/SKILL.md';
const M = [
  ['(1) fields it does not know', TR, "  if (unknown(spec, FIELDS).length) errs.push(`fields it does not know: ${unknown(spec, FIELDS).join(', ')}`);\n", ''],
  ['(1) a tool that reads as a flag', TR, " || t.trim().startsWith('-')", ''],
  ['(1) a check under the checks folder', TR, '!k.startsWith(CHECKS) || ', ''],
  ['(1) a check path that climbs', TR, "k.split('/').includes('..') || ", ''],
  ['(1) three cases or more', TR, 'if (cases.length < 3)', 'if (cases.length < 2)'],
  ['(1) a case where it should not be used', TR, "  if (!cases.some((c) => c?.use === false)) errs.push('one case where it should not be used (use: false)');\n", ''],
  ['(1) the privacy scan', TR, "  if (PRIVATE.test(text)) errs.push('it holds private data: a secret, a session id, an email address or an absolute path');\n", ''],
  ["(1) the artifact's home", TR, "if (!HOMES.test(a) || a.split('/').includes('..'))", 'if (false)'],
  ['(1) only what a commit has seen', TR, "if (!headHeld(root, f)) throw new Error(`${f} must be committed and unchanged since: only what a commit has seen runs`);", ''],
  ['(2) run checks the hash', TR, "  if (hash !== now) throw new Error(`the hash ${hash || '(none)'}", "  if (false) throw new Error(`the hash ${hash || '(none)'}"],
  ["(2) show prints the artifact's grants", TR, "grants.length ? `What the artifact itself grants or runs:", "false ? `What the artifact itself grants or runs:"],
  ['(3) no evals in a copy', TR, ' && !`${e.p}/`.startsWith(`${MAP}/evals/`)', ''],
  ['(3) hooks off', TR, "'--settings', JSON.stringify({ disableAllHooks: true }), ", ''],
  ['(3) no MCP server', TR, "'--strict-mcp-config', ...(tools.length", '...(tools.length'],
  ['(3) acceptEdits stated', TR, "'--permission-mode', 'acceptEdits',\n", '\n'],
  ['(3) the nested-session variables removed', TR, "for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e;", 'return e;'],
  ['(3) a change against the file as it is', TR, 'without: change ? fs.readFileSync(path.join(root, live), \'utf8\') : null', 'without: null'],
  ['(3) a draft never stays in a copy', TR, '  fs.rmSync(`${live}.draft`, { force: true });\n', ''],
  ['(4) "mixed" wins over the totals', TR, "  if (rows.some((r) => r.with > r.without) && rows.some((r) => r.with < r.without)) return 'mixed';\n", ''],
  ['(4) a should-not case that fails is "hurts"', TR, "if (rows.some((r) => r.use === false && r.with < r.runs)) return 'hurts';", ''],
  ['(5) the check runs outside the copy', TR, 'spawnSync(process.execPath, [checks[c.check]], { cwd: copy,', 'spawnSync(process.execPath, [path.join(copy, c.check)], { cwd: copy,'],
  ['(5) the verdict git-ignored', TR, "  fs.writeFileSync(path.join(dir, '.gitignore'), '*\\n');\n", ''],
  ['(5) the copies deleted', TR, '  fs.rmSync(work, { recursive: true, force: true });\n  const rows', '  const rows'],
  ['(6) an agent draft names its tools', TR, "kind === 'agent' ? ['name', 'description', 'tools']", "kind === 'agent' ? ['name', 'description']"],
  ['(6) a draft with private data', TR, "    if (PRIVATE.test(fs.readFileSync(from, 'utf8'))) throw new Error(`${path.basename(from)} holds private data`);\n", ''],
  ['(6) a draft never over a file', TR, "    if (fs.existsSync(path.join(root, to)) || fs.existsSync(path.join(root, to.replace(/\\.draft$/, '')))) throw new Error(`${to} or its live file exists; nothing is overwritten`);\n", ''],
  ['(6) a draft never through a link', TR, "if (!fs.lstatSync(src, { throwIfNoEntry: false })?.isDirectory() || !inRepo(root, src))", 'if (false)'],
  ['(7) tailor only a person starts', TL, 'disable-model-invocation: true\n', ''],
  ['(7) tailor never runs the trial itself', TL, 'Never run `trial.mjs show`, `run` or `exec` yourself', 'You may run trial.mjs'],
  ['(7) map-review calls a changed draft stale', MR, 'call it stale', 'note it'],
  ['(7) map-review removes only on a yes', MR, 'Remove it only on', 'Remove it on'],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'trial8e alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
let bad = 0, ran = 0;
for (const [name, file, a, b] of M) {
  if (only && !only.test(name)) continue;
  ran++;
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (src.split(a).length !== 2) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'trial8e.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8e-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
