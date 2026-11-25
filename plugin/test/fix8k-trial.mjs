// 06, section 8, 8k, group C (the trial side): one case per item, each in its own temp repo, run against the plugin
// folder given (default: this one), with the stand-in for claude (trial-stub8e.mjs). Every case prints pass or fail;
// the exit code is the number of failures. Run on group A's copy it shows which cases that build fails. No case can
// start a real session: this file's PATH holds no claude.
//   node fix8k-trial.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const HERE = path.dirname(fileURLToPath(import.meta.url));
const TRIAL = path.join(PLUGIN, 'scripts', 'trial.mjs');
const STUB = path.join(HERE, 'trial-stub8e.mjs');
const NODE = process.execPath;
const posix = process.platform !== 'win32';
const noClaude = (process.env.PATH ?? '').split(path.delimiter).filter((d) => d && !['claude', 'claude.exe', 'claude.cmd', 'claude.com'].some((f) => fs.existsSync(path.join(d, f)))).join(path.delimiter);
process.env.PATH = noClaude;
const T = await import(pathToFileURL(TRIAL).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8k-trial-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
// a plain shell's environment (a Claude Code shell sets NoDefaultCurrentDirectoryInExePath); a variable given replaces
// the inherited one in any letter case, and one given as undefined is left out
const envWith = (extra = {}) => ({ ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^NoDefaultCurrentDirectoryInExePath$/i.test(k) && !Object.keys(extra).some((x) => x.toLowerCase() === k.toLowerCase()))),
  ...Object.fromEntries(Object.entries(extra).filter(([, v]) => v !== undefined)) });
const withEnv = async (env, f) => {
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  const set = (e) => { for (const [k, v] of Object.entries(e)) if (v === undefined) delete process.env[k]; else process.env[k] = v; };
  set(env);
  try { return await f(); } finally { set(saved); }
};

