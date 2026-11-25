// 06, section 8, 8k, group A (the hook side), check 2: each mutation of a guard group A adds must fail its test. Each
// runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. A mutation is tagged with the
// systems where its killing case runs (FIFOs, devices and file links need POSIX here); elsewhere it is listed as
// "not here". The unmutated copy runs first and must pass, or nothing is counted. The run exits non-zero when a
// mutation here survives or cannot be applied. Result: results/mutate8k-hook-<platform>.txt beside this file.
//   node mutate8k-hook.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8k-hook.mjs alone in place of the self-test (until 8k's groups B and C land, the self-test
// fails by design on its bare-name case); MUT_ONLY=<regex> runs only the mutations it matches, as a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const M_ = 'scripts/map.mjs', H = 'scripts/hook.mjs', S = 'scripts/status.mjs', J = 'hooks/hooks.json';
const ANY = 'any', POSIX = 'posix';
const M = [
  ['H1 "names" not narrower than the filter', H, ".toLowerCase().replace(/\\\\\\r?\\n/g, '').replace(/[\"'`\\\\]/g, '').includes(MAP)", '.includes(MAP)', ANY],
  ['H1 letter case', H, '.toLowerCase().replace(', '.replace(', ANY],
  ['H1 a backslash-newline', H, ".replace(/\\\\\\r?\\n/g, '')", '', ANY],
  ['H1 quotes and backslashes', H, ".replace(/[\"'`\\\\]/g, '')", '', ANY],
  ['H3 a link out of the repo', M_, 'if (e.isSymbolicLink() && !inRepo(root, path.join(root, p))) {', 'if (false) {', ANY],
  ['H3 the map folder linked out', M_, "if (d === MAP && !inRepo(root, path.join(root, MAP))) throw new Error('the map folder is a link out of the repo');", '', ANY],
  ['H4 regular files only', M_, 'return st?.isFile() && st.size <= MAP_CAP && inRepo(root, p)', 'return st && inRepo(root, p)', ANY],
  ['H4 the size cap', M_, 'st.size <= MAP_CAP && ', '', ANY],
  ['H4 inside the repo', M_, 'st.size <= MAP_CAP && inRepo(root, p)', 'st.size <= MAP_CAP', POSIX],
  ['H4 session start lists no special file', M_, 'e.isFile() || e.isSymbolicLink() ? [p] : []', '[p]', POSIX],
  ['H4 labels read through readMapFile', M_, 'try { bytes = readMapFile(root, file); }', 'try { bytes = fs.readFileSync(path.join(root, file)); }', ANY],
  ['H4 the catalog reads through readMapFile', M_, 'const b = readMapFile(root, `${MAP}/${f}`); if (!b) return f;', 'const b = fs.readFileSync(path.join(root, MAP, f));', ANY],
  ['H4 waiting reads through readMapFile', M_, 'const b = readMapFile(root, f); if (b) proposed +=', 'const b = fs.readFileSync(path.join(root, f)); if (b) proposed +=', ANY],
  ['H4 the ids read through readMapFile', M_, "const b = readMapFile(root, f); if (!b) throw new Error('unreadable'); return idsIn(decode(b));", 'return idsIn(decode(fs.readFileSync(path.join(root, f))));', ANY],
  ['H4 status reads through readMapFile', S, 'try { b = readMapFile(root, f); } catch {}', 'try { b = fs.readFileSync(path.join(root, f)); } catch {}', ANY],
  ['H4 status names a file it cannot read', S, "unread.length ? `- Cannot read ${unread.join(', ')}", "false ? `- Cannot read ${unread.join(', ')}", ANY],
  ['H5 the scan budget', M_, 'if ((work += k + 1) > SCAN_BUDGET) return null;', '', ANY],
  ['H5 the linear search', M_, 'scan(w, low) ?? run(w, wordsOf(low))', 'scan(w, low) ?? false', ANY],
  ['H6 a safe name in labels', M_, 'Labels on the entries of ${safeName(file)}', 'Labels on the entries of ${file}', ANY],
  ['H6 a safe name in the fail-closed line', H, '[project map] The labels for ${safeName(file)}', '[project map] The labels for ${file}', ANY],
  ['H7 the resolver returns the bare name', M_, '  return bins.get(name);', '  return name;', ANY],
  ['H7 relative PATH entries skipped', M_, '.filter((d) => path.isAbsolute(d))', '', ANY],
  ['H7 none found is not the bare name', M_, "?? path.resolve('/', `${name} not found on PATH`, file)", '?? name', ANY],
  ['Q-1 the fork source', J, 'startup|clear|resume|compact|fork', 'startup|clear|resume|compact', ANY],
  ['Q-3 the timeout', J, '"read"], "timeout": 10', '"read"]', ANY],
  ['Q-8 a repo whose git cannot run says so', M_, "if (fs.existsSync(path.join(root, '.git'))) notes.push(", 'if (false) notes.push(', ANY],
  ["Q-8 why: git does not trust the folder", M_, String.raw`/safe\.directory/.test(tracked.stderr ?? '')`, 'false', ANY],
  ['Q-8 nothing outside git', H, "idx === null ? '' : startText(idx).text", 'startText(idx).text', ANY],
  ['Q-9 the catalog skips an ended entry', M_, '!ended(b) && reviewOn(b) < today', 'reviewOn(b) < today', ANY],
  ['Q-9 the labels skip an ended entry', M_, 'const review = !ended(b) && reviewOn(b);', 'const review = reviewOn(b);', ANY],
  ['Q-10 a grown transcript', M_, '(!Object.hasOwn(seen, f) || grown(path.join(d, f), seen[f]))', '!Object.hasOwn(seen, f)', ANY],
  ['Q-11 status with no .git', S, "if (!fs.existsSync(path.join(root, '.git'))) return", 'if (false) return', ANY],
  ['Q-12 the root by its real path', H, 'if (!file.startsWith(`${MAP}/`)) try { file = at(fs.realpathSync.native(root)); } catch {}', '', ANY],
  ["Q-12 no call on the model's path", H, 'const at = (r) => rel(r, input.tool_input?.file_path);', "const at = (r) => { const p = String(input.tool_input?.file_path ?? ''); return rel(r, fs.existsSync(p) ? fs.realpathSync.native(p) : p); };", ANY],
  ['Q-13 the version check', H, "&& Number(process.versions.node.split('.')[0]) < 20;", '&& false;', ANY],
  ['Q-13 only session start says so', H, "if (which === 'session-start') process.stdout.write(", 'process.stdout.write(', ANY],
  ['Q-13 the input not read first', H, "const input = old || ['onboard', 'setup']", "const input = ['onboard', 'setup']", ANY],
  ['K-5 agent drafts', M_, "for (const d of ['rules', 'agents'])", "for (const d of ['rules'])", ANY],
  ["L-11 an earlier release's template", S, 'const old = FILES.filter(', 'const old = [].filter(', ANY],
  ['Audit 2 a rejected proposal', M_, String.raw`/^- status:[ \t]*\S+[ \t]+\d{4}-\d{2}-\d{2}[ \t]+by[ \t]+review:/m.test(b) ? undefined : `, '', ANY],
  ['exclusions: the lines', M_, "['--', ...excluded(ls)]", '[]', ANY],
  ['exclusions: everything under a line', M_, ", `:(exclude,glob)${l}/**`]", ']', ANY],
  ['exclusions: a leading slash', M_, String.raw`.map((l) => l.replace(/^\/+/, ''))`, '', ANY],
  ['exclusions: a CRLF line', M_, ".split(/\\r?\\n/).map((l) => l.trim())", ".split('\\n')", ANY],
  ["exclusions: the map's own folder", M_, '  try { fresh = under(root, MAP)', '  if (!skip.length) try { fresh = under(root, MAP)', ANY],
  ['exclusions: the fallback', M_, 'if (tracked.status !== 0 && skip.length && !tracked.error) {', 'if (false) {', ANY],
  ["exclusions: the person's note", M_, 'if (tracked.status === 0) notes.push(`second-brain: git rejected', 'if (false) notes.push(`second-brain: git rejected', ANY],
  ["exclusions: the note reaches session start", H, 'const idx = index(root, notes);', 'const idx = index(root);', ANY],
];
const here = (os) => os === ANY || (os === POSIX) === (process.platform !== 'win32');
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const test = fast ? 'fix8k-hook.mjs' : 'selftest.mjs';
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix8k-hook alone' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
const runIn = (dir) => spawnSync(process.execPath, [path.join(dir, 'plugin', 'test', test)], { encoding: 'utf8', timeout: 1_200_000 });
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
  console.log(`the unmutated copy fails ${test}, so no mutation is counted:\n${baseRun.stdout.split('\n').filter((l) => l.startsWith('FAIL')).join('\n')}${baseRun.stderr.slice(-600)}`);
  process.exit(2);
}
// the cases by name, from the unmutated run, so each kill names the case that made it
const cases = baseRun.stdout.split('\n').filter((l) => l.startsWith('pass  ')).map((l) => l.slice(6));
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
  const by = r.stdout.split('\n').filter((l) => l.startsWith('FAIL')).map((l) => cases.find((c) => l.slice(6).startsWith(`${c}:`)) ?? l.slice(6, 60));
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${by.length ? ` (by ${by.join('; ')})` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8k-hook-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
