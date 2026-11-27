// 06, section 9 (2.6.1, the audit's fixes AU-1 to AU-20; AU-4 is checked at the release): one case per item, each in
// its own temp repo, run against the plugin folder given (default: this one). Every case prints pass or fail; the exit
// code is the number of failures. Run on 2.6.0's product it shows which cases that build fails.
//   node fix261.mjs [plugin folder]
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.resolve(process.argv[2] ?? path.join(HERE, '..'));
const imp = (f) => import(pathToFileURL(path.join(PLUGIN, 'scripts', f)).href);
const D = await imp('dream.mjs');
const T = await imp('trial.mjs');
const M = await imp('map.mjs');
const S = await imp('setup.mjs');
const NODE = process.execPath;
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');
const tmp = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix261-')));
const ostemp = path.join(tmp, 'ostemp');
fs.mkdirSync(ostemp);
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${String(why).slice(0, 600)}`}`); if (!ok) failed++; };
// FIX261_ONLY=<regex>: only the cases whose name it matches (the mutation run's)
const only = process.env.FIX261_ONLY ? new RegExp(process.env.FIX261_ONLY) : null;
const tryCheck = async (id, f) => { if (only && !only.test(`${id} `)) return; try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const text = (f) => { try { return fs.readFileSync(path.join(PLUGIN, f), 'utf8'); } catch { return ''; } };
const flat = (s) => s.replace(/\s+/g, ' ');
const MR = 'templates/claude/skills/map-review/SKILL.md';
const MR260 = fs.readFileSync(path.join(HERE, 'earlier', '2.6.0-release', 'claude', 'skills', 'map-review', 'SKILL.md'), 'utf8');
const saved = { cfg: process.env.CLAUDE_CONFIG_DIR, stub: process.env.SECOND_BRAIN_TRIAL_CLAUDE };
// children run as from a plain shell, never with the session's own plugin variables, project or config
const clean = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(NoDefaultCurrentDirectoryInExePath|CLAUDE_PLUGIN_DATA|CLAUDE_PLUGIN_ROOT|CLAUDE_PROJECT_DIR|CLAUDE_CONFIG_DIR|CLAUDE_CODE_ENTRYPOINT)$/i.test(k))), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp };
let n = 0;
const put = (r, f, t) => { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); };
// a repo with files committed, then the uncommitted ones written
const repoWith = (files, uncommitted = {}) => {
  const r = path.join(tmp, `r${++n}`);
  const g = (...a) => { const x = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' }); if (x.status) throw new Error(x.stderr); return x.stdout; };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  g('config', 'core.autocrlf', 'false');
  for (const [f, t] of Object.entries(files)) put(r, f, t);
  g('add', '-A');
  g('commit', '-qm', 'base');
  for (const [f, t] of Object.entries(uncommitted)) put(r, f, t);
  return { r, g };
};
const hook = (arg, repo, input = {}, env = {}) => {
  const x = spawnSync(NODE, [HOOK, arg], { input: JSON.stringify({ cwd: repo, session_id: `fix261-${n}`, ...input }), encoding: 'utf8', env: { ...clean, CLAUDE_PROJECT_DIR: repo, BRAIN_DIR: path.join(tmp, 'no-v1'), ...env }, timeout: 60_000 });
  try { return JSON.parse(x.stdout); } catch { return { raw: x.stdout }; }
};
const ctx = (o) => o.hookSpecificOutput?.additionalContext ?? '';
const entry = (h, q, src = 'the lead developer, 2026-11-08') => `### ${h}\n> ${q}\n\n- id: ${h}\n- source: ${src}\n- when: ["work"]\n`;
const MAPF = '.project-map/decisions.md';
console.log(`node ${process.version}; plugin ${PLUGIN === path.resolve(HERE, '..') ? 'this one' : 'given'}`);

// a repo with past sessions for a dream: each session's user lines carry a marker, so a proposal's evidence can cite them
const dreamRepo = (files, sessions = [['Start, marker S1.', 'Tighten it, marker T1.'], ['Start, marker S2.', 'Tighten it, marker T2.']], extra = () => []) => {
  const { r, g } = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.'), '.project-map/dreams.md': '# Dream log\n\n', ...files });
  const cfg = path.join(tmp, `cfg${n}`);
  const data = path.join(tmp, `data${n}`);
  const tdir = path.join(cfg, 'projects', fs.realpathSync.native(r).replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(tdir, { recursive: true });
  const J = (o) => JSON.stringify({ cwd: r, timestamp: '2026-11-20T10:00:00Z', ...o });
  const U = (t) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: t } });
  sessions.forEach((us, k) => fs.writeFileSync(path.join(tdir, `s${k + 1}.jsonl`), `${[U(us[0]), ...extra(J, k), ...us.slice(1).map(U)].join('\n')}\n`));
  process.env.CLAUDE_CONFIG_DIR = cfg;
  const run = path.join(r, '.project-map', '.dream-run');
  const ref = (m) => { for (const f of fs.readdirSync(path.join(run, 'digests'))) { const i = fs.readFileSync(path.join(run, 'digests', f), 'utf8').split('\n').findIndex((l) => l.startsWith('U: ') && l.includes(m)); if (i >= 0) return `${f}:${i + 1}`; } throw new Error(`no digest holds ${m}`); };
  const stage = (p, t) => { fs.mkdirSync(path.dirname(path.join(run, 'proposals', p)), { recursive: true }); fs.writeFileSync(path.join(run, 'proposals', p), `${t}<!-- evidence: ${ref('T1')}, ${ref('T2')} -->\n`); };
  return { r, g, cfg, data, tdir, stage, J };
};
const runId = (report) => /^Run id: ([0-9a-f]{8}) /m.exec(report)?.[1];

