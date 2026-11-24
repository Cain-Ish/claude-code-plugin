// 06, section 8, 8a, check 2: each mutation of a guard 8a adds must fail the self-test (which runs test/fix8a.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. The run exits non-zero
// when a mutation survives or cannot be applied. Result: results/mutate8.txt beside this file.
//   node mutate8.mjs <plugin folder> <work folder>
// D-4 (taking a stale lock by rename) has no mutation here: no deterministic test reproduces its race (06, 8a).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const M_ = 'scripts/map.mjs', H = 'scripts/hook.mjs', D = 'scripts/dream.mjs';
const M = [
  ['H1 a command that does not name the map', H, "if (!named && output === undefined) process.exit(0);", ''],
  ['H1 only the entries the output shows', H, 'labelled(f, output, !named)', 'labelled(f, output, false)'],
  ['H1 "names" not narrower than the filter', H, ".toLowerCase().replace(/[\"'`\\\\]/g, '').includes(MAP)", '.includes(MAP)'],
  ['H1 its own header', M_, "shownOnly ? ' this output shows' : ' not yet committed, and on those this output shows'", "' not yet committed, and on those this output shows'"],
  ['H3 a link out of the repo', M_, "if (e.isSymbolicLink() && !inRepo(root, path.join(root, p))) {", 'if (false) {'],
  ['H4 regular files only', M_, 'return st?.isFile() && st.size <= MAP_CAP && inRepo(root, p)', 'return st && inRepo(root, p)'],
  ['H4 the size cap', M_, 'st.size <= MAP_CAP && ', ''],
  ['H4 inside the repo', M_, 'st.size <= MAP_CAP && inRepo(root, p)', 'st.size <= MAP_CAP'],
  ['H4 session start lists no special file', M_, "e.isFile() || e.isSymbolicLink() ? [p] : []", '[p]'],
  ['H5 the scan budget', M_, 'if ((work += k + 1) > SCAN_BUDGET) return null;', ''],
  ['H6 a safe name in labels', M_, 'Labels on the entries of ${safeName(file)}', 'Labels on the entries of ${file}'],
  ['H6 a safe name in fail-closed lines', H, '[project map] The labels for ${safeName(file)}', '[project map] The labels for ${file}'],
  ['H7 no git.exe from the repo', M_, "process.env.NoDefaultCurrentDirectoryInExePath = '1';", ''],
  ['D-1 instruction file names', D, "'readme.md', 'dreams.md', 'claude.md', 'claude.local.md', 'agents.md'", "'readme.md', 'dreams.md'"],
  ['D-1 the when line cap', D, "if (/^- when:.{201,}$/m.test(b)) { drop('a when line over 200 characters'); continue; }", ''],
  ['D-2 sk_ and rk_ keys', D, '[sr]k[-_][a-z0-9_-]{10,}', 'sk-[a-z0-9_-]{10,}'],
  ['D-2 SendGrid keys', D, 'sg\\.[a-z0-9_-]{16,}\\.[a-z0-9_-]{16,}|', ''],
  ['D-2 Hugging Face keys', D, 'hf_[a-z0-9]{30,}', 'hf_[a-z0-9]{300,}'],
  ['D-2 Slack webhooks', D, '|hooks\\.slack\\.com\\/services\\/', ''],
  ['D-2 bearer tokens', D, '|bearer\\s+[a-z0-9._~+/=-]{16,}', ''],
  ['D-3 digests redacted', D, "dg.lines.map((l) => l.replace(PRIVATE_ALL, '[private]'))", 'dg.lines'],
  ['D-5 binaries skipped', D, 'if (!body.includes(0)) parts.push', 'parts.push'],
  ['D-6 the bounded read', D, '...(end !== Infinity && { end: Math.max(start, end) - 1 })', ''],
];
const lines = [];
let bad = 0;
for (const [name, file, a, b] of M) {
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (!src.includes(a)) { lines.push(`MISSING  ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [t], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed  ' : 'SURVIVED'} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${M.length - bad} of ${M.length} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', 'mutate8.txt');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${lines.join('\n')}\n`);
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