const CHECK = "import fs from 'node:fs';\nprocess.exit(fs.existsSync('out.txt') && fs.readFileSync('out.txt', 'utf8').trim() === 'pass' ? 0 : 1);\n";
const SKILL = '---\nname: pricing\ndescription: Prices the cart. Use when asked to price it.\n---\nPrice it.\n';
const D = '.claude/skills/pricing/SKILL.md.draft';
const LIVE = '.claude/skills/pricing/SKILL.md';
const spec = () => ({ artifact: D, runs: 3, cases: [
  { id: 'price-a', prompt: 'Price the cart.', tools: ['Read', 'Skill'], check: '.project-map/evals/checks/ok.mjs' },
  { id: 'price-b', prompt: 'Price the order.', tools: ['Read', 'Skill'], check: '.project-map/evals/checks/ok.mjs' },
  { id: 'other', prompt: 'An unrelated task.', tools: ['Read', 'Skill'], use: false, check: '.project-map/evals/checks/ok.mjs' },
] });
let n = 0;
// a repo with a committed case file and check, and the skill draft uncommitted
function repo() {
  const r = path.join(tmp, `r${++n}`);
  const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' });
  const put = (f, t) => { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  g('config', 'core.autocrlf', 'false');
  put('README.md', '# r\n');
  put('.project-map/evals/checks/ok.mjs', CHECK);
  put('.project-map/evals/pricing.json', JSON.stringify(spec(), null, 1));
  g('add', '-A');
  g('commit', '-qm', 'base');
  put(D, SKILL);
  return { r, g, put };
}
const cli = (r, words, env = envWith()) => spawnSync(NODE, [TRIAL, 'cli'], { cwd: r, encoding: 'utf8', input: words, env }).stdout;
const hashOf = (out) => /run pricing ([0-9a-f]{12})/.exec(out ?? '')?.[1];
const verdictOf = (r) => { try { return JSON.parse(fs.readFileSync(path.join(r, '.project-map', '.trial', 'pricing.json'), 'utf8')); } catch { return {}; } };
// the stand-in's variables, in a file that sets them and loads it, since a session's environment is an allowlist (X-3)
const stand = (vars) => {
  const f = path.join(tmp, `stand${++n}.mjs`);
  fs.writeFileSync(f, `Object.assign(process.env, ${JSON.stringify(vars)});\nawait import(${JSON.stringify(pathToFileURL(STUB).href)});\n`);
  return { ...vars, SECOND_BRAIN_TRIAL_CLAUDE: f };
};
const stubVars = (log, more = {}) => stand({ STUB_LOG: path.join(tmp, log), STUB_LIVE: LIVE, ...more });
const logOf = (log) => (fs.existsSync(path.join(tmp, log)) ? fs.readFileSync(path.join(tmp, log), 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : []);

// H7: git starts by its full path. A git in the repo (on Windows a copy of node, which fails on git's arguments; on
// POSIX a script), which a bare name runs from the working folder on Windows and from a relative PATH entry on POSIX,
// never runs: show prints its line, and a run reaches its verdict with git's blob ids
await tryCheck('H7 a git in the repo never runs', () => {
  const { r } = repo();
  if (posix) fs.writeFileSync(path.join(r, 'git'), '#!/bin/sh\necho fake git\n', { mode: 0o755 });
  else fs.copyFileSync(NODE, path.join(r, 'git.exe'));
  const env = envWith({ PATH: `.${path.delimiter}${noClaude}` });
  const out = cli(r, 'show pricing', env);
  const hash = hashOf(out);
  spawnSync(NODE, [TRIAL, 'exec', 'pricing', hash ?? '0'], { cwd: r, env: { ...env, ...stubVars('h7git.log') }, encoding: 'utf8' });
  const v = verdictOf(r);
  check('H7 a git in the repo never runs', Boolean(hash) && v.verdict === 'helps' && /^[0-9a-f]{40}$/.test(v.artifactBlob ?? '') && /^[0-9a-f]{40}$/.test(v.casesBlob ?? ''), JSON.stringify({ out: out.slice(0, 160), v }));
});

// H7: claude starts by its full path, never from the copy. A repo that commits a program named claude (on Windows a
// copy of where.exe, which only prints; on POSIX a script) gets no session from it: with no claude on PATH, the
// verdict says claude could not be started
await tryCheck('H7 a claude in the copy never runs', () => {
  const { r, g } = repo();
  const fake = posix ? 'claude' : 'claude.exe';
  if (posix) fs.writeFileSync(path.join(r, fake), '#!/bin/sh\nexit 3\n', { mode: 0o755 });
  else fs.copyFileSync(path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'where.exe'), path.join(r, fake));
  g('add', fake);
  g('commit', '-qm', 'a program named claude');
  const env = envWith({ PATH: `.${path.delimiter}${noClaude}`, SECOND_BRAIN_TRIAL_CLAUDE: undefined });
  const hash = hashOf(cli(r, 'show pricing', env));
  spawnSync(NODE, [TRIAL, 'exec', 'pricing', hash ?? '0'], { cwd: r, env, encoding: 'utf8' });
  const v = verdictOf(r);
  check('H7 a claude in the copy never runs', Boolean(hash) && v.verdict === 'not judged' && v.failed === 18 && /^claude could not be started/.test(v.why ?? '') && /claude\.cmd/.test(v.why ?? ''), JSON.stringify(v));
});

// the audit's item 7: committed() reads, never writes: show leaves .git/index byte for byte as it was, though the case
// file was written again with the same bytes and a later time (git diff refreshed the index under index.lock)
await tryCheck('Audit 7 show leaves the index alone', () => {
  const { r } = repo();
  const f = path.join(r, '.project-map', 'evals', 'pricing.json');
  fs.writeFileSync(f, fs.readFileSync(f));
  const later = new Date(Date.now() + 60_000);
  fs.utimesSync(f, later, later);
  const idx = path.join(r, '.git', 'index');
  const before = fs.readFileSync(idx);
  const out = cli(r, 'show pricing');
  check('Audit 7 show leaves the index alone', Boolean(hashOf(out)) && fs.readFileSync(idx).equals(before), `index ${fs.readFileSync(idx).equals(before) ? 'unchanged' : 'rewritten'}; ${out.slice(0, 160)}`);
});

// the audit, small: a committed path with a tab is never cut at it. POSIX holds the file by its own name; Windows cannot
// hold a tab in a name, so that copy stops (a run is not judged) rather than hold the file as "a"
await tryCheck('Audit: a path with a tab', () => {
  const { r, g } = repo();
  const blobId = spawnSync('git', ['hash-object', '-w', '--stdin'], { cwd: r, input: 'x\n', encoding: 'utf8' }).stdout.trim();
  const tree = spawnSync('git', ['mktree', '-z'], { cwd: r, input: [`100644 blob ${blobId}\ta\tb.txt`, `100644 blob ${blobId}\tok.txt`, ''].join('\0'), encoding: 'utf8' }).stdout.trim();
  const commit = g('commit-tree', tree, '-m', 'tab').stdout.trim();
  const to = path.join(tmp, `copy${++n}`);
  let err = '';
  try { T.copyHead(r, commit, to); } catch (x) { err = x.message; }
  const ok = !fs.existsSync(path.join(to, 'a')) && (posix ? !err && fs.readFileSync(path.join(to, 'a\tb.txt'), 'utf8') === 'x\n' : Boolean(err));
  check('Audit: a path with a tab', ok, JSON.stringify({ err: err.slice(0, 80), files: fs.existsSync(to) ? fs.readdirSync(to) : null }));
});

// B-4: show names a binary file beside a skill and says it is binary, rather than print its bytes; a text file beside
// it is still printed
await tryCheck('B-4 a binary file beside a skill', () => {
  const { r, put } = repo();
  put('.claude/skills/pricing/logo.png', Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]));
  put('.claude/skills/pricing/price.mjs', 'console.log(1);\n');
  const out = cli(r, 'show pricing');
  check('B-4 a binary file beside a skill', Boolean(hashOf(out)) && out.includes('The file .claude/skills/pricing/logo.png is binary (12 bytes), so it is not shown.') && !out.includes('\0') && out.includes('  | console.log(1);'), out.slice(-400));
});