// a trial's repo: a case file and a check script committed, the artifact as given
const ok = '.project-map/evals/checks/ok.mjs';
const caseFile = (artifact, tools, more = []) => JSON.stringify({ artifact, runs: 3, cases: [
  { id: 'one', prompt: 'Price the cart for the order.', tools, check: ok },
  { id: 'two', prompt: 'Price the second order.', tools, check: ok },
  { id: 'other', prompt: 'An unrelated task here.', tools, use: false, check: ok }, ...more] }, null, 1);
const stubs = path.join(tmp, 'stubs');
fs.mkdirSync(stubs);
const stub = (name, ms) => { const p = path.join(stubs, name); fs.writeFileSync(p, `setTimeout(() => console.log(JSON.stringify({ type: 'result', is_error: false, result: 'ok' })), ${ms});\n`); return p; };
const FAST = stub('fast.mjs', 0);
const SLOW = stub('slow.mjs', 6000);
let slowUsed = false;
const SKILL = '---\nname: pricing\ndescription: Prices the cart. Use when asked to price it.\n---\nPrice it with price.mjs.\n';

// AU-1 (attempt 3): show names each power a draft sets, with what it does, an odd key beside another power too; a
// plain draft gets no such line
await tryCheck('AU-1 show names each power', () => {
  const ag = (name, more = '', end = '\nBody.\n') => `---\nname: ${name}\ndescription: ${name} does one task.\ntools: Read\n${more}---${end}`;
  const POW = { perm: 'permissionMode, so its sessions may skip permission prompts', hooks: 'hooks, commands that run as you', mcp: 'mcpServers, servers its sessions start',
    mem: 'a memory other than project or local', odd: 'a top-level line that is not a plain key' };
  const drafts = { a1: ['permissionMode: bypassPermissions\n', ['perm']], a2: ['hooks:\n  PreToolUse: []\n', ['hooks']], a3: ['mcpServers:\n  x: {}\n', ['mcp']],
    a4: ['memory: user\n', ['mem']], a5: ['"permissionMode": bypassPermissions\n', ['odd']], a6: ['permissionMode: bypassPermissions\n', ['perm'], ''],
    a7: ['hooks:\n  PreToolUse: []\n"mcpServers": {}\n', ['hooks', 'odd']], k1: ['memory: project\n', []] };
  const files = { 'README.md': '# r\n', [ok]: 'process.exit(0);\n', '.project-map/evals/s1.json': caseFile('.claude/skills/s1/SKILL.md.draft', ['Read', 'Skill']), '.project-map/evals/a8.json': caseFile('.claude/agents/a8.md.draft', ['Read', 'Agent']) };
  for (const k of Object.keys(drafts)) files[`.project-map/evals/${k}.json`] = caseFile(`.claude/agents/${k}.md.draft`, ['Read', 'Agent']);
  const { r } = repoWith(files);
  for (const [k, [more, , end]] of Object.entries(drafts)) put(r, `.claude/agents/${k}.md.draft`, ag(k, more, end));
  // a closing --- with spaces after it
  put(r, '.claude/agents/a8.md.draft', '---\nname: a8\ndescription: a8 does one task.\ntools: Read\npermissionMode: bypassPermissions\n---  \nBody.\n');
  put(r, '.claude/skills/s1/SKILL.md.draft', '---\nname: s1\ndescription: Does s1. Use when asked.\nallowed-tools: Bash(node .claude/skills/s1/run.mjs:*)\n---\nDo it.\n');
  const warns = (name) => T.show(r, name).split('\n').filter((l) => l.startsWith('Warning: it sets '));
  const want = { ...Object.fromEntries(Object.entries(drafts).map(([k, [, w]]) => [k, w.map((x) => POW[x])])), a8: [POW.perm], s1: ['allowed-tools, what it runs without asking'] };
  const got = Object.fromEntries(Object.keys(want).map((k) => [k, warns(k)]));
  check('AU-1 show names each power', Object.entries(want).every(([k, w]) => got[k].length === w.length && w.every((x, i) => got[k][i].includes(x))), JSON.stringify(got));
});

