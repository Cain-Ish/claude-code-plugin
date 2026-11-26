// 06, section 8, 8o (the final audit's fixes): each mutation of a guard or a pinned sentence 8o adds must fail its test.
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. A mutation is tagged with
// the systems where its killing case runs; elsewhere it is listed as "not here". The unmutated copy runs first and must
// pass, or nothing is counted. The run exits non-zero when a mutation here survives or cannot be applied. Result:
// results/mutate8o-<platform>.txt beside this file, unless MUT_ONLY.
//   node mutate8o.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8o.mjs in place of the self-test; MUT_ONLY=<regex> runs only the mutations it matches, as a
// dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const ANY = 'any';
const HJ = 'hooks/hooks.json', H = 'scripts/hook.mjs', D = 'scripts/dream.mjs', TR = 'scripts/trial.mjs', SU = 'scripts/setup.mjs';
const MR = 'templates/claude/skills/map-review/SKILL.md';
const PS = '"if": "PowerShell(*.project-map*)", "command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs", ';
const M = [
  // 1. PowerShell and Grep take the Bash route; Grep names the map by its path or glob, never its pattern
  ['1 PowerShell after a command', HJ, `"PowerShell",\n        "hooks": [{ "type": "command", ${PS}"bash"]`, `"PowerShellX",\n        "hooks": [{ "type": "command", ${PS}"bash"]`, ANY],
  ['1 PowerShell after a failed command', HJ, `"PowerShell",\n        "hooks": [{ "type": "command", ${PS}"bash-failure"]`, `"PowerShellX",\n        "hooks": [{ "type": "command", ${PS}"bash-failure"]`, ANY],
  ["1 PowerShell's if follows Bash's", HJ, `${PS}"bash"]`, '"command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs", "bash"]', ANY],
  ['1 a new matcher keeps timeout 10', HJ, `${PS}"bash-failure"], "timeout": 10 }]`, `${PS}"bash-failure"], "timeout": 60 }]`, ANY],
  ['1 Grep after a search', HJ, '"matcher": "Grep"', '"matcher": "GrepX"', ANY],
  ['1 Grep has no if on its pattern', HJ, '"Grep",\n        "hooks": [{ "type": "command", "command"', '"Grep",\n        "hooks": [{ "type": "command", "if": "Grep(*.project-map*)", "command"', ANY],
  ["1 a Grep's path or glob names the map", H, "input.tool_name === 'Grep' ? [input.tool_input?.path, input.tool_input?.glob].join(' ') : ", '', ANY],
  ["1 a Grep's glob counts", H, '[input.tool_input?.path, input.tool_input?.glob].join', '[input.tool_input?.path].join', ANY],
  ["1 a Grep's pattern names nothing", H, '[input.tool_input?.path, input.tool_input?.glob].join', '[input.tool_input?.path, input.tool_input?.glob, input.tool_input?.pattern].join', ANY],
  // 2. memory: user refused as a power; project, local and none stay allowed; one plain spelling
  ['2 an agent with memory: user refused', D, "    if (userMemory(fm)) { drop('agent with memory: user, or a memory other than project or local'); continue; }\n", '', ANY],
  ['2 a change with memory: user refused', D, "    if (userMemory(fm)) { drop('change with memory: user, or a memory other than project or local'); continue; }\n", '', ANY],
  ['2 memory: local allowed', D, '(project|local)\\1', '(project)\\1', ANY],
  ['2 no memory key allowed', D, "const userMemory = (fm) => Boolean(entry(fm, 'memory')) && ", 'const userMemory = (fm) => ', ANY],
  ['2 the key spelled once', D, "\\1[ \\t]*$/.test(entry(fm, 'memory'))", "\\1[ \\t]*$/m.test(entry(fm, 'memory'))", ANY],
  // 3. map-review waits for each answer, and shows others' changes before the commit; its 2.6.0 text for setup
  ['3 a proposal waits for the answer', MR, " Wait for the user's answer before any edit.", '', ANY],
  ['3 a draft waits for the answer', MR, ", and wait for the user's answer before any edit", '', ANY],
  ["3 others' changes shown before the commit", MR, " Before it, show any change in\n   those files that this review did not make (`git diff HEAD -- <those files>`), and commit a file that holds one\n   only on the user's yes.", '', ANY],
  ["3 map-review's 2.6.0 text listed for setup", SU, "'2c564cbd2d263dac', ", '', ANY],
  // 4. show warns of a bare Bash only
  ["4 show's bare Bash sentence", TR, "${(c.tools ?? []).some((t) => t.trim() === 'Bash') ? '\\n  Bash with no pattern: its sessions may run any command as you, outside the copy too.' : ''}", '', ANY],
  ['4 a Bash with a pattern is not bare', TR, "(c.tools ?? []).some((t) => t.trim() === 'Bash')", "(c.tools ?? []).some((t) => t.trim().startsWith('Bash'))", ANY],
];
const here = (os) => os === ANY || process.platform === os;
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['fix8o.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix8o' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
// each test in turn, stopping at the first that fails; the failing lines name the cases
const runIn = (dir) => {
  for (const t of tests) {
    const r = spawnSync(process.execPath, [path.join(dir, 'plugin', 'test', t)], { encoding: 'utf8', timeout: 1_200_000 });
    if (r.status !== 0) return { ...r, test: t };
  }
  return { status: 0, stdout: '', stderr: '' };
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
  console.log(`the unmutated copy fails ${baseRun.test}, so no mutation is counted:\n${baseRun.stdout.split('\n').filter((l) => l.startsWith('FAIL')).join('\n')}${baseRun.stderr.slice(-600)}`);
  process.exit(2);
}
let bad = 0, ran = 0;
for (const [name, file, a, b, os] of M) {
  if (only && !only.test(name)) continue;
  if (!here(os)) { lines.push(`not here  ${name} (${os})`); console.log(lines.at(-1)); continue; }
  ran++;
  copy(dir);
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (src.split(a).length !== 2) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, () => b));
  const r = runIn(dir);
  const killed = r.status !== 0;
  if (!killed) bad++;
  const by = (r.stdout ?? '').split('\n').filter((l) => l.startsWith('FAIL')).map((l) => l.slice(6).split(':')[0]);
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${killed ? ` (by ${r.test}${by.length ? `: ${by.join('; ')}` : `, exit ${r.status}${r.error ? ` ${r.error.code}` : ''}`})` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8o-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
