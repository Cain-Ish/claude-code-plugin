// 06, section 8, 8k, group A (the hook side): one case per item, each in its own temp repo, run against the plugin
// folder given (default: this one). Every case prints pass or fail; the exit code is the number of failures. Run on
// the 8i and 8j copy it shows which cases that build fails. Hooks run on the Node that runs this file.
//   node fix8k-hook.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');
const STATUS = path.join(PLUGIN, 'scripts', 'status.mjs');
const NODE = process.execPath;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8k-'));
const ostemp = path.join(tmp, 'ostemp');
fs.mkdirSync(ostemp);
// a Claude Code shell sets NoDefaultCurrentDirectoryInExePath; a plain shell does not, so the children run without it,
// and never with the session's own plugin data. A PATH given replaces the one inherited in any letter case
const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(NoDefaultCurrentDirectoryInExePath|CLAUDE_PLUGIN_DATA|CLAUDE_PLUGIN_ROOT)$/i.test(k)));
const env = (repo, extra = {}) => ({ ...Object.fromEntries(Object.entries(clean).filter(([k]) => !(extra.PATH && /^path$/i.test(k)))), CLAUDE_PROJECT_DIR: repo, BRAIN_DIR: path.join(tmp, 'no-v1'), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp, ...extra });
const node = (args, repo, { input = '', extra, timeout = 60_000, cwd } = {}) => spawnSync(NODE, args, { input, encoding: 'utf8', env: env(repo, extra), timeout, cwd });
// a preload that runs before the hook's modules (node --import)
const pre = (code) => ['--import', `data:text/javascript,${encodeURIComponent(`import fs from 'node:fs'; ${code}`)}`];
const hook = (repo, which, input, opts = {}) => {
  const t0 = Date.now();
  const r = node([...(opts.pre ?? []), HOOK, which], repo, { ...opts, input: typeof input === 'string' ? input : JSON.stringify({ cwd: repo, session_id: 'fix8k', ...input }) });
  const j = r.stdout ? JSON.parse(r.stdout) : {};
  return { out: j.hookSpecificOutput?.additionalContext ?? '', msg: j.systemMessage, raw: r.stdout, ms: Date.now() - t0, status: r.status, timedOut: r.error?.code === 'ETIMEDOUT', err: r.stderr };
};
const bashHook = (repo, command, response) => hook(repo, 'bash', { tool_input: { command }, tool_response: response });
const status = (repo, data = path.join(tmp, 'status-data')) => node([STATUS, data], repo);
const entry = (h, q, src = 'the lead developer, 2026-11-08', more = '') => `### ${h}\n> ${q}\n\n- source: ${src}\n- when: ["work"]\n${more}`;
let n = 0;
const repoWith = (files, uncommitted = {}) => {
  const r = path.join(tmp, `r${++n}`);
  fs.mkdirSync(r, { recursive: true });
  const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' });
  g('init', '-q');
  for (const [f, t] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); }
  g('add', '-A');
  g('commit', '-qm', 'base');
  for (const [f, t] of Object.entries(uncommitted)) { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.appendFileSync(path.join(r, f), t); }
  return r;
};
const MAPF = '.project-map/decisions.md';
const base = () => repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.'), 'README.md': '# r\n' }, { [MAPF]: `\n${entry('pricing', 'Prices round half up to whole cents.')}` });
const posix = process.platform !== 'win32';
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message); } };
const NEEDS = 'The project map needs Node 20 or later; install it, or disable the plugin.';
console.log(`node ${process.version}; hooks run on ${spawnSync(NODE, ['-p', 'process.version'], { encoding: 'utf8' }).stdout.trim()}`);

// H1 in 8h's guard (C-10): a command names the map when it does so after letter case, quotes, backslashes and a
// backslash-newline are set aside, so the guard is never narrower than the if field's match (8a's four naming cases)
for (const cmd of ['cat ".project-"map/decisions.md', 'cat .project\\-map/decisions.md', 'cat .Project-Map/decisions.md', 'cat .project-\\\nmap/decisions.md | tr a-z A-Z']) {
  await tryCheck(`H1 named as ${JSON.stringify(cmd)}`, () => { const x = bashHook(base(), cmd, { stdout: 'x\n', stderr: '' }); check(`H1 named as ${JSON.stringify(cmd)}`, x.out.includes('pricing: unreviewed, not yet committed'), x.out.slice(0, 160)); });
}