// AU-2: the verdict's blob ids cover every file the trial ran from
await tryCheck('AU-2 verdict blobs', async () => {
  const art = '.claude/skills/pricing/SKILL.md.draft';
  const { r, g } = repoWith({ 'README.md': '# r\n', [ok]: 'process.exit(0);\n', '.project-map/evals/pricing.json': caseFile(art, ['Read', 'Skill']) }, { [art]: SKILL, '.claude/skills/pricing/price.mjs': 'console.log(1);\n' });
  process.env.SECOND_BRAIN_TRIAL_CLAUDE = FAST;
  const hash = /run pricing ([0-9a-f]{12})"?\s*$/.exec(T.show(r, 'pricing'))?.[1];
  const out = await T.exec(r, 'pricing', hash);
  const files = [art, '.project-map/evals/pricing.json', ok, '.claude/skills/pricing/price.mjs'];
  const same = files.every((f) => out.blobs?.[f] === g('hash-object', '--', f).trim());
  fs.appendFileSync(path.join(r, '.claude/skills/pricing/price.mjs'), 'process.exit(1);\n');
  const stale = out.blobs?.['.claude/skills/pricing/price.mjs'] !== g('hash-object', '--', '.claude/skills/pricing/price.mjs').trim();
  const pinned = flat(text(MR)).includes('If it has no `blobs`, or `git hash-object <file>` of a file its `blobs` names no longer equals the id there, call it stale.');
  check('AU-2 verdict blobs', same && stale && pinned && Object.keys(out.blobs ?? {}).length === 4, JSON.stringify({ blobs: out.blobs, same, stale, pinned }));
});

// AU-3: the dream's log line is named for the commit, and no dream is called due while it waits, with no git call at
// session start beyond the index's (D32; counted where git can be stood in for by a script, not on Windows)
await tryCheck('AU-3 the log line waits for its commit', async () => {
  const { r, g, data, tdir } = dreamRepo({ '.claude/skills/map-review/SKILL.md': MR260 });
  const prep = await D.prepare(r, data);
  const fin = D.finish(r, data, runId(prep));
  const next = fin.split('\n').find((l) => l.startsWith('Next:')) ?? '';
  for (let k = 0; k < 10; k++) fs.writeFileSync(path.join(tdir, `n${k}.jsonl`), '{}\n');
  const env = { CLAUDE_PLUGIN_DATA: data, CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR, CLAUDE_CODE_ENTRYPOINT: 'cli' };
  const log = path.join(tmp, `git${n}.log`);
  let shim = {};
  if (process.platform !== 'win32') {
    const real = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
    const dir = path.join(tmp, `shim${n}`);
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'git'), `#!/bin/sh\necho "$1" >> '${log}'\nexec '${real}' "$@"\n`, { mode: 0o755 });
    shim = { PATH: `${dir}${path.delimiter}${clean.PATH}` };
  }
  const start = (more = {}) => hook('session-start', r, { source: 'startup', transcript_path: path.join(tdir, 'now.jsonl') }, { ...env, ...more });
  const before = start(shim);
  const calls = process.platform === 'win32' ? ['ls-files'] : (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n') : []);
  g('add', '--', '.project-map/dreams.md');
  g('commit', '-qm', 'the dream log');
  const after = start();
  const DUE = 'A dream is due for this project';
  const pinned = flat(text(MR)).includes("and `.project-map/dreams.md` when it holds a dream's log line not yet committed (the next dream waits for that commit)");
  check('AU-3 the log line waits for its commit', next.includes('.project-map/dreams.md') && /would be due/.test(before.systemMessage ?? '') && (before.systemMessage ?? '').includes('.project-map/dreams.md') && !ctx(before).includes(DUE)
    && JSON.stringify(calls) === '["ls-files"]' && /a dream is due/.test(after.systemMessage ?? '') && ctx(after).includes(DUE) && pinned, JSON.stringify({ next, before: before.systemMessage, calls, after: after.systemMessage, pinned }));
});

