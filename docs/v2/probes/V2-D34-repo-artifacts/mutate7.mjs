// 06, section 7, 7a, check 1: each mutation of a trial guard must fail the self-test. Each runs in a copy of the
// candidate plugin under <work>/m, with the product-hash pin off (any edit trips it). Result: results/mutate7.txt.
//   node mutate7.mjs <plugin folder> <work folder>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const T = 'scripts/trial.mjs', K = 'skills/tailor/SKILL.md', S = 'scripts/setup.mjs';
const R = 'templates/project-map/README.md', V = 'templates/claude/skills/map-review/SKILL.md';
const M = [
  ['(i) data folder inside the repo refused', T, 'if (inRepo(root, base)) throw', 'if (false) throw'],
  ['(i) ignored files left out', T, "'-co', '--exclude-standard'", "'-co'"],
  ['(i) a fresh repository, not the repo\'s .git', T, "  git(to, 'init', '-q');\n  git(to, 'add', '-A');", "  fs.cpSync(path.join(root, '.git'), path.join(to, '.git'), { recursive: true });\n  git(to, 'add', '-A');"],
  ['(ii) the artifact placed in "with"', T, "if (arm === 'with') {", 'if (false) {'],
  ['(ii) the draft file removed', T, 'if (artifact !== info.live) fs.rmSync', 'if (false) fs.rmSync'],
  ['(ii) nothing at the live path in "without"', T, "if (arm === 'without') fs.rmSync(live", 'if (false) fs.rmSync(live'],
  ['(iii) a skill by exact name', T, ".split(':').pop() === name", '.includes(name)'],
  ['(iii) an agent by exact type', T, "String(t.input?.subagent_type ?? '') === name", "String(t.input?.subagent_type ?? '').startsWith(name)"],
  ['(iv) nesting variables removed', T, "for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k];", ''],
  ['(v) copies deleted', T, "fs.rmSync(copy, { recursive: true, force: true }); // (v)\n    }\n  }));\n  fs.rmSync(path.join(base, 'copies'), { recursive: true, force: true });", '}\n  }));'],
  ['(vi) three cases', T, 'cases.length < 3', 'cases.length < 2'],
  ['(vi) a should-not case', T, '!cases.some((c) => c?.use === false)', 'false'],
  ['(vi) an outcome per case', T, "if (typeof c?.expect !== 'string' || !c.expect.trim())", 'if (false)'],
  ['(vi) the privacy scan', T, 'if (PRIVATE.test(JSON.stringify(cases)))', 'if (false)'],
  ['(vi) the three homes', T, "if (!HOMES.test(a)) errs.push", 'if (false) errs.push'],
  ['(vii) acceptEdits', T, "'--permission-mode', 'acceptEdits'", "'--permission-mode', 'bypassPermissions'"],
  ['(vii) hooks off', T, 'disableAllHooks: true', 'disableAllHooks: false'],
  ['(vii) no MCP server', T, "'--strict-mcp-config', ", ''],
  ['(vii) only the listed tools', T, "...(tools.length ? ['--allowedTools', ...tools] : [])", "'--allowedTools', 'Bash'"],
  ['records blind to the arm', T, 'const rec = { id, case: c.id,', 'const rec = { id, arm, case: c.id,'],
  ['draft: never overwrites', T, 'if (fs.existsSync(path.join(root, to))) throw', 'if (false) throw'],
  ['draft: inside the repo', T, 'if (!inRepo(root, path.join(root, to))) throw', 'if (false) throw'],
  ['draft: the front matter', T, 'for (const k of need) if (', 'for (const k of []) if ('],
  ['draft: the privacy scan', T, "if (PRIVATE.test(fs.readFileSync(from, 'utf8'))) throw", 'if (false) throw'],
  ['draft: the name', T, 'if (!/^[a-z0-9][a-z0-9-]*$/.test(String(name)))', 'if (false)'],
  ['draft: the staging folder removed', T, 'fs.rmSync(src, { recursive: true, force: true });', ''],
  ['score: grades joined per arm', T, 'r.case === c && r.arm === arm', 'r.case === c'],
  ['score: the verdict', T, 'a > b ?', 'a >= b ?'],
  ['score: too broad', T, "rows.some((r) => !r.use && !r.ua.startsWith('0/'))", 'false'],
  ['score: a run id only', T, 'if (!/^[\\w.-]+-\\d+$/.test(String(runId)))', 'if (false)'],
  ['listing text at most 400 bytes', K, 'description: Makes or tests', `description: ${'x'.repeat(80)} Makes or tests`],
  ['Claude may invoke tailor', K, 'allowed-tools:', 'disable-model-invocation: true\nallowed-tools:'],
  ['no gap, nothing made', K, 'With no gap, make nothing', 'With no gap, make a starter'],
  ['made artifacts go through draft', K, 'trial.mjs" draft <name> <skill|agent|rule>', 'trial.mjs" place <name> <skill|agent|rule>'],
  ['a test changes nothing', K, 'A test changes nothing in the artifact or the repo', 'A test may fix the artifact'],
  ['no read outside the repo', K, 'Follow **Guidelines**, at the end of this file.', 'Read `${CLAUDE_PLUGIN_ROOT}/skills/tailor/guidelines.md` first.'],
  ["the README's agent row", R, '| A task that recurs and needs its own context, tools or notes |', '| A task that recurs |'],
  ['map-review tests a draft first', V, 'invoke the `second-brain:tailor` skill', 'consider the `second-brain:tailor` skill'],
  ["2.5.1's map-review hash listed", S, ", '7ff1c09c889ebe9c']", ']'],
  ["2.5.1's README hash listed", S, ", '15a4bb133893f00e']", ']'],
];
const lines = [];
let survived = 0;
for (const [name, file, a, b] of M) {
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (!src.includes(a)) { lines.push(`MISSING  ${name}`); survived++; continue; }
  fs.writeFileSync(target, src.replace(a, b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [t], { encoding: 'utf8', timeout: 900000 });
  const killed = r.status !== 0;
  if (!killed) survived++;
  lines.push(`${killed ? 'killed  ' : 'SURVIVED'} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${M.length - survived} of ${M.length} killed`);
const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', 'mutate7.txt');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${lines.join('\n')}\n`);
console.log(lines.at(-1));