// B-5 and B-2: the system's refusal to remove a copy's folder, simulated on the folder itself (Windows refuses one a
// program still runs in). One refusal: the retry removes it. Two: the copy is named, and holds no file
const refusing = async (times, f) => {
  const real = fs.rmSync;
  let k = 0;
  fs.rmSync = function (p, o) { if (/^second-brain-trial-/.test(path.basename(String(p))) && k++ < times) { const e = new Error('EBUSY: resource busy or locked'); e.code = 'EBUSY'; throw e; } return real.call(fs, p, o); };
  try { return await f(); } finally { fs.rmSync = real; }
};
const leftOf = (v) => (v?.copiesLeft ?? []).map((f) => path.join(os.tmpdir(), f));
await tryCheck('B-5 one retry', async () => {
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const v = await withEnv(stubVars('b5.log'), () => refusing(1, () => T.exec(r, 'pricing', hash)));
  for (const d of leftOf(v)) fs.rmSync(d, { recursive: true, force: true });
  check('B-5 one retry', v?.verdict === 'helps' && !v.copiesLeft, JSON.stringify(v));
});
await tryCheck('B-2 the files go first', async () => {
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const v = await withEnv(stubVars('b2.log'), () => refusing(2, () => T.exec(r, 'pricing', hash)));
  const left = leftOf(v);
  const files = left.map((d) => (fs.existsSync(d) ? fs.readdirSync(d).length : -1));
  for (const d of left) fs.rmSync(d, { recursive: true, force: true });
  check('B-2 the files go first', v?.verdict === 'helps' && left.length === 1 && files[0] === 0, JSON.stringify({ v, files }));
});
// B-2 for real on Windows: a program the session started still runs in the copy, so the folder stays; its files do not
// (before 8k, Node 24 and Node 20 both kept them all here)
await tryCheck('B-2 a held copy keeps no file', async () => {
  if (posix) { console.log(`pass  B-2 a held copy keeps no file (skipped on ${process.platform}: the system deletes a folder that is a working folder)`); return; }
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const held = path.join(tmp, `holder${++n}.pid`);
  const v = await withEnv(stubVars('b2held.log', { STUB_HOLD: held }), () => T.exec(r, 'pricing', hash));
  const left = leftOf(v);
  const files = left.map((d) => (fs.existsSync(d) ? fs.readdirSync(d).length : -1));
  const pid = Number(fs.existsSync(held) ? fs.readFileSync(held, 'utf8') : 0);
  if (pid) try { process.kill(pid); } catch {}
  for (const d of left) for (let k = 0; k < 100; k++) { try { fs.rmSync(d, { recursive: true, force: true }); break; } catch { await sleep(100); } }
  check('B-2 a held copy keeps no file', v?.verdict === 'helps' && left.length === 1 && files[0] === 0, JSON.stringify({ v, files }));
});