// AU-5: one trial at a time across a repo's worktrees
await tryCheck('AU-5 one trial across worktrees', async () => {
  const art = '.claude/skills/pricing/SKILL.md.draft';
  const { r, g } = repoWith({ 'README.md': '# r\n', [ok]: 'process.exit(0);\n', '.project-map/evals/pricing.json': caseFile(art, ['Read', 'Skill']) }, { [art]: SKILL });
  const wt = path.join(tmp, `wt${n}`);
  g('worktree', 'add', '-q', wt);
  put(wt, art, SKILL);
  const hashOf = (root) => /run pricing ([0-9a-f]{12})"?\s*$/.exec(T.show(root, 'pricing'))?.[1];
  const locks = [path.join(r, '.git', 'second-brain-trial.lock'), path.join(r, '.project-map', '.trial', '.lock'), path.join(wt, '.project-map', '.trial', '.lock')];
  const kill = () => { for (const l of locks) { try { process.kill(Number(fs.readFileSync(l, 'utf8'))); } catch {} } };
  process.env.SECOND_BRAIN_TRIAL_CLAUDE = SLOW;
  slowUsed = true;
  let second, third;
  try {
    T.start(r, 'pricing', hashOf(r));
    try { T.start(wt, 'pricing', hashOf(wt)); second = 'started'; } catch (e) { second = e.message; }
    kill();
    await new Promise((done) => setTimeout(done, 500));
    try { T.start(wt, 'pricing', hashOf(wt)); third = 'started'; } catch (e) { third = e.message; }
  } finally { kill(); }
  check('AU-5 one trial across worktrees', /another trial is running/.test(second) && third === 'started', JSON.stringify({ second, third }));
});

// AU-6: a dream's skill draft with a command line is refused, and so is a change to a skill's command lines, whether
// it adds one or drops the guard lines of a fenced block
await tryCheck('AU-6 command lines in skill drafts', async () => {
  const helper = '---\nname: helper\ndescription: Helps with the task. Use when asked.\n---\nHelp with it.\n';
  const guard = '---\nname: guard\ndescription: Cleans the build. Use when asked.\n---\nClean it:\n```!\nif [ "$ALLOW_CLEAN" = "1" ]; then\n  rm -rf dist\nfi\n```\n';
  const use = (J, k, s) => [J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: `${s}${k}`, name: 'Skill', input: { skill: s } }] } }), J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: `${s}${k}`, content: 'ok' }] } })];
  const { r, data, stage } = dreamRepo({ '.claude/skills/helper/SKILL.md': helper, '.claude/skills/guard/SKILL.md': guard }, undefined, (J, k) => [...use(J, k, 'helper'), ...use(J, k, 'guard')]);
  const prep = await D.prepare(r, data);
  const sk = (name, body) => `---\nname: ${name}\ndescription: Does ${name}. Use when asked to do ${name}.\n---\n${body}\n`;
  stage('skills/bang/SKILL.md', sk('bang', 'First run !`git status` and read it.'));
  stage('skills/fence/SKILL.md', sk('fence', 'Then:\n```!\ngit log -1\n```\nRead it.'));
  stage('skills/prose/SKILL.md', sk('prose', 'Do it now! Then check the result.'));
  stage('change/skills/helper/SKILL.md', `${helper}!\`git status\`\n`);
  stage('change/skills/guard/SKILL.md', '---\nname: guard\ndescription: Cleans the build. Use when asked.\n---\nClean it now:\n```!\n  rm -rf dist\n```\n');
  const fin = D.finish(r, data, runId(prep));
  const has = (p) => fs.existsSync(path.join(r, p));
  // and AU-3's Next line, after a dream that proposed something
  const next = fin.split('\n').find((l) => l.startsWith('Next:')) ?? '';
  check('AU-6 command lines in skill drafts', next.includes('.project-map/dreams.md') && !has('.claude/skills/bang/SKILL.md.draft') && !has('.claude/skills/fence/SKILL.md.draft') && has('.claude/skills/prose/SKILL.md.draft')
    && !has('.claude/skills/helper/SKILL.md.draft') && !has('.claude/skills/guard/SKILL.md.draft') && /(^|\D)2 skill with a command line \(!\)/.test(fin) && /(^|\D)2 change to a command line \(!\)/.test(fin), fin);
});

