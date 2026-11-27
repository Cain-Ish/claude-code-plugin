// 06, section 9 (2.6.1, the audit's fixes): each mutation of a guard or a pinned sentence 2.6.1 adds must fail its
// case. Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off, and runs only the
// case named with it (FIX261_ONLY), or the self-test without MUT_FAST. The unmutated copy runs first and must pass, or
// nothing is counted. Exits non-zero when a mutation survives or cannot be applied. Result: results/mutate261-
// <platform>.txt beside this file, unless MUT_ONLY.
//   node mutate261.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix261.mjs (the named case) in place of the self-test; MUT_ONLY=<regex> runs only the mutations
// it matches, as a dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const H = 'scripts/hook.mjs', D = 'scripts/dream.mjs', TR = 'scripts/trial.mjs', SU = 'scripts/setup.mjs', MA = 'scripts/map.mjs', ST = 'scripts/status.mjs';
const MR = 'templates/claude/skills/map-review/SKILL.md';
// [name, file, text, its mutation, the case that must fail]
const M = [
  ['AU-1 show names the powers', TR, "...(info.kind === 'rule' ? [] : powersIn(", "...(true ? [] : powersIn(", 'AU-1'],
  ['AU-1 memory counted', D, "  if (kind === 'agent' && userMemory(fm)) set.push('memory');\n", '', 'AU-1'],
  ['AU-1 allowed-tools counted', D, "  if (kind === 'skill' && entry(fm, 'allowed-tools')) set.push('allowed-tools');\n", '', 'AU-1'],
  ['AU-1 an odd line counted beside another power', D, "  if (odd(fm)) set.push('odd');", "  if (!set.length && odd(fm)) set.push('odd');", 'AU-1'],
  ['AU-1 a closing --- with spaces', D, ".replace(/^---[ \\t]+$/gm, '---')}\\n`);", "}\\n`);", 'AU-1'],
  ['AU-1 no line end after ---', D, "  const fm = front(`${t.replace(/\\r/g, '').replace(/^---[ \\t]+$/gm, '---')}\\n`);", "  const fm = front(t.replace(/\\r/g, '').replace(/^---[ \\t]+$/gm, '---'));", 'AU-1'],
  ['AU-2 check scripts in blobs', TR, '...Object.fromEntries(Object.keys(t.checks).map((k) => [k, at(k)])), ', '', 'AU-2'],
  ['AU-2 files beside in blobs', TR, ', ...Object.fromEntries(t.info.extras.map((e) => [e.rel, hashOf(e.rel, e.body)])) };', ' };', 'AU-2'],
  ['AU-2 map-review reads blobs', MR, 'If it has no `blobs`, or `git hash-object <file>` of a file its `blobs`\n     names no longer equals the id there, call it stale.', 'If `git hash-object <the draft>` no longer equals its\n     `artifactBlob`, call it stale.', 'AU-2'],
  ['AU-3 Next names the log', D, '`commit ${MAP}/dreams.md, whose new line the next dream waits for.`', "'commit.'", 'AU-3'],
  ['AU-3 Next names the log with proposals', D, "then commit${read.length ? ` them with ${MAP}/dreams.md, whose new line the next dream waits for` : ''}.", 'then commit.', 'AU-6'],
  ['AU-3 no dream due while the line waits', MA, '  if (logWaits(root, st)) return', '  if (false) return', 'AU-3'],
  ['AU-3 waits only until a commit', MA, "    return fs.statSync(path.join(g, 'index')).mtimeMs <= Date.parse(st.lastDream);", '    return true;', 'AU-3'],
  ['AU-3 no git call at session start', MA, '  if (logWaits(root, st)) return', '  if (lastDream(root, st)?.waits) return', 'AU-3'],
  ['AU-3 Claude told only when due', H, " && d.startsWith('second-brain: a dream is due')", '', 'AU-3'],
  ['AU-3 map-review commits the log', MR, ", and `.project-map/dreams.md` when it holds a dream's\n   log line not yet committed (the next dream waits for that commit)", '', 'AU-3'],
  ['AU-5 the lock in the shared git folder', TR, "const lockOf = (root) => path.join(gitDir(root), 'second-brain-trial.lock');", "const lockOf = (root) => path.join(root, MAP, 'trial.lock');", 'AU-5'],
  ['AU-6 a skill draft with a command line', D, "    if (commandLines(t).length) { drop('skill with a command line (!)'); continue; }\n", '', 'AU-6'],
  ['AU-6 a change to a command line', D, "    if (c.kind === 'skill' && commandLines(t).join('\\n') !== commandLines(liveText).join('\\n')) { drop('change to a command line (!)'); continue; }\n", '', 'AU-6'],
  ['AU-6 the lines as a whole, in order', D, "commandLines(t).join('\\n') !== commandLines(liveText).join('\\n')", 'commandLines(t).some((l) => !commandLines(liveText).includes(l))', 'AU-6'],
  ['AU-6 a fenced block', D, " const keep = fenced || /!`|^\\s*```!/.test(l);", " const keep = /!`/.test(l);", 'AU-6'],
  ['AU-7 every HEAD text at once', MA, "  named.forEach((f, i) => got[i]?.type === 'blob' && heads.set(f, got[i].body));\n", '', 'AU-7'],
  ['AU-8 skip, not stop', MA, '{ listed.push(d); used += d.length + 1; }', '{ listed.push(d); used += d.length + 1; } else break;', 'AU-8'],
  ['AU-9 PowerShell and * warn', TR, '/^(Bash|PowerShell)(?:\\(\\s*\\*\\s*\\))?$/', '/^(Bash)$/', 'AU-9'],
  ['AU-10 a late finish refused', D, '  if (!job?.id || id === undefined || job.id === id) return;', '  return;', 'AU-10'],
  ['AU-10 the command with no id refused', D, 'finish(root, data, id ?? null)', 'finish(root, data, id)', 'AU-10'],
  ['AU-10 the run id printed', D, '      `Run id: ${id} (finish and abort take it).`,\n', '', 'AU-10'],
  ['AU-11 the tracked name by letter case', MA, "  if (!lost.length || tree?.type !== 'tree') return heads;", '  return heads;', 'AU-11'],
  ['AU-11 one tracked name only', MA, 'return ts.length === 1 ? [[f,', 'return ts.length ? [[f,', 'AU-11'],
  ["AU-12 onboard's reason", H, "why.length ? why.join(' ')", "false ? why.join(' ')", 'AU-12'],
  ['AU-12 onboard says nothing of commits without git', H, '  const tracked = idx === null ? null : git(', '  const tracked = idx === null ? [] : git(', 'AU-12'],
  ["AU-12 status's reason", ST, '  if (probe.status !== 0) return', '  if (false) return', 'AU-12'],
  ["AU-13 prepare takes finish's test", D, "would refuse never starts\n  if (!inside(root, path.join(root, MAP, 'dreams.md'))) throw", 'would refuse never starts\n  if (false) throw', 'AU-13'],
  ['AU-14 setup decodes', SU, '  const read = (f) => { try { return decode(fs.readFileSync(path.join(root, f))); }', "  const read = (f) => { try { return fs.readFileSync(path.join(root, f), 'utf8'); }", 'AU-14'],
  ['AU-15 a copy adds with -f', TR, "[['add', '-A', '-f'],", "[['add', '-A'],", 'AU-15'],
  ['AU-16 a source over 4 MB is not read', MA, 'docs.set(at, st.size <= MAP_CAP && (real', 'docs.set(at, (real', 'AU-16'],
  ['AU-16 a source out of the repo is not read', MA, '(real === base || real.startsWith(base + path.sep)) ? decode(', 'true ? decode(', 'AU-16'],
  ["AU-17 2.6.0's map-review listed", SU, "'7e5d413c03dfa3ea', 'd2e13952443549c2']", "'7e5d413c03dfa3ea']", 'AU-17'],
  ['AU-17 no promote untested', MR, '   - A draft that is untested, stale or not judged is not offered for promotion: each is tested against a run without\n     it before anyone keeps it.', '   - A draft that is untested may be promoted.', 'AU-17'],
  ['AU-18 session ids private', D, '|(?<![a-z0-9])session_[a-z0-9]{20,}(?![a-z0-9])', '', 'AU-18'],
  ['AU-19 a staged draft is not team memory', MA, ' && !p.startsWith(`${MAP}/drafts/`));', '));', 'AU-19'],
  ['AU-20 the dream watches .claude/hooks', D, ", '.claude/output-styles', '.claude/hooks'];", ", '.claude/output-styles'];", 'AU-20'],
  ['AU-20 an older record removes no hook script', D, "(dirs ?? []).includes('.claude/hooks')", 'true', 'AU-20'],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix261 (the named case)' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
const runIn = (dir, id) => {
  const t = fast ? 'fix261.mjs' : 'selftest.mjs';
  const r = spawnSync(process.execPath, [path.join(dir, 'plugin', 'test', t)], { encoding: 'utf8', timeout: 1_200_000, env: { ...process.env, ...(fast && id ? { FIX261_ONLY: `^${id} ` } : {}) } });
  return { ...r, test: t };
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
for (const [name, file, a, b, id] of M) {
  if (only && !only.test(name)) continue;
  // its case counts git's calls through a script on PATH, which a git.exe cannot be
  if (process.platform === 'win32' && /no git call/.test(name)) { lines.push(`not here  ${name} (not on Windows)`); console.log(lines.at(-1)); continue; }
  ran++;
  copy(dir);
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (src.split(a).length !== 2) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, () => b));
  const r = runIn(dir, id);
  const killed = r.status !== 0;
  if (!killed) bad++;
  const by = (r.stdout ?? '').split('\n').filter((l) => l.startsWith('FAIL')).map((l) => l.slice(6).split(':')[0]);
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${killed ? ` (by ${r.test}${by.length ? `: ${by.join('; ')}` : `, exit ${r.status}`})` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate261-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