// L-14 (a), seen live: run takes the lock itself and hands it to its exec, so a second run line typed at once is
// refused. Here run's child only idles, so the base's exec never takes the lock at all
await tryCheck('L-14 run takes the lock itself', async () => {
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const pids = path.join(tmp, `idle${++n}.pids`);
  const idle = path.join(tmp, `idle${n}.mjs`);
  fs.writeFileSync(idle, `import fs from 'node:fs';\nfs.appendFileSync(${JSON.stringify(pids)}, \`\${process.pid}\\n\`);\nsetTimeout(() => {}, 30000);\n`);
  const attempt = (f) => { try { return f(); } catch (e) { return e.message; } };
  const first = attempt(() => T.start(r, 'pricing', hash, idle));
  const second = attempt(() => T.start(r, 'pricing', hash, idle));
  for (let k = 0; k < 50 && !fs.existsSync(pids); k++) await sleep(100);
  await sleep(500);
  const children = fs.existsSync(pids) ? fs.readFileSync(pids, 'utf8').trim().split('\n').map(Number) : [];
  let lock = '';
  try { lock = fs.readFileSync(path.join(r, '.project-map', '.trial', '.lock'), 'utf8'); } catch {}
  for (const p of children) try { process.kill(p); } catch {}
  check('L-14 run takes the lock itself', /started/.test(first) && /another trial is running/.test(second) && children.length === 1 && lock === String(children[0]), JSON.stringify({ first, second, children, lock }));
});

// L-14: exec takes the lock run hands it, named by run's process id (the token) until run writes exec's own; with no
// token, a held lock is still refused (8i-5)
await tryCheck('L-14 exec takes the lock its token names', () => {
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const lock = path.join(r, '.project-map', '.trial', '.lock');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.writeFileSync(lock, String(process.pid));
  const res = spawnSync(NODE, [TRIAL, 'exec', 'pricing', hash, String(process.pid)], { cwd: r, env: envWith(stubVars('token.log')), encoding: 'utf8' });
  const v = verdictOf(r);
  check('L-14 exec takes the lock its token names', v.verdict === 'helps' && !fs.existsSync(lock), JSON.stringify({ out: res.stdout, v }));
});

// L-14 (b), seen live: an exec refused because another trial runs records nothing, so the verdict file is not
// overwritten with "not judged, stopped" while the real trial runs
await tryCheck('L-14 a refused run keeps the verdict', () => {
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const dir = path.join(r, '.project-map', '.trial');
  fs.mkdirSync(dir, { recursive: true });
  const prior = '{\n "verdict": "helps"\n}\n';
  fs.writeFileSync(path.join(dir, 'pricing.json'), prior);
  fs.writeFileSync(path.join(dir, '.lock'), String(process.pid));
  const res = spawnSync(NODE, [TRIAL, 'exec', 'pricing', hash], { cwd: r, env: envWith({ SECOND_BRAIN_TRIAL_CLAUDE: undefined }), encoding: 'utf8' });
  const now = fs.readFileSync(path.join(dir, 'pricing.json'), 'utf8');
  check('L-14 a refused run keeps the verdict', /another trial is running/.test(res.stdout) && now === prior, JSON.stringify({ out: res.stdout, now }));
});

// X-3, reproduced on a loopback stand-in for the API (06, 8k): a file tool's bare name in --allowedTools let a session
// write, edit, read and search outside its copy. Those names are made available, not approved; any other stays
await tryCheck('X-3 file tools not approved', () => {
  // --allowedTools, when there, comes last
  const tools = (a) => JSON.stringify(a.slice(a.indexOf('--tools') + 1, a.includes('--allowedTools') ? a.indexOf('--allowedTools') : undefined));
  const allowed = (a) => (a.includes('--allowedTools') ? JSON.stringify(a.slice(a.indexOf('--allowedTools') + 1)) : null);
  const a = T.childArgs('Price it.', ['Read', 'Write', 'Edit', 'Glob', 'Grep', 'Skill', 'Bash(node x.mjs:*)']);
  const b = T.childArgs('Price it.', ['Read', 'Write(*)', 'Edit(/x/**)', 'NotebookEdit', 'Glob', 'Grep']);
  const ok = tools(a) === '["Read","Write","Edit","Glob","Grep","Skill","Bash"]' && allowed(a) === '["Skill","Bash(node x.mjs:*)"]' && tools(b) === '["Read","Write","Edit","NotebookEdit","Glob","Grep"]' && allowed(b) === null;
  check('X-3 file tools not approved', ok, JSON.stringify({ a: a.slice(a.indexOf('--tools')), b: b.slice(b.indexOf('--tools')) }));
});