// H3: a link in the map that leads out of the repo is never walked or read, so no name from there is listed either; the
// whole folder fails closed
await tryCheck('H3 link out of the repo', () => {
  const r = base();
  const outside = path.join(tmp, 'outside', 'deep');
  fs.mkdirSync(outside, { recursive: true });
  fs.writeFileSync(path.join(outside, 'notes.md'), entry('Outside heading', 'Text from outside the repo stays out.'));
  fs.symlinkSync(path.join(tmp, 'outside'), path.join(r, '.project-map', 'out'), 'junction');
  const x = bashHook(r, `cat ${MAPF}`, { stdout: 'x\n', stderr: '' });
  check('H3 link out of the repo', !/Outside heading|notes\.md/.test(x.out) && x.out.includes('The labels for .project-map/ could not be computed'), x.out.slice(0, 200));
});
// a single map file linked out of the repo (file links need POSIX, or Windows' developer mode)
await tryCheck('H3 file link out of the repo', () => {
  const r = base();
  const outside = path.join(tmp, 'outside-file.md');
  fs.writeFileSync(outside, entry('Outside file heading', 'Text from a file outside the repo stays out.'));
  try { fs.symlinkSync(outside, path.join(r, '.project-map', 'linked.md'), 'file'); } catch (e) { if (e.code === 'EPERM') return console.log('skip  H3 file link out of the repo: no file links here'); throw e; }
  const x = bashHook(r, `cat ${MAPF}`, { stdout: 'x\n', stderr: '' });
  const y = hook(r, 'read', { tool_input: { file_path: path.join(r, '.project-map', 'linked.md') } });
  check('H3 file link out of the repo', [x.out, y.out].every((o) => !o.includes('Outside file heading') && o.includes('The labels for .project-map/linked.md could not be computed')), `${x.out.slice(0, 160)} | ${y.out.slice(0, 160)}`);
});
// the map folder itself linked out of the repo: nothing under it is walked, read or named
await tryCheck('H3 the map folder linked out', () => {
  const r = repoWith({ 'README.md': '# r\n' });
  const outside = path.join(tmp, 'outside-map', 'sub', 'deeper');
  fs.mkdirSync(outside, { recursive: true });
  fs.writeFileSync(path.join(outside, 'client-acme-contract.md'), entry('Outside map heading', 'Text from outside the repo stays out.'));
  fs.symlinkSync(path.join(tmp, 'outside-map'), path.join(r, '.project-map'), 'junction');
  const x = bashHook(r, 'cat .project-map/sub/deeper/client-acme-contract.md', { stdout: 'x\n', stderr: '' });
  const s = hook(r, 'session-start', { source: 'startup' });
  check('H3 the map folder linked out', x.out.includes('The labels for .project-map/ could not be computed') && ![x.out, s.out].some((o) => /client-acme|Outside map heading/.test(o)), `${x.out.slice(0, 160)} | ${s.out.slice(0, 300)}`);
});

// H4: a map file over 4 MB is read nowhere: its labels fail closed, the catalog shows its bare name, its proposal does
// not wait, its ids are not read (so no id is called missing on a partial read), and status names it as unreadable
await tryCheck('H4 map file over 4 MB', () => {
  const r = base();
  fs.writeFileSync(path.join(r, '.project-map', 'huge.md'), `---\nname: huge\ndescription: Huge.\n---\n${entry('huge', 'A very large map file stays unread.', 'the PM, 2026-11-08', '- id: huge-1\n- proposed: dream 2026-11-19\n')}${'x'.repeat(5 << 20)}`);
  fs.appendFileSync(path.join(r, MAPF), `\n${entry('ended', 'An older rule here.', 'the PM, 2026-11-08', '- id: ended-1\n- status: superseded 2026-11-09 by gone-1: nothing\n')}`);
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, '.project-map', 'huge.md') } });
  const y = hook(r, 'read', { tool_input: { file_path: path.join(r, MAPF) } });
  const s = hook(r, 'session-start', { source: 'startup' }, { extra: { CLAUDE_PLUGIN_DATA: path.join(tmp, 'h4-data') } });
  const st = status(r).stdout;
  check('H4 map file over 4 MB', /could not be computed/.test(x.out) && y.out.includes('3. ended') && !y.out.includes('replaced by gone-1') && s.status === 0 && s.out.includes('.project-map/: decisions.md, huge.md\n') && !s.msg && st.includes('Cannot read .project-map/huge.md'), `${x.out.slice(0, 100)} | ${y.out.slice(0, 300)} | ${s.out.split('\n').find((l) => l.startsWith('.project-map/'))} | ${s.msg} | ${st}`);
});
if (posix) {
  await tryCheck('H4 FIFO at session start', () => {
    const r = base();
    spawnSync('mkfifo', [path.join(r, '.project-map', 'pipe.md')]);
    const s = hook(r, 'session-start', { source: 'startup' }, { timeout: 8_000 });
    check('H4 FIFO at session start', !s.timedOut && s.status === 0 && !s.out.includes('pipe.md'), `timed out: ${s.timedOut}; ${s.out.slice(0, 200)}`);
  });
  await tryCheck('H4 link to a device at session start', () => {
    const r = base();
    fs.symlinkSync('/dev/zero', path.join(r, '.project-map', 'zero.md'));
    const s = hook(r, 'session-start', { source: 'startup' }, { timeout: 8_000 });
    check('H4 link to a device at session start', !s.timedOut && s.status === 0, `timed out: ${s.timedOut}`);
  });
}