// AU-7: every map file's HEAD text in one call (git not folding letter case, so AU-11's fallback cannot stand in)
await tryCheck('AU-7 HEAD texts at once', () => {
  const files = Object.fromEntries(Array.from({ length: 8 }, (_, k) => [`.project-map/t${k}.md`, entry(`t${k}`, `Topic ${k} holds its own rule here.`)]));
  const { r, g } = repoWith(files, { '.project-map/new.md': entry('new', 'A new topic not yet committed.') });
  g('config', 'core.ignorecase', 'false');
  const got = M.headTexts?.(r, [...Object.keys(files), '.project-map/new.md']);
  check('AU-7 HEAD texts at once', got instanceof Map && got.size === 8 && Object.entries(files).every(([f, t]) => got.get(f)?.toString('utf8') === t) && !got.has('.project-map/new.md'), String(got?.size));
});

// AU-8: one large directory early on hides no later one
await tryCheck('AU-8 the cut skips what does not fit', () => {
  const idx = `${M.HEADER}\n${['big/: ' + 'x'.repeat(9000), ...Array.from({ length: 41 }, (_, k) => `d${k}/: a.md, b.md`)].join('\n')}\n`;
  const s = M.startText(idx);
  check('AU-8 the cut skips what does not fit', s.listed === 41 && s.total === 42 && s.text.length <= M.CAP && s.text.includes('(1 more directory not listed') && s.text.includes('d40/: a.md'), JSON.stringify({ listed: s.listed, total: s.total, len: s.text.length }));
});

// AU-9: show warns for PowerShell and for either with the pattern *
await tryCheck('AU-9 show warns for any shell', () => {
  const art = '.claude/skills/pricing/SKILL.md.draft';
  const cases = ['Bash', 'PowerShell', 'Bash(*)', 'PowerShell(*)', 'Bash(git status)'].map((t, k) => ({ id: `c${k}`, prompt: `Price order ${k}.`, tools: ['Read', 'Skill', t], check: ok }));
  const spec = { artifact: art, runs: 3, cases: [...cases, { id: 'other', prompt: 'An unrelated task.', tools: ['Read', 'Skill'], use: false, check: ok }] };
  const { r } = repoWith({ 'README.md': '# r\n', [ok]: 'process.exit(0);\n', '.project-map/evals/pricing.json': JSON.stringify(spec, null, 1) }, { [art]: SKILL });
  const out = T.show(r, 'pricing');
  const warned = (k) => (out.split(`- case c${k} `)[1] ?? '').split('\n- case')[0].split('with no pattern: its sessions may run any command as you').length - 1;
  check('AU-9 show warns for any shell', [0, 1, 2, 3].every((k) => warned(k) === 1) && warned(4) === 0, JSON.stringify([0, 1, 2, 3, 4].map(warned)));
});

