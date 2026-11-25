// 06, section 8, 8c, check 2: each mutation of a guard 8c adds must fail the self-test (which runs test/dream8c.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. The run exits non-zero
// when a mutation survives or cannot be applied. Result: results/mutate8c-<platform>.txt beside this file.
//   node mutate8c.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/dream8c.mjs alone in place of the self-test, and MUT_ONLY=<regex> only the mutations it matches:
// each a dry run, never a result.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs', AN = 'agents/dream-analyzer.md';
const S = 'skills/dream/SKILL.md';
const M = [
  ['(1) the name first', D, "${k ? ` ${one(k, 80)}` : ''}", ''],
  ['(1) R! for a failure', D, "`R${x.is_error ? '!' : ''}: ", '`R: '],
  ['(1) an older Skill call names its skill as command', D, "(x.input?.skill ?? x.input?.command)", 'x.input?.skill'],
  ['(1) Agent\'s older name, Task', D, '/^(Agent|Task)$/.test(x?.name)', "x?.name === 'Agent'"],
  ['(1) the analyzer names R!', AN, ", and **R!:** a tool's output marked as a failure", ''],
  ['(1) the analyzer reads steering first', AN, "When you are also given the run's `steering.md`, read it before the digest.", ''],
  // re-anchored 2026-11-25: the move of 8d to 8f into plugin/ (2e57af4f) split this line in two, so the old anchor went
  // missing unseen until the merged 8i and 8j copy's run
  ['(2) uses counted', D, 'const u = !r.isSidechain && used(x);', 'const u = false;'],
  ['(2) a sidechain call is no use', D, "const u = !r.isSidechain && used(x);", 'const u = used(x);'],
  ['(2) a typed /<name> counted', D, "    if (cmd && (skills.has(cmd) || cmd.includes(':'))) use({ kind: 'skill', name: cmd, via: 'typed' }, false);", ''],
  ['(2) a built-in command is no use', D, "    if (cmd && (skills.has(cmd) || cmd.includes(':')))", '    if (cmd)'],
  ['(2) a typed use leaves the open ones open', D, "use({ kind: 'skill', name: cmd, via: 'typed' }, false);", "use({ kind: 'skill', name: cmd, via: 'typed' }, true);"],
  ['(2) a typed line after a use', D, '{ for (const u of open) u.after = true; open = []; }', '{ open = []; }'],
  ['(2) a call ends the open uses', D, 'open = ends ? [e] : [...open, e];', 'open = [...open, e];'],
  ['(2) failed results by tool', D, 'fails[t] = (fails[t] ?? 0) + 1;', ''],
  ['(2) a sidechain failure is not the session\'s', D, "if (r.type === 'user' && !r.isSidechain && Array.isArray(r.message?.content)) for (const x of r.message.content) if (x?.type === 'tool_result' && x.is_error)", "if (r.type === 'user' && Array.isArray(r.message?.content)) for (const x of r.message.content) if (x?.type === 'tool_result' && x.is_error)"],
  ['(2) use counted before the nothing-typed skip', D, '      // 8c (D35): use is counted for every session of this repo the dream reads,', "      if (!dg.lines.some((l) => /^(U|Q): /.test(l))) { manifest.push({ f: c.f, end: c.size, skipped: 'nothing typed' }); continue; }\n      // 8c (D35): use is counted for every session of this repo the dream reads,"],
  ['(2) subagent runs read', D, "files = fs.readdirSync(d).filter((f) => f.endsWith('.meta.json')).sort();", 'files = [];'],
  ['(2) a run counts by its Agent call', D, "(typeof m.toolUseId === 'string' && calls.has(m.toolUseId))", "typeof m.toolUseId === 'string'"],
  ['(2) a run counts through the run that started it', D, ' || counted.has(m.parentAgentId))', ')'],
  ['(2) "unknown" with no agentType', D, "const type = typeof m.agentType === 'string' && m.agentType ? m.agentType : 'unknown';", 'const type = m.agentType;'],
  ['(2) failures inside a subagent run', D, "failed += r.message.content.filter((x) => x?.type === 'tool_result' && x.is_error).length;", 'failed += 0;'],
  ['(2) counters with no prototype', D, 'const bag = () => Object.create(null);', 'const bag = () => ({});'],
  ['(3) the "used" line', D, "    if (e) return `${kind === 'skill' ? 'Skill' : 'Agent'} ${safe(name)}: used", "    if (e) return '' && `${kind === 'skill' ? 'Skill' : 'Agent'} ${safe(name)}: used"],
  ['(3) "no use" needs 10 sessions', D, 'return n >= 10 ?', 'return n >= 9 ?'],
  ['(3) the repo\'s own skills listed', D, "usage.ownSkills = own('skills',", "usage.ownSkills = [] || own('skills',"],
  ['(3) the repo\'s own agents listed', D, "usage.ownAgents = own('agents',", "usage.ownAgents = [] || own('agents',"],
  ['(3) names made safe', D, "const safe = (s) => String(s).replace(/[\\x00-\\x1f\\x7f]/g, '?').slice(0, 80);", 'const safe = (s) => String(s);'],
  ['(4) steering from HEAD', D, "if (steer.status === 0) fs.writeFileSync(path.join(run, 'steering.md'), steer.stdout);", "try { fs.writeFileSync(path.join(run, 'steering.md'), fs.readFileSync(path.join(root, MAP, 'steering.md'), 'utf8')); } catch {}"],
  ['(4) the steering line in the report', D, "steer.status === 0 ? `Steering: ", "true ? `Steering: "],
  ['(4) topic refuses steering.md', D, "'readme.md', 'dreams.md', 'steering.md'", "'readme.md', 'dreams.md'"],
  ['(4) a status line only in a topic file', D, '.filter((p) => topic(path.basename(p))).map((p) => [p, mapText(p)])', '.map((p) => [p, mapText(p)])'],
  ['(4) the skill skips steering.md in its map read', S, ", except `steering.md`: the analyzers\n   had its committed text, and its working copy may hold edits no one reviewed.", '.'],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'dream8c alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
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
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'dream8c.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8c-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