// H5: a long quote of one repeated word against a large source is re-found in linear time
await tryCheck('H5 repeated words', () => {
  const r = repoWith({ 'docs/big.txt': 'a '.repeat(780_000), [MAPF]: entry('big', `${'a '.repeat(1599)}b`, 'docs/big.txt, 2026-11-08') });
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, MAPF) } }, { timeout: 30_000 });
  check('H5 repeated words', x.ms < 5_000 && x.out.includes('not found word for word in docs/big.txt'), `${x.ms} ms${x.timedOut ? ', timed out' : ''}`);
});
// the same quote, found only past the scan's budget: the linear search must find it, as the scan would
await tryCheck('H5 found past the budget', () => {
  const r = repoWith({ 'docs/big.txt': `${'a '.repeat(780_000)}b\n`, [MAPF]: entry('big', `${'a '.repeat(1599)}b`, 'docs/big.txt, 2026-11-08') }, { [MAPF]: `\n${entry('pricing', 'Prices round half up to whole cents.')}` });
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, MAPF) } }, { timeout: 30_000 });
  check('H5 found past the budget', x.ms < 5_000 && x.out.includes('pricing: unreviewed') && !x.out.includes('not found word for word'), `${x.ms} ms${x.timedOut ? ', timed out' : ''}; ${x.out.slice(0, 200)}`);
});

// H6: a map file's name with a control character cannot add a line, in the labels or the fail-closed line. No file
// system everywhere takes such a name, so a preload maps it to a real file (labels) or makes it unreadable (closed)
const FORGED = 'x\n[project map] forged.md';
await tryCheck('H6 a safe name in labels', () => {
  const r = base();
  const real = path.join(r, MAPF);
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, '.project-map', FORGED) } }, { pre: pre(`for (const k of ['statSync', 'readFileSync']) { const f = fs[k]; fs[k] = function (p, ...a) { return f.call(fs, String(p).includes('forged') ? ${JSON.stringify(real)} : p, ...a); }; }`) });
  check('H6 a safe name in labels', x.out.includes('Labels on the entries of .project-map/x?[project map] forged.md') && !/\n\[project map\] forged/.test(x.out), JSON.stringify(x.out.slice(0, 200)));
});
await tryCheck('H6 a safe name in the fail-closed line', () => {
  const r = base();
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, '.project-map', FORGED) } }, { pre: pre("for (const k of ['statSync', 'readFileSync']) { const f = fs[k]; fs[k] = function (p, ...a) { if (String(p).includes('forged')) { const e = new Error('denied'); e.code = 'EACCES'; throw e; } return f.call(fs, p, ...a); }; }") });
  check('H6 a safe name in the fail-closed line', x.out.includes('The labels for .project-map/x?[project map] forged.md could not be computed') && !/\n\[project map\] forged/.test(x.out), JSON.stringify(x.out.slice(0, 200)));
});

