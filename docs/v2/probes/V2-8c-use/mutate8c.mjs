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
const M = [
  ['(1) the name first', D, "${k ? ` ${one(k, 80)}` : ''}", '', ],
  ['(1) R! for a failure', D, "`R${x.is_error ? '!' : ''}: ", '`R: '],
  ['(1) the analyzer names R!', AN, ", and **R!:** a tool's output marked as a failure", ''],
  ['(2) uses counted', D, "const u = !r.isSidechain && used(x); if (u) use({ ...u, via: 'call' });", 'const u = false;'],
  ['(2) a typed /<name> counted', D, "else if (cmd) use({ kind: 'skill', name: cmd, via: 'typed' });", ''],
  ['(2) a typed line after a use', D, '{ for (const u of open) u.after = true; open = []; }', '{ open = []; }'],
  ['(2) a new use closes the open ones', D, 'const use = (u) => { open = [{ ...u, after: false }]; uses.push(open[0]); };', 'const use = (u) => { open.push({ ...u, after: false }); uses.push(open.at(-1)); };'],
  ['(2) failed results by tool', D, 'fails[t] = (fails[t] ?? 0) + 1;', ''],
  ['(2) subagent runs read', D, "files = fs.readdirSync(d).filter((f) => f.endsWith('.meta.json'));", 'files = [];'],
  ['(2) "unknown" with no agentType', D, "if (typeof m.agentType === 'string' && m.agentType) type = m.agentType;", 'type = m.agentType;'],
  ['(2) failures inside a subagent run', D, "failed += r.message.content.filter((x) => x?.type === 'tool_result' && x.is_error).length;", 'failed += 0;'],
  ['(2) the watermark skips counted runs', D, '    if (seen.has(p)) continue;\n', ''],
  ['(2) the watermark written at finish', D, 'sub.seen = [...new Set([...(sub.seen ?? []), ...sub.pending])]', 'sub.seen = [...(sub.seen ?? [])]'],
  ['(2) the watermark back on a discard', D, 'if (!head.includes(st.pending.line)) sub.seen = sub.seen.filter((m) => !sub.pending.includes(m));', ''],
  ['(3) the "used" line', D, "    if (e) return `${kind === 'skill' ? 'Skill' : 'Agent'} ${name}: used", "    if (e) return '' && `${kind === 'skill' ? 'Skill' : 'Agent'} ${name}: used"],
  ['(3) "no use" needs 10 sessions', D, 'return n >= 10 ?', 'return n >= 9 ?'],
  ['(3) the repo\'s own skills listed', D, "usage.ownSkills = own('skills',", "usage.ownSkills = [] || own('skills',"],
  ['(4) steering from HEAD', D, "if (steer.status === 0) fs.writeFileSync(path.join(run, 'steering.md'), steer.stdout);", "try { fs.writeFileSync(path.join(run, 'steering.md'), fs.readFileSync(path.join(root, MAP, 'steering.md'), 'utf8')); } catch {}"],
  ['(4) the steering line in the report', D, "steer.status === 0 ? `Steering: ", "false ? `Steering: "],
  ['(4) topic refuses steering.md', D, "'readme.md', 'dreams.md', 'steering.md'", "'readme.md', 'dreams.md'"],
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
