// 06, section 8, 8f, check 2: each mutation of a guard 8f adds must fail the self-test (which runs test/dream8f.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. Case (6) runs on Windows
// only (a folder that is a working folder cannot be deleted there), so its mutation is killed on Windows. The run
// exits non-zero when a mutation survives or cannot be applied. Result: results/mutate8f-<platform>.txt beside this
// file.
//   node mutate8f.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/dream8f.mjs alone, and MUT_ONLY=<regex> only the mutations it matches: each a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs', SK = 'skills/dream/SKILL.md', AN = 'agents/dream-analyzer.md';
const M = [
  // 1, the trim
  ['(1) the trim keeps A lines', D, 'const keep = lines.map((l, i) => !tool(l) || keepAt.has(i));', 'const keep = lines.map((l, i) => /^(U|Q): /.test(l) || keepAt.has(i));'],
  ['(1) 4 tool lines before', D, 'k >= 0 && n < 4; k--', 'k >= 0 && n < 2; k--'],
  ['(1) map-read lines kept', D, 'const keep = lines.map((l, i) => !tool(l) || keepAt.has(i));', 'const keep = lines.map((l, i) => !tool(l));'],
  ['(1) a run of tool lines counted', D, '    if (gap) { out.push(`…: ${gap} tool lines`); gap = 0; }', '    if (gap) { gap = 0; }'],
  ['(2) prepare writes the trimmed digest', D, "const text = `${out.join('\\n')}\\n`;", "const text = `${dg.lines.join('\\n')}\\n`;"],
  ['(2) map reads recorded', D, 'if (recReads.length) t.forEach(', 'if (false) t.forEach('],
  ["(2) a read's line in the trimmed digest", D, 'line: at.get(m.idx)', 'line: m.idx + 1'],
  // 2, read then corrected
  ['(3) only corrections count', D, '/^CANDIDATE \\| correction \\| (d\\d+\\.digest)', '/^CANDIDATE \\| \\w+ \\| (d\\d+\\.digest)'],
  ['(3) only at a U or Q line', D, "if (!c || !/^(U|Q): /.test(digests[c[1]]?.[Number(c[2]) - 1] ?? '')) continue;", 'if (!c) continue;'],
  ['(3) only after the read', D, 'if (r.line < Number(c[2])) {', 'if (true) {'],
  ['(4) no candidates file', D, "  try { cands = fs.readFileSync(path.join(run, 'candidates.txt'), 'utf8'); } catch {}", "  cands = fs.readFileSync(path.join(run, 'candidates.txt'), 'utf8');"],
  // 4, the lock and the state before the repo's run folder
  ['(6) the state and the lock before the run folder', D, "  fs.rmSync(runDir, { recursive: true, force: true });\n  fs.writeFileSync(path.join(dir, 'state.json')",
    "  fs.rmSync(run, { recursive: true, force: true });\n  fs.rmSync(runDir, { recursive: true, force: true });\n  fs.writeFileSync(path.join(dir, 'state.json')"],
  ['(6) the folder named in the report', D, '} catch { stuck = `${RUN}/ could not be removed', "} catch { stuck = ''; `${RUN}/ could not be removed"],
  // 3, the texts
  ['(5) the skill writes the candidates file', SK, '   - `.project-map/.dream-run/candidates.txt`:', '   - `candidates`:'],
  ['(5) the analyzer knows the cut lines', AN, ' A line `…: <n> tool lines` stands for tool calls left out of the digest;', ''],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'dream8f alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
let bad = 0, ran = 0;
for (const [name, file, a, b] of M) {
  if (only && !only.test(name)) continue;
  // case (6) holds a folder open, which only Windows refuses to delete
  if (name.startsWith('(6) the state') && process.platform !== 'win32') { lines.push(`skipped   ${name} (Windows only)`); console.log(lines.at(-1)); continue; }
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
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'dream8f.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8f-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