// X-3: a session's environment is an allowlist plus Claude Code's own variables, so a user's tokens never reach it;
// AWS's pass only for a Bedrock login. Through a run too: the stand-in sees no token
await tryCheck('X-3 no user token reaches a session', async () => {
  const tokens = { GITHUB_TOKEN: 'x', AWS_SECRET_ACCESS_KEY: 'x', NPM_TOKEN: 'x', OPENAI_API_KEY: 'x' };
  const login = { ANTHROPIC_API_KEY: 'x', CLAUDE_CODE_OAUTH_TOKEN: 'x', CLAUDE_CONFIG_DIR: 'x', HTTPS_PROXY: 'x', DISABLE_TELEMETRY: 'x' };
  const has = (e, k) => Object.keys(e).some((x) => x.toUpperCase() === k);
  const plain = await withEnv({ ...tokens, ...login, CLAUDE_CODE_USE_BEDROCK: undefined }, () => T.childEnv());
  const bedrock = await withEnv({ ...tokens, ...login, CLAUDE_CODE_USE_BEDROCK: '1' }, () => T.childEnv());
  const off = await withEnv({ ...tokens, ...login, CLAUDE_CODE_USE_BEDROCK: '0' }, () => T.childEnv());
  const { r } = repo();
  const hash = hashOf(cli(r, 'show pricing'));
  const v = await withEnv({ GITHUB_TOKEN: 'x', ...stubVars('x3env.log') }, () => T.exec(r, 'pricing', hash));
  const seen = logOf('x3env.log');
  const facts = { tokens: !Object.keys(tokens).some((k) => has(plain, k)), login: Object.keys(login).every((k) => has(plain, k)), path: has(plain, 'PATH'),
    bedrock: has(bedrock, 'AWS_SECRET_ACCESS_KEY') && !has(bedrock, 'GITHUB_TOKEN'), off: !has(off, 'AWS_SECRET_ACCESS_KEY'), run: v?.verdict === 'helps' && seen.length === 18 && seen.every((s) => s.env.GITHUB_TOKEN === null) };
  check('X-3 no user token reaches a session', Object.values(facts).every(Boolean), JSON.stringify(facts));
});

// D-2, the trial's share: the private-data filter's wider shapes (8a's) refuse a case file, a verdict and a draft.
// The filter is dream.mjs's PRIVATE (group B), so this case passes once that lands
await tryCheck('D-2 the wider filter in the trial', () => {
  const { r, put } = repo();
  const shapes = ['sk_live_51HxYzAbCdEfGhIjKl', 'https://hooks.slack.com/services/T0/B0/x', 'postgres://admin:hunter2@10.0.0.5/app', 'Authorization: Bearer abcdef0123456789abcdef'];
  const valid = shapes.map((s) => { const x = spec(); x.cases[0].prompt = `Use ${s} here.`; return T.validate(r, x).some((e) => /private data/.test(e)); });
  const recorded = shapes.map((s, i) => { try { T.record(r, `leak${i}`, { note: s }); return false; } catch { return !fs.existsSync(path.join(r, '.project-map', '.trial', `leak${i}.json`)); } });
  const drafted = shapes.map((s, i) => { put(`.project-map/drafts/leak${i}/SKILL.md`, `---\nname: leak${i}\ndescription: Leaks.\n---\nUse ${s}.\n`); try { T.draft(r, `leak${i}`, 'skill'); return false; } catch (e) { return /private data/.test(e.message); } });
  check('D-2 the wider filter in the trial', [...valid, ...recorded, ...drafted].every(Boolean), JSON.stringify({ valid, recorded, drafted }));
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8k-trial ok');
process.exitCode = failed;