// AU-10: a finish after a newer prepare took the lock over applies nothing; nor does the command with no id
await tryCheck('AU-10 a late finish', async () => {
  const { r, cfg } = dreamRepo({});
  const data = path.join(cfg, 'plugins', 'data', 'second-brain');
  const a = runId(await D.prepare(r, data));
  const dir = M.stateDir(r, data);
  const old = Date.now() / 1000 - 3 * 3600;
  fs.utimesSync(path.join(dir, 'dream.lock'), old, old);
  const b = runId(await D.prepare(r, data));
  const state = () => { try { return fs.readFileSync(path.join(dir, 'state.json'), 'utf8'); } catch { return null; } };
  const st = state();
  let late;
  try { D.finish(r, data, a); late = 'finished'; } catch (e) { late = e.message; }
  const cli = spawnSync(NODE, [path.join(PLUGIN, 'scripts', 'dream.mjs'), 'finish', data], { cwd: r, encoding: 'utf8', env: { ...clean, CLAUDE_CONFIG_DIR: cfg, CLAUDE_PROJECT_DIR: r } });
  const kept = fs.existsSync(path.join(dir, 'dream.lock')) && JSON.parse(fs.readFileSync(path.join(dir, 'run', 'run.json'), 'utf8')).id === b && state() === st;
  let own;
  try { own = D.finish(r, data, b); } catch (e) { own = e.message; }
  check('AU-10 a late finish', a && b && a !== b && /not the run/.test(late) && cli.status === 1 && /needs the run id/.test(cli.stdout) && kept && /^Dream finished/.test(own), JSON.stringify({ a, b, late, cli: cli.stdout, kept, own: own.slice(0, 80) }));
});

// AU-11: a map file renamed by letter case only keeps its committed entries; one whose name folds to two tracked
// names is read as uncommitted
await tryCheck('AU-11 a case-only rename', () => {
  const { r, g } = repoWith({ '.project-map/Decisions.md': entry('dates', 'Dates show as DD.MM.YYYY across the app.') });
  g('config', 'core.ignorecase', 'true');
  fs.renameSync(path.join(r, '.project-map', 'Decisions.md'), path.join(r, '.project-map', 'x.tmp'));
  fs.renameSync(path.join(r, '.project-map', 'x.tmp'), path.join(r, '.project-map', 'decisions.md'));
  const read = ctx(hook('read', r, { tool_name: 'Read', tool_input: { file_path: path.join(r, '.project-map', 'decisions.md') } }));
  const bash = ctx(hook('bash', r, { tool_name: 'Bash', tool_input: { command: 'cat .project-map/decisions.md' }, tool_response: { stdout: '### dates\n> Dates show as DD.MM.YYYY across the app.\n', stderr: '' } }));
  // two tracked names, Rules.md and RULES.md, that fold alike (put in git's index by their ids: one disk cannot hold both)
  const two = repoWith({ 'README.md': '# r\n' });
  two.g('config', 'core.ignorecase', 'true');
  const text = entry('rules', 'Rules hold for the whole team here.');
  put(two.r, 'blob.txt', text);
  const oid = two.g('hash-object', '-w', 'blob.txt').trim();
  for (const f of ['.project-map/Rules.md', '.project-map/RULES.md']) two.g('update-index', '--add', '--cacheinfo', `100644,${oid},${f}`);
  two.g('commit', '-qm', 'two names');
  put(two.r, '.project-map/rules.md', text);
  const both = ctx(hook('read', two.r, { tool_name: 'Read', tool_input: { file_path: path.join(two.r, '.project-map', 'rules.md') } }));
  check('AU-11 a case-only rename', [read, bash].every((o) => o.includes('unverified quote, committed') && !o.includes('unreviewed')) && both.includes('unreviewed'), JSON.stringify({ read, bash, both }));
});