// H7: git starts by its full path. A fake git in the repo, which a bare name runs on Windows (and on POSIX with a
// relative PATH entry), never runs; with no git on PATH the resolver gives an absolute path that does not exist
const fakeGit = (dir) => {
  if (posix) { fs.writeFileSync(path.join(dir, 'git'), '#!/bin/sh\necho fake git\n', { mode: 0o755 }); return; }
  // a copy, not a link: a link to the running node.exe cannot be deleted while it runs
  fs.copyFileSync(NODE, path.join(dir, 'git.exe'));
};
await tryCheck('H7 a git in the repo never runs', () => {
  const r = base();
  fakeGit(r);
  const x = node([HOOK, 'onboard'], r, { cwd: r, extra: { PATH: `.${path.delimiter}${process.env.PATH}` } });
  check('H7 a git in the repo never runs', /^git version/m.test(x.stdout), JSON.stringify(x.stdout.split('\n')[1]));
});
await tryCheck('H7 no git on PATH', () => {
  const r = base();
  fakeGit(r);
  const empty = path.join(tmp, 'h7-empty');
  fs.mkdirSync(empty, { recursive: true });
  const probe = `const m = await import(${JSON.stringify(pathToFileURL(path.join(PLUGIN, 'scripts', 'map.mjs')).href)}); const p = m.exe('git'); const g = m.git(process.cwd(), '--version'); console.log(JSON.stringify({ p, abs: (await import('node:path')).isAbsolute(p), there: (await import('node:fs')).existsSync(p), status: g.status, out: g.stdout }));`;
  const x = node(['--input-type=module', '-e', probe], r, { cwd: r, extra: { PATH: `.${path.delimiter}${empty}` } });
  const o = JSON.parse(x.stdout || '{}');
  const ob = node([HOOK, 'onboard'], r, { cwd: r, extra: { PATH: `.${path.delimiter}${empty}` } }).stdout;
  check('H7 no git on PATH', o.abs === true && o.there === false && o.status !== 0 && !o.out && ob.includes('git not found: the project map needs git'), `${x.stdout}${x.stderr.slice(0, 200)} | ${ob.split('\n')[1]}`);
});

// Q-1: a forked session starts as a resumed one does, so it gets the start context too (the docs leave open whether a
// fork carries its parent's). Q-3: each hook stops after 10 seconds, not the default 600 (30 for UserPromptSubmit)
await tryCheck('Q-1 and Q-3 in hooks.json', () => {
  const { hooks } = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
  const all = Object.values(hooks).flatMap((g) => g.flatMap((m) => m.hooks));
  check('Q-1 the fork source', hooks.SessionStart[0].matcher.split('|').includes('fork'), hooks.SessionStart[0].matcher);
  check('Q-3 a 10-second timeout on every hook', all.length === 8 && all.every((h) => h.timeout === 10), JSON.stringify(all.map((h) => h.timeout)));
});

// Q-8: a folder with no .git gets nothing at session start
await tryCheck('Q-8 no .git, no start text', () => {
  const r = path.join(tmp, 'q8');
  fs.mkdirSync(path.join(r, '.project-map'), { recursive: true });
  fs.writeFileSync(path.join(r, MAPF), entry('a', 'b c d'));
  const x = hook(r, 'session-start', { source: 'startup' });
  check('Q-8 no .git, no start text', x.status === 0 && x.raw === '', `${x.raw.length} bytes: ${x.raw.slice(0, 80)}`);
});
// a repo whose git cannot run (not found, a folder git does not trust, a broken index): nothing for Claude, and one
// line for the person saying why, with no absolute path
const empty = path.join(tmp, 'no-git-here');
fs.mkdirSync(empty);
for (const [why, extra, says, pre] of [
  ['git not found', { PATH: empty }, 'git was not found on PATH'],
  // no system or global config, so a runner's safe.directory (CI's macOS and Linux) cannot trust the folder
  ['an untrusted folder', { GIT_TEST_ASSUME_DIFFERENT_OWNER: '1', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(empty, 'none') }, "git does not trust this folder (another user owns it; see git's safe.directory)"],
  ['a broken index', {}, "git could not list this repository's files", (r) => fs.writeFileSync(path.join(r, '.git', 'index'), 'not an index')],
]) {
  await tryCheck(`Q-8 a repo where git cannot run: ${why}`, () => {
    const r = base();
    pre?.(r);
    const x = hook(r, 'session-start', { source: 'startup' }, { extra });
    check(`Q-8 a repo where git cannot run: ${why}`, x.status === 0 && x.out === '' && x.msg === `second-brain: the project map needs git, and ${says}, so this session has no map.`, `${x.msg} | ${x.out.slice(0, 80)}`);
  });
}

