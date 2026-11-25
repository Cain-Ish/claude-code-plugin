// 06, section 8, 8k, group B (the dream side), check 2: each mutation of a guard group B adds must fail its test. Each
// runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. A mutation is tagged with the
// systems where its killing case runs (a git.exe in the working folder, backslash paths and letter case need Windows);
// elsewhere it is listed as "not here". The unmutated copy runs first and must pass, or nothing is counted. The run
// exits non-zero when a mutation here survives or cannot be applied. Result: results/mutate8k-dream-<platform>.txt
// beside this file, unless MUT_ONLY.
//   node mutate8k-dream.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8k-dream.mjs, then dream8c.mjs, dream8d.mjs and dream8f.mjs, in place of the self-test (a
// mutation is killed at the first that fails); MUT_ONLY=<regex> runs only the mutations it matches, as a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs';
const ANY = 'any', WIN = 'win32';
const M = [
  // D-1
  ['D-1 instruction file names', D, "'steering.md', 'claude.md', 'claude.local.md', 'agents.md'", "'steering.md'", ANY],
  ['D-1 a when or review line over 200 characters', D, '(?:.{201,}$|[\\s\\S]*^- \\1:)', '(?:[\\s\\S]*^- \\1:)', ANY],
  ['D-1 one when and one review line', D, '(?:.{201,}$|[\\s\\S]*^- \\1:)', '(?:.{201,}$)', ANY],
  ['D-1 the review line too', D, '/^- (when|review):(?:', '/^- (when):(?:', ANY],
  // D-2, and the empty user
  ['D-2 sk_ and rk_ keys', D, '[sr]k[-_][a-z0-9_-]{10,}', 'sk-[a-z0-9_-]{10,}', ANY],
  ['D-2 SendGrid keys', D, 'sg\\.[a-z0-9_-]{16,}\\.[a-z0-9_-]{16,}|', '', ANY],
  ['D-2 Hugging Face keys', D, 'hf_[a-z0-9]{30,}|', '', ANY],
  ['D-2 Slack webhooks', D, '|hooks\\.slack\\.com\\/services\\/', '', ANY],
  ['D-2 credentials in a URL', D, '|:\\/\\/[^\\s/:@]*:[^\\s/@]+@', '', ANY],
  ['D-2 a URL credential with an empty user', D, ':\\/\\/[^\\s/:@]*:', ':\\/\\/[^\\s/:@]+:', ANY],
  ['D-2 bearer tokens', D, '|bearer\\s+[a-z0-9._~+/=-]{16,}', '', ANY],
  ['D-2 a quoted [private] is private', D, '|\\[private\\]/i;', '/i;', ANY],
  // D-3, as amended
  ['D-3 digests redacted', D, 'trim(dg.lines.map(redact(rootsIn())), ', 'trim(dg.lines, ', ANY],
  ['D-3 to the end of a token', D, "new RegExp(`(?:${PRIVATE.source})\\\\S*`, 'gi')", "new RegExp(PRIVATE.source, 'gi')", ANY],
  ['D-3 a key to the end of its line', D, ".replace(/begin [a-z0-9 ]*private key.*/i, '[private]')", '', ANY],
  ['D-3 the tag kept', D, "const tag = /^[A-Z]!?: /.exec(l)?.[0] ?? '';", "const tag = '';", ANY],
  ["D-3 the repo's paths made relative first", D, ".replace(roots, (m, sep) => (sep ? '' : '.'))", '', ANY],
  ['D-3 a root ends at a separator or a non-name character', D, "|(?=[\\\\s\"'\\`<>|:;,)\\\\]}]|$))`", '|)`', ANY],
  ['D-3 a JSON-escaped separator', D, 'const SEP = String.raw`(?:\\\\\\\\|\\\\|/)`;', 'const SEP = String.raw`(?:\\\\|/)`;', WIN],
  ['D-3 a root as a session spelled it', D, ', ...spellings.flatMap(([s, r]) => roots.filter((x) => `${x}${path.sep}`.startsWith(`${r}${path.sep}`)).map((x) => s + x.slice(r.length)))', '', ANY],
  ['D-3 the Git Bash spelling of the root', D, "  if (process.platform === 'win32') all.push(...all.filter((x) => /^[a-z]:[\\\\/]/i.test(x)).map((x) => `/${x[0]}${x.slice(2)}`));\n", '', WIN],
  ['D-3 letter case on Windows', D, "process.platform === 'win32' ? 'gi' : 'g'", "'g'", WIN],
  // D-4, D-5, D-6
  ['D-4 the takeover by rename', D, "  const away = `${f}.${process.pid}.${Date.now()}`;\n  try { fs.renameSync(f, away); } catch { throw new Error('another dream is running in this repo'); }\n  if (Date.now() - fs.statSync(away).mtimeMs < STALE_LOCK_MS) { try { fs.renameSync(away, f); } catch {} throw new Error('another dream is running in this repo'); }\n  fs.rmSync(away, { force: true });\n", '  fs.rmSync(f, { force: true });\n', ANY],
  ['D-5 binaries skipped', D, 'if (!body.includes(0)) parts.push', 'parts.push', ANY],
  ['D-5 each file searched apart', D, 'repoText.some((t) => foundIn(q, t))', "foundIn(q, repoText.join('\\n'))", ANY],
  ['D-6 the bounded read', D, '...(end !== Infinity && { end: end - 1 }), ', '', ANY],
  ['D-6 the call site', D, 'new Set(usage.ownSkills), c.size, (s) =>', 'new Set(usage.ownSkills), Infinity, (s) =>', ANY],
  // the straddling record
  ['a straddling record ends at the last newline', D, 'const size = lineEnd(p, from, fs.statSync(p).size);', 'const size = fs.statSync(p).size;', ANY],
  ['a straddling record read back past one window', D, 'if (nl >= 0) return at + nl + 1;', 'return nl >= 0 ? at + nl + 1 : from;', ANY],
  // finish reads map files through readMapFile
  ['finish: a topic file read through readMapFile', D, 'const now = fs.existsSync(target) ? readMap(`${MAP}/${f}`) : Buffer.alloc(0);', 'const now = (() => { try { return fs.readFileSync(target); } catch { return Buffer.alloc(0); } })();', ANY],
  ['finish: an unreadable topic file dropped', D, "if (!now) { drop('a map file that cannot be read'); continue; }", '', ANY],
  ['finish: status lines read through readMapFile', D, '.map((p) => [p, mapText(p)])', ".map((p) => [p, fs.readFileSync(path.join(root, p), 'utf8')])", ANY],
  // every git call by the resolver's full path
  ['git by full path: check-ignore', D, "spawnSync(exe('git'), ['check-ignore'", "spawnSync('git', ['check-ignore'", WIN],
  ['git by full path: ls-tree', D, "spawnSync(exe('git'), ['ls-tree'", "spawnSync('git', ['ls-tree'", WIN],
  ['git by full path: cat-file', D, "spawnSync(exe('git'), ['cat-file'", "spawnSync('git', ['cat-file'", WIN],
  // Q-11
  ['Q-11 no .git said plainly', D, "} else if (!fs.existsSync(path.join(root, '.git'))) {", '} else if (false) {', ANY],
  // 8c's mutation (4), whose anchor group B's status-line read moved; dream8c.mjs's case (4) kills it
  ['8c (4) a status line only in a topic file', D, 'mapFiles(root).filter((p) => topic(path.basename(p))).map(', 'mapFiles(root).map(', ANY],
  // the review's findings (Gemini, 8k): a path out of the root, a sibling ending in ~, < before a path, a key header with digits
  ['review: .. after the root stays absolute', D, '(${SEP}(?!\\\\.\\\\.(?:[\\\\\\\\/]|$))|', '(${SEP}|', ANY],
  ['review: a root ends only before a path-ending character', D, "|(?=[\\\\s\"'\\`<>|:;,)\\\\]}]|$))`", "|(?![\\\\w.-]))`", ANY],
  ['review: < before a home path', D, ";,<>*_~|]|\\/\\/)\\/(?:users", ";,>*_~|]|\\/\\/)\\/(?:users", ANY],
  ['review: a key header with digits', D, 'begin [a-z0-9 ]*private key.*/i', 'begin [a-z ]*private key.*/i', ANY],
];
const here = (os) => os === ANY || process.platform === os;
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['fix8k-dream.mjs', 'dream8c.mjs', 'dream8d.mjs', 'dream8f.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix8k-dream, dream8c, dream8d and dream8f' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
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
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8k-dream-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
