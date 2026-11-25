// 06, section 8, 8j, check 2: each mutation of a guard 8j adds must fail the dream's tests. Each runs in a copy of the
// candidate plugin under <work>/m, with the product-hash pin off. Case (8) of dream8f holds a folder open, which only
// Windows refuses to delete, so its mutation is killed on Windows and skipped elsewhere. The run exits non-zero when a
// mutation survives or cannot be applied. Result: results/mutate8j-<platform>.txt beside this file, unless MUT_ONLY.
//   node mutate8j.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/dream8d.mjs, dream8f.mjs and dream8c.mjs alone (a mutation is killed at the first that fails);
// MUT_ONLY=<regex> runs only the mutations it matches, as a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs';
const M = [
  // 1, X-2: a path a tool call names is placed by strings, through the sessions' recorded spellings
  ['(X-2) a named path placed by strings only', D, "const realDir = (a) => { for (const [s, r] of spellings) { const q = path.relative(s, a); if (!q.startsWith('..') && !path.isAbsolute(q)) return path.join(r, q); } return a; };",
    "const realDir = (a) => { let q = path.dirname(a); while (!fs.existsSync(q) && path.dirname(q) !== q) q = path.dirname(q); try { return path.join(real(q), path.relative(q, a)); } catch { return a; } };"],
  ['(X-2) a session spelled through a link', D, '        if (a !== b) { spellings.push([a, b]); spellings.sort((x, y) => y[0].length - x[0].length); }\n', ''],
  ['(X-2) the longest spelling first', D, ' spellings.sort((x, y) => y[0].length - x[0].length);', ''],
  ['(X-2) the spellings cut back to where they part', D, 'while (path.basename(a) && path.basename(a) === path.basename(b))', 'while (false)'],
  // 2, K-1: prepare clears with clearRun and stops; clearRun never follows a link
  ['(K-1) prepare clears the run folder with clearRun', D, '    if (!clearRun(run)) throw new Error(STUCK);\n', '    fs.rmSync(run, { recursive: true, force: true });\n'],
  ['(K-1) a linked run folder is not followed', D, 'if (!lstat(run)?.isSymbolicLink()) for (const e', 'for (const e'],
  // 3, X-4: the powers, and the live tools
  ['(X-4) an agent that may set a power refused', D, "    if (powers(fm)) { drop('agent that may set permissionMode, hooks or mcpServers'); continue; }\n", ''],
  ['(X-4) a change that may set a power refused', D, "    if (powers(fm)) { drop('change that may set permissionMode, hooks or mcpServers'); continue; }\n", ''],
  ['(X-4) permissionMode is a power', D, "const POWERS = ['permissionMode', 'hooks', 'mcpServers'];", "const POWERS = ['hooks', 'mcpServers'];"],
  ['(X-4) hooks is a power', D, "const POWERS = ['permissionMode', 'hooks', 'mcpServers'];", "const POWERS = ['permissionMode', 'mcpServers'];"],
  ['(X-4) mcpServers is a power', D, "const POWERS = ['permissionMode', 'hooks', 'mcpServers'];", "const POWERS = ['permissionMode', 'hooks'];"],
  ['(X-4) a change keeps the live tools', D, "    if (['allowed-tools', 'tools', 'disallowedTools'].some((k) => entry(fm, k) !== entry(liveFm, k))) { drop('change to allowed-tools or tools'); continue; }\n", ''],
  ['(X-4) allowed-tools compared', D, "if (['allowed-tools', 'tools', 'disallowedTools'].some(", "if (['tools', 'disallowedTools'].some("],
  ['(X-4) tools compared', D, "if (['allowed-tools', 'tools', 'disallowedTools'].some(", "if (['allowed-tools', 'disallowedTools'].some("],
  ['(X-4) a key that is not plain counts as a power', D, " || !(fm?.[1] ?? '').split('\\n').every((l) => /^([ \\t#-]|$)|^[\\w-]+[ \\t]*:/.test(l));", ';'],
  ['(X-4) the lines that continue a key counted', D, '(on = /^([ \\t#-]|$)/.test(l) ? on :', '(on = false ? on :'],
  ['(X-4) a comment inside a list continues it', D, '(on = /^([ \\t#-]|$)/.test(l) ? on :', '(on = /^([ \\t-]|$)/.test(l) ? on :'],
  // 4, K-4: a YAML block list
  ['(K-4) a block list read', D, "\n  ?? new RegExp(`^${k}:[ \\\\t]*((?:\\\\n[ \\\\t]*-[ \\\\t]+\\\\S.*)+)`, 'm').exec(fm?.[1] ?? '')?.[1].split(/\\n[ \\t]*-[ \\t]+/).slice(1).join(', ')", ''],
  // 5, P-2: git-ignored files left out of the touched files
  ['(P-2) ignored files left out', D, 'm.touched.filter((f) => kept.has(f))', 'm.touched'],
  ['(P-2) the rest checked again after git stops', D, 'rest = x.status > 1 ? rest.slice(k / 4 + 1) : [];', 'rest = [];'],
  ['(P-2) the path git stops at left out', D, 'rest.slice(k / 4 + 1)', '(kept.add(rest[k / 4]), rest.slice(k / 4 + 1))'],
  ['(P-2) a "!" pattern keeps its file', D, " || f[k + 2].startsWith('!')", ''],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['dream8d.mjs', 'dream8f.mjs', 'dream8c.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, copy ${path.basename(plugin)}, ${fast ? 'test/dream8d.mjs, dream8f.mjs and dream8c.mjs alone' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
let bad = 0, ran = 0;
for (const [name, file, a, b] of M) {
  if (only && !only.test(name)) continue;
  // dream8f's case (8) holds a folder open, which only Windows refuses to delete
  if (/^\(K-1\) prepare/.test(name) && process.platform !== 'win32') { lines.push(`skipped   ${name} (Windows only)`); console.log(lines.at(-1)); continue; }
  ran++;
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (src.split(a).length !== 2) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, () => b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const killed = tests.some((f) => spawnSync('node', [path.join(dir, 'plugin', 'test', f)], { encoding: 'utf8', timeout: 1_200_000 }).status !== 0);
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8j-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