// AU-12: onboard and status say why git cannot run, and onboard says nothing then of what is committed
await tryCheck('AU-12 why git cannot run', () => {
  const { r } = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.') });
  const data = path.join(tmp, `data${n}`);
  const statusOf = (env) => spawnSync(NODE, ['--input-type=module', '-e', `const { status } = await import(${JSON.stringify(pathToFileURL(path.join(PLUGIN, 'scripts', 'status.mjs')).href)}); console.log(status(${JSON.stringify(r)}, ${JSON.stringify(data)}));`], { encoding: 'utf8', env: { ...clean, ...env }, cwd: r }).stdout;
  // no global or system git config, which on CI's runners trusts every folder (safe.directory=*)
  const empty = path.join(tmp, 'empty.gitconfig');
  fs.writeFileSync(empty, '');
  const owner = { GIT_TEST_ASSUME_DIFFERENT_OWNER: '1', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: empty };
  const onb = spawnSync(NODE, [HOOK, 'onboard'], { encoding: 'utf8', env: { ...clean, CLAUDE_PROJECT_DIR: r, ...owner } }).stdout;
  const st = statusOf(owner);
  const noGit = clean.PATH.split(path.delimiter).filter((d) => !['git', 'git.exe'].some((f) => fs.existsSync(path.join(d, f)))).join(path.delimiter);
  const st2 = statusOf({ PATH: noGit });
  check('AU-12 why git cannot run', /does not trust this folder/.test(onb) && !/Not a git repository/.test(onb) && !/not committed/.test(onb) && /does not trust this folder/.test(st) && !/never committed/.test(st) && /git was not found/.test(st2) && !/never committed/.test(st2), JSON.stringify({ onb, st, st2 }));
});

// AU-13: a map folder that is a link inside the repo stops prepare before any analysis
await tryCheck('AU-13 a linked map folder', async () => {
  const { r } = repoWith({ 'real-map/decisions.md': entry('dates', 'Dates show as DD.MM.YYYY across the app.'), 'README.md': '# r\n' });
  fs.symlinkSync(path.join(r, 'real-map'), path.join(r, '.project-map'), 'junction');
  const data = path.join(tmp, `data${n}`);
  process.env.CLAUDE_CONFIG_DIR = path.join(tmp, `cfg${n}`);
  let out;
  try { out = await D.prepare(r, data); } catch (e) { out = e.message; }
  check('AU-13 a linked map folder', /is a link/.test(out) && !fs.existsSync(path.join(M.stateDir(r, data), 'dream.lock')), out);
});

// AU-14: setup finds its section in a UTF-16 CLAUDE.md
await tryCheck('AU-14 a UTF-16 CLAUDE.md', () => {
  const tpl = fs.readFileSync(path.join(PLUGIN, 'templates', 'CLAUDE.template.md'), 'utf8');
  const body = `# Project\n\n## Team memory${tpl.split('## Team memory')[1]}`;
  const { r } = repoWith({ 'README.md': '# r\n' });
  fs.writeFileSync(path.join(r, 'CLAUDE.md'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(body, 'utf16le')]));
  spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qam', 'x'], { cwd: r });
  spawnSync('git', ['add', 'CLAUDE.md'], { cwd: r });
  spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'claude'], { cwd: r });
  const out = S.setup(r, PLUGIN);
  check('AU-14 a UTF-16 CLAUDE.md', !/has no team-memory section/.test(out), out);
});

// AU-15: a trial copy tracks a committed file that .gitignore matches
await tryCheck('AU-15 a force-added file in a copy', () => {
  const { r, g } = repoWith({ '.gitignore': 'build/\n', 'src/a.js': 'x\n' });
  put(r, 'build/out.txt', 'built\n');
  g('add', '-f', 'build/out.txt');
  g('commit', '-qm', 'forced');
  const to = path.join(tmp, `copy${n}`);
  T.copyHead(r, g('rev-parse', 'HEAD').trim(), to);
  const ls = spawnSync('git', ['ls-files'], { cwd: to, encoding: 'utf8' }).stdout;
  check('AU-15 a force-added file in a copy', ls.split('\n').includes('build/out.txt'), ls);
});

// AU-16: a huge source, or one through a link out of the repo, is not read
await tryCheck('AU-16 the re-find reads as map files are read', () => {
  const q = 'Prices round half up to whole cents.';
  const outside = path.join(tmp, `outside${n}`);
  put(outside, 'rules.md', `${q}\n`);
  const { r } = repoWith({ [MAPF]: [entry('big', q, 'docs/big.md, 2026-11-01'), entry('out', q, 'docs/out/rules.md, 2026-11-01'), entry('fine', q, 'docs/ok.md, 2026-11-01')].join('\n'),
    'docs/big.md': `${q}\n${'pad '.repeat(1_400_000)}\n`, 'docs/ok.md': `${q}\n` });
  fs.symlinkSync(outside, path.join(r, 'docs', 'out'), 'junction');
  const o = ctx(hook('read', r, { tool_name: 'Read', tool_input: { file_path: path.join(r, MAPF) } }));
  check('AU-16 the re-find reads as map files are read', o.includes('cannot read docs/big.md') && o.includes('cannot read docs/out/rules.md') && !o.includes('docs/ok.md'), o);
});