// Q-9: an entry a status line ended is never due, in the catalog's count or the read labels (status already skips it)
await tryCheck('Q-9 an ended entry is never due', () => {
  const r = repoWith({ '.project-map/ui.md': `---\nname: ui\ndescription: UI.\n---\n${entry('old', 'Old rule here.', 'the PM, 2026-11-01', '- id: old-1\n- review: 2000-01-01\n- status: superseded 2026-11-02 by new-1: nothing\n')}\n${entry('new', 'New rule here.', 'the PM, 2026-11-02', '- id: new-1\n- review: 2000-01-01\n')}` });
  const s = hook(r, 'session-start', { source: 'compact' });
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, '.project-map', 'ui.md') } });
  check('Q-9 an ended entry is never due', s.out.includes('ui.md (UI.; 2 entries, 1 due)') && !/1\. old:[^\n]*review due/.test(x.out) && /2\. new:[^\n]*review due since 2000-01-01/.test(x.out), `${s.out.split('\n').find((l) => l.startsWith('.project-map/'))} | ${x.out}`);
});

// Q-10: a transcript the dream read that grew since (a resumed session) counts as new
await tryCheck('Q-10 a grown transcript counts', async () => {
  const { unseenIn } = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'map.mjs')).href);
  const d = path.join(tmp, 'q10');
  fs.mkdirSync(d);
  for (const f of ['same.jsonl', 'grown.jsonl', 'new.jsonl']) fs.writeFileSync(path.join(d, f), '{"x":1}\n');
  const got = unseenIn([d], { 'same.jsonl': 8, 'grown.jsonl': 4 }).map((p) => path.basename(p)).sort();
  check('Q-10 a grown transcript counts', JSON.stringify(got) === '["grown.jsonl","new.jsonl"]', JSON.stringify(got));
});

// Q-11: status with no .git says so plainly: no raw error and no absolute path
await tryCheck('Q-11 status with no .git', () => {
  const r = path.join(tmp, 'q11');
  fs.mkdirSync(path.join(r, '.project-map'), { recursive: true });
  fs.writeFileSync(path.join(r, MAPF), entry('a', 'b c d'));
  const x = status(r);
  check('Q-11 status with no .git', x.status === 0 && /not in a git repository/.test(x.stdout) && !/ENOENT|stopped/.test(x.stdout) && !x.stdout.includes(tmp) && !x.stdout.includes(path.basename(tmp)), x.stdout + x.stderr);
});

// Q-12: a repo reached through a link (macOS /var, a junction) still labels a Read that names its real path; and no
// file-system call touches the model's path before a string check places it in the repo
await tryCheck('Q-12 the root by its real path', () => {
  const real = path.join(tmp, 'q12real');
  const r = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.') }, { [MAPF]: `\n${entry('pricing', 'Prices round half up to whole cents.')}` });
  fs.renameSync(r, real);
  const link = path.join(tmp, 'q12link');
  fs.symlinkSync(real, link, 'junction');
  const x = hook(link, 'read', { cwd: link, tool_input: { file_path: path.join(fs.realpathSync.native(real), '.project-map', 'decisions.md') } });
  check('Q-12 the root by its real path', x.out.includes('pricing: unreviewed, not yet committed'), x.out.slice(0, 160));
});
await tryCheck("Q-12 no file-system call on the model's path", () => {
  const r = base();
  const touched = path.join(tmp, 'q12-touched.txt');
  const spy = `for (const k of ['statSync', 'lstatSync', 'existsSync', 'readFileSync', 'openSync', 'realpathSync', 'readdirSync', 'accessSync']) { const f = fs[k]; const g = function (p, ...a) { if (String(p).includes('model-only')) fs.appendFileSync(${JSON.stringify(touched)}, k + ' '); return f.call(fs, p, ...a); }; if (f.native) g.native = function (p, ...a) { if (String(p).includes('model-only')) fs.appendFileSync(${JSON.stringify(touched)}, k + '.native '); return f.native.call(fs, p, ...a); }; fs[k] = g; }`;
  const x = hook(r, 'read', { tool_input: { file_path: path.join(tmp, 'model-only', '.project-map', 'decisions.md') } }, { pre: pre(spy) });
  const calls = fs.existsSync(touched) ? fs.readFileSync(touched, 'utf8') : '';
  check("Q-12 no file-system call on the model's path", x.status === 0 && x.out === '' && calls === '', `calls: ${calls}; ${x.out.slice(0, 100)}${x.err.slice(0, 200)}`);
});

