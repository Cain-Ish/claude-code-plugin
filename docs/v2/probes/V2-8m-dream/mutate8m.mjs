// 06, section 8, 8m (the dream's older gaps): each mutation of a guard 8m adds must fail its test (R<n>: a guard added
// for claim n of the outside review of 8m). Each runs in a copy
// of the candidate plugin under <work>/m, with the product-hash pin off. A mutation is tagged with the systems where its
// killing case runs; elsewhere it is listed as "not here". The unmutated copy runs first and must pass, or nothing is
// counted. The run exits non-zero when a mutation here survives or cannot be applied. Result:
// results/mutate8m-<platform>.txt beside this file, unless MUT_ONLY.
//   node mutate8m.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8m-dream.mjs in place of the self-test; MUT_ONLY=<regex> runs only the mutations it matches,
// as a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const D = 'scripts/dream.mjs';
const ANY = 'any';
const M = [
  // 1. Q-6
  ['1 Q-6 the typed command starts a dream', D, "if (cmd === 'second-brain:dream' || calls.some(", 'if (calls.some(', ANY],
  ['1 Q-6 a Skill call starts a dream', D, "calls.some((x) => used(x)?.name === 'second-brain:dream') || ", '', ANY],
  ["1 Q-6 the dream's own turns are not read", D, '    if (inDream) {', '    if (false) {', ANY],
  ["1 Q-6 the end's result resumes the read", D, "content.some((x) => x?.type === 'tool_result' && x.tool_use_id === endId) :", 'false :', ANY],
  ["R10 Q-6 a read begun at prepare's output starts inside the dream", D, ' || /^Dream prepared: /m.test(meta))', ')', ANY],
  ['R6 Q-6 an end with no start is read, not a start', D, ' || /^Dream prepared: /m.test(meta))', String.raw` || /^Dream prepared: /m.test(meta) || calls.some((x) => /dream\.mjs["']?\s+(finish|abort)/.test(x.input?.command ?? '')))`, ANY],
  ["R7 Q-6 prepare's refusal ends the dream", D, ': /^The dream stopped: /m.test(meta)) inDream = false;', ': false) inDream = false;', ANY],
  ['R8 Q-6 a finish after cd or from a folder with a space', D, String.raw`/\bnode\b.*dream\.mjs["']?\s+(finish|abort)\b/`, String.raw`/^\s*node\s+["']?[^"'\s]*dream\.mjs["']?\s+(finish|abort)\b/`, ANY],
  ['R9 Q-6 a sdk-cli prompt starts the dream', D, String.raw`(\[sdk-cli[^\]]*\] )?`, '', ANY],
  ['1 Q-6 a dream session is not skipped whole', D, '      // 8c (D35): use is counted for every session of this repo the dream reads',
    "      if (dg.lines.length >= 0) { manifest.push({ f: c.f, end: Number.MAX_SAFE_INTEGER, skipped: 'the dream itself' }); continue; }\n      // 8c (D35): use is counted for every session of this repo the dream reads", ANY],
  // 2. Q-7
  ['2 Q-7 a prompt with an image keeps its text', D, "c.every((x) => x?.type === 'text' || x?.type === 'image')", "c.every((x) => x?.type === 'text')", ANY],
  ["2 Q-7 only Claude Code's wrappers are dropped", D, '!WRAPPER.test(t.trimStart())', "!t.trimStart().startsWith('<')", ANY],
  // 3. Q-14
  ['3 Q-14 a home path names a folder below the user', D, String.raw`|home\/[\w.+$-]+(?:\/|(?=["'` + '`' + String.raw`\\\r\n]|$))|`, '|home|', ANY],
  ['3 Q-14 no system folder', D, '(?:root|var|tmp|mnt|private|volumes)', '(?:root|var|tmp|etc|opt|srv|mnt|private|volumes)', ANY],
  ['3 Q-14 a retina file name is no address', D, String.raw`@(?!\d+x\.(?:png|jpe?g|gif|webp|svg|avif)\b)`, '@', ANY],
  ['3 Q-14 a git remote is no address', D, String.raw`|:[\w~.-]*\/)`, ')', ANY],
  ['R1 Q-14 a bare /Users/<name>', D, String.raw`users\/[\w.+$-]|`, String.raw`users\/[\w.+$-]+\/|`, ANY],
  ['R1 Q-14 a bare /home/<name> where a path or the text ends', D, String.raw`home\/[\w.+$-]+(?:\/|(?=["'` + '`' + String.raw`\\\r\n]|$))`, String.raw`home\/[\w.+$-]+\/`, ANY],
  ['R1 Q-14 a user name with + or $', D, String.raw`home\/[\w.+$-]+(?:`, String.raw`home\/[\w.-]+(?:`, ANY],
  ['R2 Q-14 an address on a digit domain', D, String.raw`@(?!\d+x\.(?:png|jpe?g|gif|webp|svg|avif)\b)`, String.raw`@(?!\d+x\.)`, ANY],
  ['R2 Q-14 an address before a password', D, String.raw`|:[\w~.-]*\/)`, String.raw`|:[\w~])`, ANY],
  ['R2 Q-14 a dotted git host', D, String.raw`(?![\w-]|\.[\w-]|:`, String.raw`(?![\w-]|:`, ANY],
  ['R3 Q-14 a Git Bash file URL', D, String.raw`|\/\/)\/(?:cygdrive`, String.raw`)\/(?:cygdrive`, ANY],
  // 4. Q-15
  ['4 Q-15 the note is written', D, "if (s) fs.appendFileSync(path.join(dir, 'undone.txt')", "if (false) fs.appendFileSync(path.join(dir, 'undone.txt')", ANY],
  ['4 Q-15 finish tells', D, 'tell(dir, strays.length ? ', '(strays.length ? ', ANY],
  ['4 Q-15 abort tells', D, 'tell(dir, what && ', '(what && ', ANY],
  // 5. Q-16
  ["5 Q-16 one session's typed lines", D, 'userTexts.some((t) => foundIn(q, t))', "foundIn(q, userTexts.join('\\n'))", ANY],
  ["5 Q-16 a cut's mark is no source", D, ".map((l) => said(l).replace(CUT, '')).join(", '.map(said).join(', ANY],
  ["R4 Q-16 a cut's mark only at a line's end", D, String.raw`characters\]$/;`, String.raw`characters\]/g;`, ANY],
  ["R4 Q-16 a Q line's question cut", D, "l.slice(0, l.lastIndexOf(' = ')).replace(CUT, '')", "l.slice(0, l.lastIndexOf(' = '))", ANY],
  ["R4 Q-16 a Q line's answer cut", D, "l.slice(l.lastIndexOf(' = ') + 3).replace(CUT, '')", "l.slice(l.lastIndexOf(' = ') + 3)", ANY],
  ['R5 L-8 the sdk-cli mark is no source', D, 'l.startsWith(SDK, 3) ? l.slice(3 + SDK.length) : l.slice(3)', 'l.slice(3)', ANY],
  ['5 Q-16 a U line records its cut', D, '${whole(t, 4000)}', '${one(t, 4000)}', ANY],
  ['5 Q-16 a Q line records its cut', D, '${whole(q, 300)} = ${whole(v, 300)}', '${one(q, 300)} = ${one(v, 300)}', ANY],
  // 6. J-1, J-2, J-4
  ['6 J-1 a skill draft with allowed-tools', D, "if (powers(fm) || entry(fm, 'allowed-tools'))", 'if (powers(fm))', ANY],
  ['6 J-1 a skill draft with hooks', D, "if (powers(fm) || entry(fm, 'allowed-tools'))", "if (entry(fm, 'allowed-tools'))", ANY],
  ['6 J-2 a removed disallowedTools', D, "['allowed-tools', 'tools', 'disallowedTools']", "['allowed-tools', 'tools']", ANY],
  ['6 J-4 no pathspec magic for git', D, ".filter((f) => !f.startsWith(':') && ", '.filter((f) => ', ANY],
  ['6 J-4 no path past a link for git', D, ' && plain(root, path.join(root, f)) && !f.split(', ' && !f.split(', ANY],
  ['R14 J-4 no file in a submodule for git', D, " && !f.split('/').slice(0, -1).some((s, i, a) => lstat(path.join(root, ...a.slice(0, i + 1), '.git')))", '', ANY],
  ['R15 J-2 front matter after a BOM', D, String.raw`/^﻿?---\n`, String.raw`/^---\n`, ANY],
  ['R16 Audit 3 a file where a folder is due', D, ' || !st.isDirectory()) return false;', ') return false;', ANY],
  // 7. the user's word
  ['7 no disable-model-invocation added', D, "fs.writeFileSync(path.join(folder, 'SKILL.md.draft'), t, { flag: 'wx' });", "fs.writeFileSync(path.join(folder, 'SKILL.md.draft'), t.replace('---\\n', '---\\ndisable-model-invocation: true\\n'), { flag: 'wx' });", ANY],
  // 8. Audit 1
  ["8 Audit 1 any local branch's tip", D, "...tips, '--', `${MAP}/dreams.md`)", "'HEAD', '--', `${MAP}/dreams.md`)", ANY],
  ['8 Audit 1 no branch, no git grep', D, 'const kept = tips.length > 0 && git(', 'const kept = git(', ANY],
  ['R12 Audit 1 a detached HEAD', D, ", git(at, 'rev-parse', '--verify', '-q', 'HEAD').stdout?.trim()]", ']', ANY],
  ['R12 Audit 1 HEAD only when it names a commit', D, ", git(at, 'rev-parse', '--verify', '-q', 'HEAD').stdout?.trim()]", ", 'HEAD']", ANY],
  // 9. Audit 3
  ["9 Audit 3 a skill's name is its folder's", D, "if (field(fm, 'name') !== d) {", 'if (false) {', ANY],
  ['9 Audit 3 a live skill kept', D, "if (fs.existsSync(path.join(folder, 'SKILL.md'))) { drop('a skill the repo holds'); continue; }", '', ANY],
  ['9 Audit 3 a waiting draft kept', D, "if (fs.existsSync(path.join(folder, 'SKILL.md.draft'))) { drop('a draft already waits'); continue; }", '', ANY],
  // 10. Audit 4
  ["10 Audit 4 evidence with the digest's folder", D, 'new RegExp(`^\\\\s*${REF}\\\\s*$`).exec(ref)', '/^\\s*(d\\d+\\.digest):(\\d+)\\s*$/.exec(ref)', ANY],
  // 11. Audit 8
  ['11 Audit 8 a session file read once', D, 'if (candidates.some((c) => c.f === f)) continue;', '', ANY],
  // 12. the rename
  ['12 by follows the rename', D, 'const by = renamed.get(s[3]) ?? s[3];', 'const by = s[3];', ANY],
  // 13. L-8
  ['13 L-8 sdk-cli lines marked', D, "r.entrypoint === 'sdk-cli' ?", 'false ?', ANY],
  // 14. L-9
  ['14 L-9 only the topic named', D, ' && (!named || r.file === named)', '', ANY],
  ['R13 L-9 a topic named with its path', D, String.raw`(?:[\w.-]+[\\/])*`, '', ANY],
  // 15. the cut after the paths are made relative
  ['15 tag makes paths relative before the cut', D, "${one(rel(JSON.stringify(x.input) ?? ''), 80)}", "${one(JSON.stringify(x.input) ?? '', 80)}", ANY],
  ['R11 a tool call with no input', D, "JSON.stringify(x.input) ?? ''), 80)}", 'JSON.stringify(x.input)), 80)}', ANY],
  ['15 prepare gives tag the roots', D, "c.size, (s) => s.replace((re ??= rootsIn()), (m, sep) => (sep ? '' : '.')));", 'c.size);', ANY],
];
const here = (os) => os === ANY || process.platform === os;
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['fix8m-dream.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix8m-dream' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
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
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8m-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