// AU-17: map-review promotes only a tested draft; a repo's unchanged 2.6.0 copy takes the new text
await tryCheck('AU-17 promote only what was tested', () => {
  const { r } = repoWith({ 'README.md': '# r\n', '.claude/skills/map-review/SKILL.md': MR260 });
  const out = S.setup(r, PLUGIN);
  const now = fs.readFileSync(path.join(r, '.claude/skills/map-review/SKILL.md'), 'utf8');
  const pinned = flat(text(MR)).includes('A draft that is untested, stale or not judged is not offered for promotion: each is tested against a run without it before anyone keeps it.');
  check('AU-17 promote only what was tested', /Updated to this version's templates[^\n]*\.claude\/skills\/map-review\/SKILL\.md/.test(out) && now === text(MR) && pinned, out.split('\n').slice(0, 4).join(' | '));
});

// AU-18: a session_ id is private
await tryCheck('AU-18 session ids', () => check('AU-18 session ids', D.PRIVATE.test('see session_01HQ8ZK3XJ5V9N2B7C4D6E8F0G there') && !D.PRIVATE.test('the session_handler and session_timeout_ms keys'), ''));

// AU-19 (attempt 2): a staged draft is not team memory, so its entry is not counted as waiting
await tryCheck('AU-19 a staged draft is not team memory', () => {
  const staged = `### staged\n> Staged words in a draft here.\n\n- id: staged\n- proposed: dream 2026-11-20\n- source: the lead developer, 2026-11-20\n- when: ["work"]\n`;
  const { r } = repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.') }, { '.project-map/drafts/x/SKILL.md': staged });
  check('AU-19 a staged draft is not team memory', M.waiting(r) === '' && !M.mapMd(r).some((f) => f.includes('drafts/')), JSON.stringify({ waiting: M.waiting(r), mapMd: M.mapMd(r) }));
});

// AU-20: an edit to a hook script during a dream is put back and named; a record from before 2.6.1, which watched no
// hook script, removes none
await tryCheck('AU-20 the dream watches .claude/hooks', async () => {
  const { r, g, data } = dreamRepo({ '.claude/hooks/check.sh': 'echo ok\n' });
  const prep = await D.prepare(r, data);
  fs.writeFileSync(path.join(r, '.claude/hooks/check.sh'), 'echo changed\n');
  const fin = D.finish(r, data, runId(prep));
  const back = fs.readFileSync(path.join(r, '.claude/hooks/check.sh'), 'utf8') === 'echo ok\n' && fin.includes('.claude/hooks/check.sh');
  // the older record: no dirs, no hook script in its list
  g('add', '-A');
  g('commit', '-qm', 'reviewed');
  await D.prepare(r, data).catch(() => {});
  const rec = path.join(M.stateDir(r, data), 'run', 'run.json');
  let kept = false;
  if (fs.existsSync(rec)) {
    const job = JSON.parse(fs.readFileSync(rec, 'utf8'));
    delete job.dirs;
    delete job.id;
    job.watched = job.watched.filter((f) => !f.startsWith('.claude/hooks/'));
    fs.writeFileSync(rec, JSON.stringify(job));
    D.abort(r, data);
    kept = fs.existsSync(path.join(r, '.claude/hooks/check.sh'));
  }
  check('AU-20 the dream watches .claude/hooks', back && kept, JSON.stringify({ back, kept, rec: fs.existsSync(rec), fin }));
});

for (const [k, v] of [['CLAUDE_CONFIG_DIR', saved.cfg], ['SECOND_BRAIN_TRIAL_CLAUDE', saved.stub]]) if (v === undefined) delete process.env[k]; else process.env[k] = v;
// the slow stand-in may still hold a copy for a few seconds
if (slowUsed) await new Promise((done) => setTimeout(done, 6500));
try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
console.log(failed ? `${failed} case(s) failed` : 'fix261 ok');
process.exitCode = failed;
