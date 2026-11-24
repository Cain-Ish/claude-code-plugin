// 06, section 8, 8a, check 2: each mutation of a guard 8a adds must fail the self-test (which runs test/fix8a.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. A mutation is tagged with
// the systems where its killing case runs (FIFOs, devices, control characters in names and file links need POSIX; a
// repo's git.exe needs Windows); on other systems it is listed as "not here", and the two systems' files together
// must kill every mutation. The run exits non-zero when a mutation here survives or cannot be applied.
// Result: results/mutate8-<platform>.txt beside this file.
//   node mutate8.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8a.mjs alone in place of the self-test, and MUT_ONLY=<regex> only the mutations it matches:
// each a dry run, never a result.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const M_ = 'scripts/map.mjs', H = 'scripts/hook.mjs', D = 'scripts/dream.mjs', T = 'test/selftest.mjs';
const ANY = 'any', POSIX = 'posix', WIN = 'win32';
const M = [
  ['H1 an unnamed command whose output cannot be seen', H, '  if (!named && output === undefined) process.exit(0);\n', '', ANY],
  ['H1 only the entries the output shows', H, 'labelled(f, output, !named)', 'labelled(f, output, false)', ANY],
  ['H1 "names" not narrower than the filter', H, ".toLowerCase().replace(/\\\\\\r?\\n/g, '').replace(/[\"'`\\\\]/g, '').includes(MAP)", '.includes(MAP)', ANY],
  ['H1 a backslash-newline', H, ".replace(/\\\\\\r?\\n/g, '')", '', ANY],
  ['H1 its own header', M_, "shownOnly ? ' this output shows' : ' not yet committed, and on those this output shows'", "' not yet committed, and on those this output shows'", ANY],
  ['H1 a UTF-16 print shows all', M_, '!seen || seen[i] || (!shownOnly && !held.has(b))', '(shownOnly ? Boolean(seen?.[i]) : !seen || !held.has(b) || seen[i])', ANY],
  ['H1 a folder not listed fails closed', H, 'files === null ? [[`${MAP}/`, closed(`${MAP}/`)]] :', 'files === null ? (named ? [[`${MAP}/`, closed(`${MAP}/`)]] : []) :', ANY],
  ['H3 a link out of the repo', M_, 'if (e.isSymbolicLink() && !inRepo(root, path.join(root, p))) {', 'if (false) {', ANY],
  ['H3 the map folder linked out', M_, "if (d === MAP && !inRepo(root, path.join(root, MAP))) throw new Error('the map folder is a link out of the repo');", '', ANY],
  ['H4 regular files only', M_, 'return st?.isFile() && st.size <= MAP_CAP && inRepo(root, p)', 'return st && inRepo(root, p)', ANY],
  ['H4 the size cap', M_, 'st.size <= MAP_CAP && ', '', ANY],
  ['H4 inside the repo', M_, 'st.size <= MAP_CAP && inRepo(root, p)', 'st.size <= MAP_CAP', POSIX],
  ['H4 session start lists no special file', M_, 'e.isFile() || e.isSymbolicLink() ? [p] : []', '[p]', POSIX],
  ['H5 the scan budget', M_, 'if ((work += k + 1) > SCAN_BUDGET) return null;', '', ANY],
  ['H5 the linear search', M_, 'scan(w, low) ?? run(w, wordsOf(low))', 'scan(w, low) ?? false', ANY],
  ['H6 a safe name in labels', M_, 'Labels on the entries of ${safeName(file)}', 'Labels on the entries of ${file}', POSIX],
  ['H6 a safe name in fail-closed lines', H, '[project map] The labels for ${safeName(file)}', '[project map] The labels for ${file}', POSIX],
  ['H7 no git.exe from the repo', M_, "process.env.NoDefaultCurrentDirectoryInExePath = '1';", '', WIN],
  ['D-1 instruction file names', D, "'readme.md', 'dreams.md', 'claude.md', 'claude.local.md', 'agents.md'", "'readme.md', 'dreams.md'", ANY],
  ['D-1 the when line cap', D, "if (/^- when:.{201,}$/m.test(b)) { drop('a when line over 200 characters'); continue; }", '', ANY],
  ['D-2 sk_ and rk_ keys', D, '[sr]k[-_][a-z0-9_-]{10,}', 'sk-[a-z0-9_-]{10,}', ANY],
  ['D-2 SendGrid keys', D, 'sg\\.[a-z0-9_-]{16,}\\.[a-z0-9_-]{16,}|', '', ANY],
  ['D-2 Hugging Face keys', D, 'hf_[a-z0-9]{30,}', 'hf_[a-z0-9]{300,}', ANY],
  ['D-2 Slack webhooks', D, '|hooks\\.slack\\.com\\/services\\/', '', ANY],
  ['D-2 credentials in a URL', D, '|:\\/\\/[^\\s/:@]+:[^\\s/@]+@', '', ANY],
  ['D-2 bearer tokens', D, '|bearer\\s+[a-z0-9._~+/=-]{16,}', '', ANY],
  ['D-3 digests redacted', D, 'dg.lines.map(redact)', 'dg.lines', ANY],
  ['D-3 to the end of a token', D, 'new RegExp(`(?:${PRIVATE.source})\\\\S*`, \'gi\')', "new RegExp(PRIVATE.source, 'gi')", ANY],
  ['D-3 a key to the end of its line', D, "l.replace(/begin [a-z ]*private key.*/i, '[private]')", 'l', ANY],
  ['D-3 a quoted [private] is private', D, '|\\[private\\]/i;', '/i;', ANY],
  ['D-4 the takeover by rename', D, "  const away = `${f}.${process.pid}.${Date.now()}`;\n  try { fs.renameSync(f, away); } catch { throw new Error('another dream is running in this repo'); }\n  if (Date.now() - fs.statSync(away).mtimeMs < STALE_LOCK_MS) { try { fs.renameSync(away, f); } catch {} throw new Error('another dream is running in this repo'); }\n  fs.rmSync(away, { force: true });\n", '  fs.rmSync(f, { force: true });\n', ANY],
  ['D-5 binaries skipped', D, 'if (!body.includes(0)) parts.push', 'parts.push', ANY],
  ['D-6 the bounded read', D, '...(end !== Infinity && { end: end - 1 })', '', ANY],
  ['D-6 the call site', D, '      }, c.size);', '      });', ANY],
  ['F-1 the self-test removes its markers', T, 'for (const f of ours()) fs.rmSync(path.join(os.tmpdir(), f), { force: true });', '', ANY],
];
const here = (os) => os === ANY || (os === WIN ? process.platform === 'win32' : process.platform !== 'win32');
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'fix8a alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
let bad = 0, ran = 0;
for (const [name, file, a, b, os] of M) {
  if (only && !only.test(name)) continue;
  if (!here(os)) { lines.push(`not here  ${name} (${os})`); continue; }
  ran++;
  const dir = path.join(work, 'm');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (!src.includes(a)) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'fix8a.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed here (${M.length - ran} for the other system${only ? ' or left out' : ''})${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