// Q-13: below Node 20 (a preload reports 16.20.2) every hook exits 0 without reading its input, and only session start
// says so, so the person reads it once a session, not after every prompt and Read
await tryCheck('Q-13 Node below 20', () => {
  const r = base();
  const old = pre("Object.defineProperty(process, 'versions', { value: { ...process.versions, node: '16.20.2' } });");
  const got = ['session-start', 'prompt', 'read', 'bash', 'bash-failure'].map((w) => { const x = node([...old, HOOK, w], r, { input: 'not json' }); return `${w}: ${x.status} ${x.stdout}${x.stderr.split('\n').find((l) => /Error/.test(l)) ?? ''}`; });
  check('Q-13 Node below 20', got[0] === `session-start: 0 ${JSON.stringify({ systemMessage: NEEDS })}` && got.slice(1).every((g) => g.endsWith(': 0 ')), got.join(' | '));
});

// K-5 (L-6): an agent draft waits for review like a rule or skill draft, at session start and in status
await tryCheck('K-5 agent drafts wait', () => {
  const r = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.') }, { '.claude/agents/work-status.md.draft': '---\nname: work-status\n---\nx\n' });
  const s = hook(r, 'session-start', { source: 'startup' }, { extra: { CLAUDE_PLUGIN_DATA: path.join(tmp, 'k5-data') } });
  const st = status(r).stdout;
  check('K-5 agent drafts wait', /waiting for review: 1 draft\./.test(s.msg ?? '') && st.includes('Waiting for review: 1 draft.'), `${s.msg} | ${st}`);
});

// L-11: status names a kept file that is an earlier release's template, unchanged, and says to run setup
await tryCheck("L-11 an earlier release's template", () => {
  const text = fs.readFileSync(path.join(PLUGIN, 'test', 'earlier', '2.5.1', 'claude', 'skills', 'map-review', 'SKILL.md'), 'utf8');
  const r = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.'), '.claude/skills/map-review/SKILL.md': text });
  const st = status(r).stdout;
  check("L-11 an earlier release's template", /- Out of date: \.claude\/skills\/map-review\/SKILL\.md[^\n]*Run \/second-brain:setup/.test(st), st);
});

// the audit's item 2: a proposal review rejected (its "by review:" status line) no longer waits, nor is labelled or
// counted as proposed
await tryCheck('Audit 2 a rejected proposal', () => {
  const r = repoWith({ '.claude/skills/map-review/SKILL.md': 'x\n', [MAPF]: entry('rejected', 'Buttons use the accent colour.', 'the PM, 2026-11-08', '- proposed: dream 2026-11-19\n- status: expired 2026-11-20 by review: rejected\n') });
  const s = hook(r, 'session-start', { source: 'startup' }, { extra: { CLAUDE_PLUGIN_DATA: path.join(tmp, 'a2-data') } });
  const x = hook(r, 'read', { tool_input: { file_path: path.join(r, MAPF) } });
  const st = status(r).stdout;
  check('Audit 2 a rejected proposal', !/waiting/.test(s.msg ?? '') && !x.out.includes('proposed by a dream') && st.includes('Retired (with a status line): 1. Proposed by a dream: 0.'), `${s.msg} | ${x.out} | ${st.split('\n').at(-1)}`);
});

