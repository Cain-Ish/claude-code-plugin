// 06, section 8, 8e, check 2: each mutation of a guard 8e adds must fail the self-test (which runs test/trial8e.mjs).
// Each runs in a copy of the candidate plugin under <work>/m, with the product-hash pin off. Every case runs on every
// system. The run exits non-zero when a mutation survives or cannot be applied. Result:
// results/mutate8e-<platform>.txt beside this file. The list follows 8e as amended after its reviews (06).
//   node mutate8e.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/trial8e.mjs alone, and MUT_ONLY=<regex> only the mutations it matches: each a dry run. Two are
// the self-test's own checks, which a MUT_FAST run cannot kill: the exact grant, and no code loaded at run time.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const TR = 'scripts/trial.mjs', TL = 'skills/tailor/SKILL.md', MR = 'templates/claude/skills/map-review/SKILL.md';
const M = [
  // item 1, the case file
  ['(1) fields it does not know', TR, "  if (unknown(spec, FIELDS).length) errs.push(`fields it does not know: ${unknown(spec, FIELDS).join(', ')}`);\n", ''],
  ['(1) a tool that reads as a flag', TR, " || t.trim().startsWith('-')", ''],
  ['(1) a prompt that reads as a flag', TR, " || c.prompt.trim().startsWith('-')", ''],
  ['(1) the tool its kind needs', TR, '    else if (NEEDS[kindOf(a)].length && ', '    else if (false && '],
  ['(1) a check under the checks folder', TR, '!k.startsWith(CHECKS) || ', ''],
  ['(1) a check path that climbs', TR, "k.split('/').includes('..') || ", ''],
  ['(1) three cases or more', TR, 'if (cases.length < 3)', 'if (cases.length < 2)'],
  ['(1) a case where it should not be used', TR, "  if (!cases.some((c) => c?.use === false)) errs.push('one case where it should not be used (use: false)');\n", ''],
  ['(1) runs at least 3', TR, 'n >= 3 && n <= 5', 'n >= 1 && n <= 5'],
  ['(1) runs at most 5', TR, 'n >= 3 && n <= 5', 'n >= 3 && n <= 9'],
  ['(1) the privacy scan', TR, "  if (PRIVATE.test(text)) errs.push('it holds private data: a secret, a session id, an email address or an absolute path');\n", ''],
  ["(1) the artifact's home", TR, "if (!HOMES.test(a) || a.split('/').includes('..'))", 'if (false)'],
  ['(1) an artifact path that climbs', TR, "if (!HOMES.test(a) || a.split('/').includes('..'))", 'if (!HOMES.test(a))'],
  ['(1) committed as git compares', TR, "git(root, 'diff', '--quiet', commit, '--', rel).status === 0;", 'blob(root, commit, rel).stdout.equals(fs.readFileSync(path.join(root, rel)));'],
  ['(1) unchanged since the commit', TR, " && git(root, 'diff', '--quiet', commit, '--', rel).status === 0;", ';'],
  ['(1) the case file committed', TR, '  if (!committed(root, commit, rel)) throw', '  if (false) throw'],
  ['(1) each check committed', TR, '    if (!committed(root, commit, k)) throw', '    if (false) throw'],
  ['(1) a case file through a link', TR, 'if (!plainFile(file) || !inRepo(root, file)) throw', 'if (!plainFile(file)) throw'],
  ['(1) a live artifact as committed', TR, '  if (!draft && !committed(root, commit, artifact)) throw', '  if (false) throw'],
  // item 2, show, the hash and the yes
  ['(2) the hash covers the commit', TR, '.update(`${commit}\\0`)', ''],
  ['(2) the hash covers the artifact', TR, '.update(info.text);\n  for (const e of info.extras)', ';\n  for (const e of info.extras)'],
  ['(2) the hash covers the files beside it', TR, '  for (const e of info.extras) h.update(`\\0${e.rel}\\0`).update(e.body);\n', ''],
  ['(2) run checks the hash', TR, '  if (hash !== now) throw new Error(`the hash', '  if (false) throw new Error(`the hash'],
  ['(2) show prints the front matter', TR, 'fm ? `Its front matter:', 'false ? `Its front matter:'],
  ['(2) show prints every command form', TR, '/!`|^\\s*```!/', '/^!`/'],
  ['(2) show prints the files beside it', TR, '...(info.extras.length ? [', '...(false ? ['],
  ['(2) show prints each check script', TR, '...Object.entries(checks).map(', '...[].map('],
  ['(2) the run line is typed with !', TR, '`! node "${self', '`node "${self'],
  ['(2) the skill never starts a trial', TR, "      else if (/^run\\b/.test(words)) console.log('A trial starts only", "      else if (/^run\\b/.test(words)) console.log(start(root, ...words.split(/\\s+/).slice(1)), 'A trial starts only"],
  ['(2) other words ask to make', TR, "      else console.log('Tailor: make one", "      else if (words) throw new Error('unknown');\n      else console.log('Tailor: make one"],
  // item 3, the copies and the session
  ['(3) no evals in a copy', TR, ' && !`${e.p}/`.startsWith(`${MAP}/evals/`)', ''],
  ['(3) no backslash or colon in a copy', TR, ' && !/[\\\\:]/.test(e.p)', ''],
  ['(3) no .git in a copy', TR, " || s.toLowerCase() === '.git'", ''],
  ['(3) no signing in a copy', TR, "'-c', 'commit.gpgsign=false', ", ''],
  ['(3) no hooks in a copy', TR, "'-c', 'core.hooksPath=.git/no-hooks', ", ''],
  ['(3) the same message in every arm', TR, '    else fs.rmSync(live, { force: true });\n  }\n  commit(copy);', "    else fs.rmSync(live, { force: true });\n  }\n  commit(copy);\n  git(copy, ...GIT_COPY, 'commit', '--allow-empty', '-qm', arm);"],
  ['(3) a draft never stays in a copy', TR, '  fs.rmSync(`${live}.draft`, { force: true });\n', ''],
  ['(3) "with" adds the files beside it', TR, '    for (const e of info.extras) {', '    for (const e of []) {'],
  ['(3) a new skill has no folder without it', TR, "    if (info.kind === 'skill' && info.draft) fs.rmSync(path.dirname(live), { recursive: true, force: true });\n    else ", '    '],
  ['(3) a change keeps the committed file', TR, "} else if (arm === 'without' && !info.change) {", "} else if (arm === 'without') {"],
  ['(3) the tools limited', TR, "'--tools', ...new Set(tools.map((t) => t.replace(/\\(.*$/s, '').trim())), ", ''],
  ['(3) project settings only', TR, "'--setting-sources', 'project,local', ", ''],
  ['(3) no transcript kept', TR, "'--no-session-persistence',", ''],
  ['(3) hooks off', TR, "'--settings', JSON.stringify({ disableAllHooks: true }), ", ''],
  ['(3) no MCP server', TR, "'--strict-mcp-config', ", ''],
  ['(3) acceptEdits stated', TR, "'--permission-mode', 'acceptEdits', ", ''],
  ['(3) one JSON result', TR, "'--output-format', 'json', ", ''],
  ['(3) the nested-session variables removed', TR, "for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e;", 'return e;'],
  // item 4, the verdict
  ['(4) "not judged" on a failed session', TR, 'if (failed || rows.some(', 'if (rows.some('],
  ['(4) "not judged" when the should-not case fails without', TR, " || rows.some((r) => !r.use && r.without < r.runs)) return 'not judged';", ") return 'not judged';"],
  ['(4) a should-not case that fails is "hurts"', TR, "  if (rows.some((r) => !r.use && r.with < r.runs)) return 'hurts';\n", ''],
  ['(4) "mixed" wins over the totals', TR, "  if (rows.some((r) => r.with > r.without) && rows.some((r) => r.with < r.without)) return 'mixed';\n", ''],
  // item 3 and 4, the run
  ['(5) a session counts only a result', TR, "done(!killed && code === 0 && r?.type === 'result' && r.is_error === false);", 'done(true);'],
  ['(5) the check written after the session', TR, '        if (!(await session(copy, c.prompt, c.tools ?? DEFAULT_TOOLS))) { failed++; continue; }\n        if (judged(t.checks[c.check], copy))',
    "        const pre = fs.mkdtempSync(path.join(os.tmpdir(), 'second-brain-check-')); fs.writeFileSync(path.join(pre, 'check.mjs'), t.checks[c.check]);\n        if (!(await session(copy, c.prompt, c.tools ?? DEFAULT_TOOLS))) { failed++; continue; }\n        if (spawnSync(process.execPath, [path.join(pre, 'check.mjs')], { cwd: copy, env: checkEnv() }).status === 0)"],
  ['(5) a reduced environment for the check', TR, 'env: checkEnv(), timeout: 120_000', 'env: process.env, timeout: 120_000'],
  ['(5) the copies deleted', TR, 'finally { if (copy) fs.rmSync(copy, { recursive: true, force: true }); }', 'finally { }'],
  ["(5) the check's folder deleted", TR, '  } finally { fs.rmSync(d, { recursive: true, force: true }); }', '  } finally { }'],
  ['(5) no copy inside the repo', TR, "        if (inRepo(root, copy)) throw new Error('the temporary folder lies inside the repo');\n", ''],
  ['(5) the verdict privacy-scanned', TR, "  if (PRIVATE.test(text)) throw new Error('the verdict would hold private data');\n", ''],
  ['(5) the verdict folder in the repo', TR, '  if (!inRepo(root, dir)) throw new Error(`${MAP}/.trial is a link out of the repo`);\n', ''],
  ['(5) never through a link at its path', TR, "fs.rmSync(p, { force: true }); fs.writeFileSync(p, body, { flag: 'wx' });", 'fs.writeFileSync(p, body);'],
  ['(5) the verdict git-ignored', TR, "[['.gitignore', '*\\n'], ", '['],
  ['(5) the blob ids recorded', TR, 'artifactBlob: blobId(root, t.spec.artifact), ', ''],
  ['(5) a stopped trial recorded', TR, "if (/^[\\w.-]+$/.test(String(rest[0] ?? ''))) try { record(", 'if (false) try { record('],
  // the making steps' only write
  ['(6) an agent draft names its tools', TR, "kind === 'agent' ? ['name', 'description', 'tools']", "kind === 'agent' ? ['name', 'description']"],
  ['(6) an empty field is no value', TR, "new RegExp(`^${k}:[ \\\\t]*\\\\S`, 'm')", "new RegExp(`^${k}:\\\\s*\\\\S`, 'm')"],
  ["(6) the name is the draft's own", TR, "  if (kind !== 'rule' && fm.match(", '  if (false && fm.match('],
  ['(6) a draft with private data', TR, "    if (PRIVATE.test(fs.readFileSync(from, 'utf8'))) throw new Error(`${path.basename(from)} holds private data`);\n", ''],
  ['(6) never over a draft', TR, 'if (fs.existsSync(path.join(root, to)) || ', 'if ('],
  ['(6) never over a live file', TR, " || fs.existsSync(path.join(root, to.replace(/\\.draft$/, ''))))", ')'],
  ['(6) a draft never through a link', TR, 'if (!fs.lstatSync(src, { throwIfNoEntry: false })?.isDirectory() || !inRepo(root, src))', 'if (false)'],
  // the texts, and the self-test's own checks
  ['(7) tailor only a person starts', TL, 'disable-model-invocation: true\n', ''],
  ['(7) tailor never runs a trial itself', TL, 'Never run `trial.mjs` yourself except `draft`', 'You may run trial.mjs'],
  ['(7) tailor grants cli and draft only', TL, 'trial.mjs" cli:*), Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" draft:*)', 'trial.mjs":*)'],
  ['(7) the words by a quoted heredoc', TL, "cli <<'SECOND_BRAIN_WORDS'\n$ARGUMENTS\nSECOND_BRAIN_WORDS", 'cli $ARGUMENTS'],
  ['(7) no code loaded at run time', TR, "import { PRIVATE } from './dream.mjs';", "const { PRIVATE } = await import('./dream.mjs');"],
  ['(7) map-review calls a changed draft stale', MR, 'call it stale', 'note it'],
  ['(7) map-review offers nothing when not judged', MR, '"Not judged" means', 'It means'],
  ['(7) map-review removes only on a yes', MR, 'Remove it only on', 'Remove it on'],
  ['(7) map-review removes only on a fresh verdict', MR, 'whose own trial, not stale, says', 'whose own trial says'],
];
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const dry = fast || only;
const lines = [`platform ${process.platform}, ${fast ? 'trial8e alone' : 'the self-test'}${dry ? ' (a dry run)' : ''}`];
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
  fs.writeFileSync(target, src.replace(a, () => b));
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
  const r = spawnSync('node', [path.join(dir, 'plugin', 'test', fast ? 'trial8e.mjs' : 'selftest.mjs')], { encoding: 'utf8', timeout: 1_200_000 });
  const killed = r.status !== 0;
  if (!killed) bad++;
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
if (!dry) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8e-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
