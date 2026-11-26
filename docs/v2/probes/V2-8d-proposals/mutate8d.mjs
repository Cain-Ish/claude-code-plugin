// 06, section 8, 8d, check 2: each mutation of a guard 8d adds must fail the self-test (which runs test/dream8d.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. Every case runs on every
// system. The run exits non-zero when a mutation survives or cannot be applied. Result:
// results/mutate8d-<platform>.txt beside this file.
//   node mutate8d.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/dream8d.mjs alone, and MUT_ONLY=<regex> only the mutations it matches: each a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs', AN = 'agents/dream-analyzer.md', SK = 'skills/dream/SKILL.md', MR = 'templates/claude/skills/map-review/SKILL.md', SU = 'scripts/setup.mjs';
const M = [
  ['(1) agent drafts written', D, "for (const f of fs.existsSync(agentsDir) ? fs.readdirSync(agentsDir).filter((x) => /^[\\w.-]+\\.md$/.test(x)) : []) {", 'for (const f of []) {'],
  ['(1) an agent names its tools', D, " || !field(fm, 'tools')) { drop('agent without name, description or tools')", ") { drop('agent without name, description or tools')"],
  // added after the 8d review, before the freeze: each guard its review found missing or untested
  ['(1) an empty field is no value', D, "(`^${k}:[ \\\\t]*(\\\\S.*)$`", "(`^${k}:\\\\s*(\\\\S.*)$`"],
  ['(1) the agent name is its file name', D, "    if (field(fm, 'name') !== f.slice(0, -3)) { drop('a name that is not its file name'); continue; }\n", ''],
  ['(1) an agent with a private name', D, "  for (const f of fs.existsSync(agentsDir) ? fs.readdirSync(agentsDir).filter((x) => /^[\\w.-]+\\.md$/.test(x)) : []) {\n    if (PRIVATE.test(f)) { drop('private data'); continue; }\n", "  for (const f of fs.existsSync(agentsDir) ? fs.readdirSync(agentsDir).filter((x) => /^[\\w.-]+\\.md$/.test(x)) : []) {\n"],
  ['(2) a change with a private name', D, "    if (PRIVATE.test(c.name)) { drop('private data'); continue; }\n", ''],
  ['(2) a change names its fields', D, "if (!field(fm, 'name') || !field(fm, 'description') || (c.kind === 'agent' && !field(fm, 'tools'))) { drop('change without", "if (!field(fm, 'name')) { drop('change without"],
  ['(2) an agent change names its tools', D, " || (c.kind === 'agent' && !field(fm, 'tools'))) { drop('change without", ") { drop('change without"],
  ['(2) the change name is its file name', D, "    if (field(fm, 'name') !== c.name) { drop('a name that is not its file name'); continue; }\n", ''],
  ['(2) not a file setup makes', D, "    if (MADE.has(path.relative(root, c.live).split(path.sep).join('/'))) { drop('a change to a file setup makes'); continue; }\n", ''],
  ['(2) a change from two sessions', D, "    if (cited.size < 2) { drop('change from fewer than two sessions'); continue; }\n", ''],
  ['(2) every cited session used it', D, 'if (![...cited].every((d) =>', 'if (![...cited].some((d) =>'],
  ['(2) an agent change named by its file', D, "kind: 'agent', name: f.slice(0, -3)", "kind: 'agent', name: f"],
  ['(2) the live flag kept', D, '[...(flag ? [flag] : []), ', '['],
  ["(3) only the session's own calls", D, 'if (!r.isSidechain && /^(Read|Edit|Write|MultiEdit|NotebookEdit)$/', 'if (/^(Read|Edit|Write|MultiEdit|NotebookEdit)$/'],
  ['(3) each worktree its own root', D, 'const roots = [...new Set([path.resolve(root), ...rootsReal])]', 'const roots = [...new Set([path.resolve(root)])]'],
  ['(3) the longest root first', D, '.sort((a, b) => b.length - a.length);\n    const inRoot', ';\n    const inRoot'],
  ['(3) a relative path from the session folder', D, 'path.resolve(cwd ?? root, p)', 'path.resolve(root, p)'],
  // 8g: a session's folder spelled through a link is matched by its real path
  ['(3) a folder matched by its real path', D, 'const a = realDir(path.resolve(cwd ?? root, p));', 'const a = path.resolve(cwd ?? root, p);'],
  ['(3) an inline list split outside braces', D, ".match(/(?:\"[^\"]*\"|'[^']*'|\\{[^}]*\\}|[^,])+/g) ?? []", ".split(',')"],
  ['(3) the YAML list form', D, ": paths[1].split('\\n').map((l) => l.replace(/^[ \\t]*-[ \\t]+/, ''))", ': []'],
  ['(3) a linked or impossible folder', D, 'lstat(path.join(root, fixed(g)))?.isDirectory()', 'fs.statSync(path.join(root, fixed(g)), { throwIfNoEntry: false })?.isDirectory()'],
  ['(3) a backslash glob', D, "g.includes('\\\\') || ", ''],
  ['(3) a folder inside the repo', D, ' && inRepo(root, path.join(root, fixed(g)))', ''],
  ["(4) the analyzer's artifact-correction", AN, "  - artifact-correction: the user corrects what one of the repo's own skills or agents did; the T line before the\n    correction names it.\n", ''],
  ['(5) the template says promotion replaces', MR, 'which replaces the file a change draft sits beside', 'beside a file'],
  ['(1) an agent with private data', D, "    if (PRIVATE.test(t)) { drop('agent with private data'); continue; }\n", ''],
  ['(1) an agent from two sessions', D, "    if (evidence(t, digests).size < 2) { drop('agent from fewer than two sessions'); continue; }\n", ''],
  ['(1) an agent the repo holds', D, "    if (fs.existsSync(live)) { drop('an agent the repo holds'); continue; }\n", ''],
  ['(1) an agent draft already waiting', D, "    if (fs.existsSync(`${live}.draft`)) { drop('a draft already waits'); continue; }\n", ''],
  ['(1) an agent through a link', D, "    if (!inside(root, `${live}.draft`)) { drop('a link on its path'); continue; }\n", ''],
  ['(2) a change its sessions used', D, "    if (![...cited].every((d) => usedIn[d]?.has(`${c.kind}\\0${c.name}`))) { drop('change whose sessions did not use it'); continue; }\n", ''],
  ['(2) the uses from the data folder', D, 'const usedIn = Object.fromEntries(job.manifest.filter((m) => m.digest).map((m) => [m.digest, new Set((m.uses ?? []).map((u) => `${u.kind}\\0${u.name}`))]));', "const usedIn = Object.fromEntries(Object.entries(JSON.parse(fs.readFileSync(path.join(run, 'usage.json'), 'utf8')).digests).map(([d, v]) => [d, new Set(v.uses.map((u) => `${u.kind}\\0${u.name}`))]));"],
  ['(2) a change with private data', D, "    if (PRIVATE.test(t)) { drop('change with private data'); continue; }\n", ''],
  ['(2) a change for a file the repo holds', D, "    if (!fs.existsSync(c.live)) { drop('change for a file the repo lacks'); continue; }\n", ''],
  ['(2) a change draft already waiting', D, "    if (fs.existsSync(`${c.live}.draft`)) { drop('a draft already waits'); continue; }\n", ''],
  ['(2) a change through a link', D, "    if (!inside(root, `${c.live}.draft`)) { drop('a link on its path'); continue; }\n", ''],
  ['(2) a change keeps the invocation flag', D, "    if (c.kind === 'skill') {\n      const flag", "    if (false) {\n      const flag"],
  ['(3) touched files kept', D, "if (!r.isSidechain && /^(Read|Edit|Write|MultiEdit|NotebookEdit)$/.test(x.name) && typeof fp === 'string') touched.add(fp);", ''],
  ['(3) only files in the repo', D, '[...dg.touched].map((p) => inRoot(p, dg.cwd)).filter(Boolean)', '[...dg.touched].filter(Boolean)'],
  ['(3) packages per digest', D, 'packages: [...new Set(files.map(packageOf).filter(Boolean))].sort()', 'packages: []'],
  ['(3) the report by package', D, "[...byPkg.keys()].some((k) => k !== '(no package)') ? `Files these sessions touched", "false ? `Files these sessions touched"],
  ['(3) a rule naming a folder the repo lacks', D, "{ drop('rule paths naming a folder the repo lacks'); continue; }", '{}'],
  ['(4) the analyzer\'s agent-task', AN, '  - agent-task: a task a person hands over, or does by hand, which one agent could hold.\n', ''],
  // 8l: '(4) the analyzer gets usage.json' went with P-3 (06, 8l): the main session keeps usage.json
  ['(4) the skill stages change drafts', SK, '`change/skills/<name>/SKILL.md` or `change/agents/<name>.md`', '`changes/<name>`'],
  ['(5) the template lists agent drafts', MR, ' and\n   `.claude/agents/*.md.draft`', ''],
  ['(5) the template shows a change as a diff', MR, '(`git diff --no-index <file> <file>.draft`)', ''],
  ['(5) the 2.5.1 template listed for update', SU, ", '7ff1c09c889ebe9c'", ''],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'dream8d alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
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
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'dream8d.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8d-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