// the index's exclusions: .project-map/index.ignore. A folder line (with a byte-order mark, a leading / and CRLF), and
// the patterns **/fixtures and */fixtures/*, each leave out what a glob of the line, or of everything under it, matches;
// every other start-text line stays, and one ls-files call still. A line naming the map leaves it listed. A line git
// rejects gives the full index, one call more, and the person is told the file is not used
const EX = { 'README.md': '# r\n', 'docs/archive/old.md': 'x\n', 'docs/archive/deep/older.md': 'x\n', 'docs/guide.md': 'x\n', 'a/fixtures/f.md': 'x\n', 'a/fixtures/deep/h.md': 'x\n', 'b/c/fixtures/g.md': 'x\n', 'fixtures/r.md': 'x\n', 'a/z.md': 'x\n', [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.') };
const lsCalls = (trace) => (fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8').split('\n').filter((l) => /\btrace: built-in: git ls-files\b/.test(l)).length : 0);
const startIn = (r, name) => { const trace = path.join(tmp, `${name}.trace`); const x = hook(r, 'session-start', { source: 'startup' }, { extra: { GIT_TRACE: trace } }); return { ...x, calls: lsCalls(trace) }; };
const dirsOf = (r) => Number(/in (\d+) directories/.exec(node([HOOK, 'onboard'], r).stdout)?.[1]);
let exN = 0;
const exclusion = (text, uncommitted = {}) => {
  const r = repoWith(EX, uncommitted);
  const before = startIn(r, `ex${++exN}a`), d0 = dirsOf(r);
  fs.writeFileSync(path.join(r, '.project-map', 'index.ignore'), text);
  const after = startIn(r, `ex${exN}b`);
  const was = before.out.split('\n'), is = after.out.split('\n');
  const gone = was.filter((l) => !is.includes(l));
  return { gone, same: is.every((l) => was.includes(l)) && dirsOf(r) === d0 - gone.length, calls: after.calls, msg: after.msg, out: after.out };
};
for (const [name, text, want] of [
  ['a folder line', '﻿/docs/archive\r\n# old notes\n\n', ['docs/archive/deep/: older.md', 'docs/archive/: old.md']],
  ['the pattern **/fixtures', '**/fixtures\n', ['a/fixtures/deep/: h.md', 'a/fixtures/: f.md', 'b/c/fixtures/: g.md', 'fixtures/: r.md']],
  ['the pattern */fixtures/*', '*/fixtures/*\n', ['a/fixtures/deep/: h.md', 'a/fixtures/: f.md']],
]) {
  await tryCheck(`exclusions: ${name}`, () => {
    const x = exclusion(text);
    check(`exclusions: ${name}`, JSON.stringify(x.gone) === JSON.stringify(want) && x.same && x.calls === 1 && !x.msg, `gone ${JSON.stringify(x.gone)}; the rest unchanged ${x.same}; ls-files calls ${x.calls}; ${x.msg}`);
  });
}
await tryCheck('exclusions: the map stays listed', () => {
  const x = exclusion('.project-map\n', { '.project-map/new.md': entry('fresh', 'Fresh and untracked here.') });
  check('exclusions: the map stays listed', x.gone.length === 0 && x.out.split('\n').includes('.project-map/: decisions.md, new.md'), `gone ${JSON.stringify(x.gone)}`);
});
await tryCheck('exclusions: a line git rejects', () => {
  const x = exclusion('docs/archive\n../outside\n');
  check('exclusions: a line git rejects', x.gone.length === 0 && x.same && x.msg === 'second-brain: git rejected a line of .project-map/index.ignore, so the index does not use that file this session.' && x.calls === 2, `gone ${JSON.stringify(x.gone)}; ${x.msg}; ls-files calls ${x.calls}`);
});

// R8: no hook writes to the repo, whatever it is given; checked after each hook event
await tryCheck('R8 hooks write nothing', () => {
  const r = base();
  const snap = () => JSON.stringify([spawnSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: r, encoding: 'utf8' }).stdout, ...fs.readdirSync(path.join(r, '.project-map')).map((f) => fs.readFileSync(path.join(r, '.project-map', f), 'utf8'))]);
  const before = snap();
  const changed = [
    ['session-start', () => hook(r, 'session-start', { source: 'startup' })],
    ['prompt', () => hook(r, 'prompt', { prompt: 'go' })],
    ['read', () => hook(r, 'read', { tool_input: { file_path: path.join(r, MAPF) } })],
    ['bash', () => bashHook(r, `cat ${MAPF}`, { stdout: 'x\n', stderr: '' })],
    ['bash-failure', () => hook(r, 'bash-failure', { tool_input: { command: `cat ${MAPF}` }, error: 'exit 1' })],
  ].filter(([, go]) => { go(); return snap() !== before; }).map(([ev]) => ev);
  check('R8 hooks write nothing', !changed.length, `the repo changed after ${changed.join(', ')}`);
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8k-hook ok');
process.exitCode = failed;
