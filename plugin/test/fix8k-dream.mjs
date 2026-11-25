// 06, section 8, 8k, group B (the dream side): one case per item, each in its own temp repo, on synthetic transcripts,
// run against the plugin folder given (default: this one). Every case prints pass or fail; the exit code is the number
// of failures. Run on group A's copy it shows which cases that build fails.
//   node fix8k-dream.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const DREAM = path.join(PLUGIN, 'scripts', 'dream.mjs');
const D = await import(pathToFileURL(DREAM).href);
const { stateDir } = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'map.mjs')).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8k-dream-'));
const posix = process.platform !== 'win32';
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const savedCfg = process.env.CLAUDE_CONFIG_DIR;
// a child runs as from a plain shell: without a Claude Code shell's NoDefaultCurrentDirectoryInExePath, and never with
// the session's own plugin folders, project or config
const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(NoDefaultCurrentDirectoryInExePath|CLAUDE_PLUGIN_DATA|CLAUDE_PLUGIN_ROOT|CLAUDE_PROJECT_DIR|CLAUDE_CONFIG_DIR)$/i.test(k)));
const child = (code, cfg) => spawnSync(process.execPath, ['--input-type=module', '-e', `const D = await import(${JSON.stringify(pathToFileURL(DREAM).href)}); ${code}`], { encoding: 'utf8', env: { ...clean, CLAUDE_CONFIG_DIR: cfg }, timeout: 60_000 });
const entry = (h, q, id, meta = '- when: ["work"]\n') => `### ${h}\n> ${q}\n\n- id: ${id}\n- source: the lead developer, 2026-11-20\n${meta}`;
const idsOf = (t) => (t.match(/^- id: \S+/gm) ?? []).map((l) => l.slice(6));

let n = 0;
function world(files = {}) {
  const r = path.join(tmp, `r${++n}`);
  const cfg = path.join(tmp, `cfg${n}`);
  const data = path.join(cfg, 'plugins', 'data', 'second-brain');
  const g = (...a) => { const x = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' }); if (x.status) throw new Error(x.stderr); return x.stdout; };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  const all = { '.project-map/decisions.md': entry('dates', 'Dates show as DD.MM.YYYY.', 'dates'), '.project-map/dreams.md': '# Dream log\n\n', ...files };
  for (const [f, t] of Object.entries(all)) { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); }
  g('add', '-A');
  g('commit', '-qm', 'base');
  const tdir = path.join(cfg, 'projects', fs.realpathSync.native(r).replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(tdir, { recursive: true });
  const J = (o, cwd = r) => JSON.stringify({ cwd, timestamp: '2026-11-20T10:00:00Z', ...o });
  const rec = {
    U: (text, cwd) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: text } }, cwd),
    call: (id, name, input) => J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } }),
    res: (id, text) => J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] } }),
  };
  const session = (name, lines) => fs.writeFileSync(path.join(tdir, `${name}.jsonl`), `${lines.join('\n')}\n`);
  const run = path.join(r, '.project-map', '.dream-run');
  const digests = () => { try { return fs.readdirSync(path.join(run, 'digests')).sort().map((f) => fs.readFileSync(path.join(run, 'digests', f), 'utf8')).join('\n'); } catch { return ''; } };
  const propose = (p, s) => { fs.mkdirSync(path.dirname(path.join(run, 'proposals', p)), { recursive: true }); fs.writeFileSync(path.join(run, 'proposals', p), s); };
  return { r, cfg, data, g, tdir, rec, session, run, digests, propose, use: () => { process.env.CLAUDE_CONFIG_DIR = cfg; } };
}

// D-1: a proposal cannot become a file Claude Code loads as instructions, and 8c's steering.md stays excluded
await tryCheck('D-1 instruction file names', () => {
  const named = ['CLAUDE.md', 'claude.local.md', 'AGENTS.md', 'Claude.md', 'steering.md', 'README.md', 'dreams.md'].filter((f) => D.topic(f));
  check('D-1 instruction file names', !named.length && D.topic('api.md'), `topic files: ${named.join(', ')}`);
});

// D-1 and 8a's leftover: an entry holds one when line and one review line, each at most 200 characters, or it is dropped
await tryCheck('D-1 one when and one review line, each capped', async () => {
  const w = world();
  const qs = ['Caps rule one holds here', 'Caps rule two holds here', 'Caps rule three holds here', 'Caps rule four holds here', 'Caps rule five holds here'];
  w.session('s1', qs.map((q) => w.rec.U(`${q}.`)));
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('map/caps.md', [
    entry('long when', qs[0], 'caps-1', `- when: ["${'w'.repeat(220)}"]\n`),
    entry('two whens', qs[1], 'caps-2', '- when: ["a"]\n- when: ["b"]\n'),
    entry('long review', qs[2], 'caps-3', `- when: ["c"]\n- review: 2027-01-01 ${'r'.repeat(220)}\n`),
    entry('two reviews', qs[3], 'caps-4', '- when: ["d"]\n- review: 2027-01-01\n- review: 2028-01-01\n'),
    entry('fine', qs[4], 'caps-5', `- when: ["${'e'.repeat(190)}"]\n- review: 2027-01-01\n`),
  ].join('\n'));
  const fin = D.finish(w.r, w.data);
  const m = fs.readFileSync(path.join(w.r, '.project-map', 'caps.md'), 'utf8');
  check('D-1 one when and one review line, each capped', idsOf(m).join() === 'caps-5' && fin.includes('Dropped: 4 more than one when or review line, or one over 200 characters.'), `${idsOf(m).join()} | ${fin}`);
});

// D-2: the new key shapes, and a URL credential with an empty user, are private; ordinary text stays proposable
await tryCheck('D-2 key shapes', () => {
  const keys = ['sk_live_51HxYzAbCdEfGhIjKl', 'rk_test_51HxYzAbCdEfGhIjKl', 'SG.abcdefghijklmnopqrst.abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG', 'hf_abcdefghijklmnopqrstuvwxyz0123456789',
    'https://hooks.slack.com/services/T0/B0/x', 'postgres://admin:hunter2@10.0.0.5/app', 'redis://:hunter2@10.0.0.7:6379/0', 'Authorization: Bearer abcdef0123456789abcdef', 'a quote of [private] text', 'see </Users/alice/x.md>', '-----BEGIN ED25519 PRIVATE KEY-----'];
  const fine = ['Settings live in ~/.claude/settings.json.', 'See https://example.com/docs for the API.', 'The token is short-lived.', 'Use sk-style names only in tests.', 'Ports: http://localhost:8080/app', 'The bearer of bad news is late.'];
  const missed = keys.filter((k) => !D.PRIVATE.test(k)), wrong = fine.filter((k) => D.PRIVATE.test(k));
  check('D-2 key shapes', !missed.length && !wrong.length, `missed ${JSON.stringify(missed)}; wrongly private ${JSON.stringify(wrong)}`);
});

// D-3, as amended: the digests are redacted before the trim. Paths under the repo's root are made relative first (as
// typed, in another letter case on Windows, and escaped as JSON), and only what stays absolute is redacted: a sibling
// folder whose name starts with the root's, a home path, a root cut short by a tool line's 80 characters. Each line
// keeps its tag, even when it starts with a private path
await tryCheck("D-3 digests redacted, the repo's paths made relative first", async () => {
  const w = world();
  const { rec } = w;
  // the tool lines first: the trim keeps the 4 before a typed line
  w.session('s1', [
    rec.call('t1', 'Read', { file_path: path.join(w.r, 'src', 'deep', 'folder', 'name-k4.js') }),
    rec.res('t1', JSON.stringify({ file: path.join(w.r, 'src', 'k2.js') })),
    rec.U('Alerts go to https://hooks.slack.com/services/T024BE7LD/B01ABCDEF/abcdefgh for now.'),
    rec.U('The deploy key is -----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAA end'),
    rec.U('An ed key: -----BEGIN ED25519 PRIVATE KEY----- MC4CAQAwBQYDK2VwBCIEIk8 end'),
    rec.U('/home/alice.smith/clients/acme-merger holds the notes.'),
    rec.U(`Read ${path.join(w.r, 'docs', 'spec-k1.md')} first, then ${w.r} itself.`),
    rec.U(`Old notes in ${w.r}-old${path.sep}notes-k3.md stay.`),
    rec.U(`Out of it: ${w.r}${path.sep}..${path.sep}secret-k8${path.sep}n.md and ${w.r}~backup-k9${path.sep}s.md here.`),
    ...(posix ? [] : [rec.U(`Lower case: ${path.join(w.r, 'docs', 'k6.md').toLowerCase()} counts.`)]),
  ]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  const lines = dg.split('\n').filter(Boolean);
  const leaks = ['T024BE7LD', 'b3BlbnNz', 'MC4CAQAw', 'alice.smith', 'acme-merger', 'notes-k3', 'secret-k8', 'backup-k9', path.basename(tmp)].filter((s) => dg.includes(s));
  const want = [`U: Read ${path.join('docs', 'spec-k1.md')} first, then . itself.`, 'U: [private] holds the notes.', `R: ${JSON.stringify({ file: path.join('src', 'k2.js') })}`,
    ...(posix ? [] : [`U: Lower case: ${path.join('docs', 'k6.md')} counts.`])];
  check("D-3 digests redacted, the repo's paths made relative first", !leaks.length && want.every((l) => lines.includes(l)) && lines.every((l) => /^(U|Q|A|T|R!?|…): /.test(l)) && /^U: Old notes in ?\[private\] stay\.$/m.test(dg),
    JSON.stringify({ leaks, missing: want.filter((l) => !lines.includes(l)), dg: dg.slice(0, 900) }));
});

// D-3: a session that spells the repo through a link (a junction here, macOS /var on CI) has its paths made relative too
await tryCheck('D-3 a root as a session spelled it', async () => {
  const w = world();
  const alias = path.join(tmp, `alias${n}`);
  fs.symlinkSync(w.r, alias, 'junction');
  w.session('s1', [w.rec.U(`Read ${path.join(alias, 'docs', 'spec-k5.md')} first.`, alias)]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  check('D-3 a root as a session spelled it', dg.includes(`U: Read ${path.join('docs', 'spec-k5.md')} first.`), dg);
});

// D-3: on Windows, a Git Bash command spells the root /c/…; it is made relative too
if (!posix) await tryCheck('D-3 the Git Bash spelling of the root', async () => {
  const w = world();
  const bash = (p) => `/${p[0].toLowerCase()}${p.slice(2).replace(/\\/g, '/')}`;
  w.session('s1', [w.rec.U(`Run cd ${bash(w.r)} && cat ${bash(path.join(w.r, 'src', 'k7.js'))} now.`)]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  check('D-3 the Git Bash spelling of the root', dg.includes('U: Run cd . && cat src/k7.js now.'), dg);
});

// D-4: another prepare takes the stale lock between this one's check and its takeover (made deterministic: the first
// stat of the lock reports it stale, then a fresh lock replaces it). This one must refuse and leave that lock in place
await tryCheck('D-4 a lock taken meanwhile', async () => {
  const w = world();
  w.use();
  const lockFile = path.join(stateDir(w.r, w.data), 'dream.lock');
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  fs.writeFileSync(lockFile, 'a stopped dream');
  const old = new Date(Date.now() - 3 * 3600_000);
  fs.utimesSync(lockFile, old, old);
  const stat = fs.statSync;
  let once = false;
  fs.statSync = function (p, ...a) { const st = stat.call(fs, p, ...a); if (!once && String(p).endsWith('dream.lock')) { once = true; fs.rmSync(p); fs.writeFileSync(p, 'another dream'); } return st; };
  let out = 'prepared';
  try { await D.prepare(w.r, w.data); } catch (e) { out = e.message; } finally { fs.statSync = stat; }
  const left = fs.existsSync(lockFile) ? fs.readFileSync(lockFile, 'utf8') : '(none)';
  check('D-4 a lock taken meanwhile', /another dream is running/.test(out) && left === 'another dream', `prepare: ${out}; the lock now: ${left}`);
});

// D-5: finish searches the committed files one by one, never joined, and skips a binary one (a NUL byte)
await tryCheck('D-5 tracked files one by one, binaries skipped', async () => {
  const w = world({ 'docs/blob.bin': Buffer.concat([Buffer.from('Binary rule: never ship on a Friday afternoon.\n'), Buffer.from([0, 1, 2, 3])]),
    'docs/a.md': 'Alpha rule: tests run before each merge.\n', 'docs/b.md': 'Beta rule: reviews close within two days.\n' });
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('map/tracked.md', [entry('binary', 'Binary rule: never ship on a Friday afternoon.', 'from-binary'), entry('stitched', 'Alpha rule: tests run … Beta rule: reviews close', 'stitched'),
    entry('one file', 'Alpha rule: tests run before each merge.', 'one-file')].join('\n'));
  const fin = D.finish(w.r, w.data);
  const p = path.join(w.r, '.project-map', 'tracked.md');
  const ids = fs.existsSync(p) ? idsOf(fs.readFileSync(p, 'utf8')) : [];
  check('D-5 tracked files one by one, binaries skipped', ids.join() === 'one-file', `${ids.join()} | ${fin}`);
});

// D-6: digestFrom reads only up to the end it is given, its fifth argument
await tryCheck('D-6 bounded read', async () => {
  const f = path.join(tmp, 'd6.jsonl');
  const U = (text) => `${JSON.stringify({ type: 'user', promptSource: 'sdk', isMeta: false, cwd: tmp, timestamp: '2026-11-20T10:00:00Z', message: { role: 'user', content: text } })}\n`;
  fs.writeFileSync(f, U('First line typed before the dream.'));
  const size = fs.statSync(f).size;
  fs.appendFileSync(f, U('Second line typed while the dream read.'));
  const dg = await D.digestFrom(f, 0, () => true, new Set(), size);
  check('D-6 bounded read', dg.lines.join('|') === 'U: First line typed before the dream.', JSON.stringify(dg.lines));
});

// D-6 through prepare: a line written while the dream reads is left for the next dream, which reads it
await tryCheck('D-6 the call site', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Typed before the dream, marker B6.')]);
  w.use();
  const open = fs.createReadStream;
  fs.createReadStream = function (p, o) { if (String(p).endsWith('s1.jsonl')) { fs.createReadStream = open; fs.appendFileSync(p, `${w.rec.U('Typed while the dream read, marker W6.')}\n`); } return open.call(fs, p, o); };
  try { await D.prepare(w.r, w.data); } finally { fs.createReadStream = open; }
  const first = w.digests();
  D.finish(w.r, w.data);
  w.g('add', '-A');
  w.g('commit', '-qm', 'the dream kept');
  await D.prepare(w.r, w.data);
  const next = w.digests();
  D.abort(w.r, w.data);
  check('D-6 the call site', first.includes('marker B6') && !first.includes('marker W6') && next.includes('marker W6') && !next.includes('marker B6'), JSON.stringify({ first, next }));
});

// 8a's leftover: a record still being written when prepare looks (it straddles the size prepare records) is read whole by
// the next dream. It is over 64 KB, so the newline before it lies more than one read window back
await tryCheck('a record that straddles the recorded size', async () => {
  const w = world();
  const second = w.rec.U(`Second line, marker P2: ${'long '.repeat(20000)}end.`);
  const file = path.join(w.tdir, 's1.jsonl');
  fs.writeFileSync(file, `${w.rec.U('First line, marker P1.')}\n${second.slice(0, -50)}`);
  w.use();
  await D.prepare(w.r, w.data);
  const first = w.digests();
  D.finish(w.r, w.data);
  w.g('add', '-A');
  w.g('commit', '-qm', 'the dream kept');
  fs.appendFileSync(file, `${second.slice(-50)}\n`);
  await D.prepare(w.r, w.data);
  const next = w.digests();
  D.abort(w.r, w.data);
  check('a record that straddles the recorded size', first.includes('marker P1') && !first.includes('marker P2') && next.includes('marker P2') && !next.includes('marker P1'), JSON.stringify({ first: first.slice(0, 200), next: next.slice(0, 200) }));
});

// finish reads map files as the hooks do (readMapFile, H4): a topic file over 4 MB is neither appended to nor given a
// status line, and the rest of the proposals still land
await tryCheck('finish reads map files through readMapFile', async () => {
  const w = world();
  const big = path.join(w.r, '.project-map', 'big.md');
  fs.writeFileSync(big, `${entry('big', 'Big file rule stays as written.', 'big-id')}\n${`${'x'.repeat(100)}\n`.repeat(42_000)}`);
  w.session('s1', [w.rec.U('Big rule: append nothing to a huge file.'), w.rec.U('Small rule: the control entry is written.')]);
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('map/big.md', entry('into big', 'Big rule: append nothing to a huge file.', 'into-big'));
  w.propose('map/decisions.md', entry('control', 'Small rule: the control entry is written.', 'control'));
  w.propose('status.md', 'big-id | - status: done 2026-11-20 by dates: moved\n');
  const before = fs.readFileSync(big);
  const fin = D.finish(w.r, w.data);
  check('finish reads map files through readMapFile', fs.readFileSync(big).equals(before) && idsOf(fs.readFileSync(path.join(w.r, '.project-map', 'decisions.md'), 'utf8')).includes('control')
    && /Dropped: .*1 a map file that cannot be read/.test(fin), fin);
});
// a FIFO in the map folder never blocks finish (FIFOs need POSIX; CI's macOS job runs this case)
if (posix) await tryCheck('finish never blocks on a FIFO in the map', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Pipe rule: never block on a pipe.')]);
  w.use();
  await D.prepare(w.r, w.data);
  spawnSync('mkfifo', [path.join(w.r, '.project-map', 'pipe.md')]);
  w.propose('map/pipe.md', entry('pipe', 'Pipe rule: never block on a pipe.', 'pipe'));
  const x = child(`console.log(D.finish(${JSON.stringify(w.r)}, ${JSON.stringify(w.data)}));`, w.cfg);
  check('finish never blocks on a FIFO in the map', x.status === 0 && /^Dream finished: /.test(x.stdout) && /Dropped: .*a map file that cannot be read/.test(x.stdout), `${x.error?.code ?? ''} ${x.stdout}${x.stderr}`.slice(0, 400));
});

// H7 (06, 8k): every git call of the dream starts git by full path, so a git.exe in the repo never runs: prepare's
// check-ignore still keeps a touched file, and finish's ls-tree and cat-file still find a tracked source (Windows runs a
// bare name from the working folder first; a child runs without the Claude Code shell's guard against that)
if (!posix) await tryCheck('git by full path: a git.exe in the repo never runs', () => {
  const w = world({ 'docs/a.md': 'Tracked rule: tests run before each merge.\n', 'src/x.js': 'x\n' });
  w.session('s1', [w.rec.U('Start here, marker G1.'), w.rec.call('e1', 'Edit', { file_path: path.join(w.r, 'src', 'x.js') }), w.rec.res('e1', 'ok')]);
  // a copy, not a link: the running node.exe's own file cannot be deleted at the end
  fs.copyFileSync(process.execPath, path.join(w.r, 'git.exe'));
  const [r, data] = [JSON.stringify(w.r), JSON.stringify(w.data)];
  const x = child(`const fs = await import('node:fs'); const path = await import('node:path');
    await D.prepare(${r}, ${data});
    const run = path.join(${r}, '.project-map', '.dream-run');
    const touched = JSON.parse(fs.readFileSync(path.join(run, 'usage.json'), 'utf8')).digests['d1.digest']?.touched;
    fs.mkdirSync(path.join(run, 'proposals', 'map'), { recursive: true });
    fs.writeFileSync(path.join(run, 'proposals', 'map', 'tracked.md'), ${JSON.stringify(entry('tracked', 'Tracked rule: tests run before each merge.', 'tracked'))});
    D.finish(${r}, ${data});
    console.log(JSON.stringify({ touched, written: fs.existsSync(path.join(${r}, '.project-map', 'tracked.md')) }));`, w.cfg);
  const got = (() => { try { return JSON.parse(x.stdout.trim().split('\n').at(-1)); } catch { return {}; } })();
  check('git by full path: a git.exe in the repo never runs', JSON.stringify(got.touched) === '["src/x.js"]' && got.written === true, `${x.stdout}${x.stderr}`.slice(0, 400));
});

// Q-11: the dream run with no .git says so plainly, with no raw error and no absolute path; prepare exits 0 (its ! line
// must not abort the skill), finish and abort 1
await tryCheck('Q-11 dream with no .git', () => {
  const r = path.join(tmp, 'q11');
  fs.mkdirSync(path.join(r, '.project-map'), { recursive: true });
  const cfg = path.join(tmp, 'q11-cfg');
  const data = path.join(cfg, 'plugins', 'data', 'second-brain');
  fs.mkdirSync(data, { recursive: true });
  const bad = ['prepare', 'finish', 'abort'].map((step) => [step, spawnSync(process.execPath, [DREAM, step, data], { cwd: r, encoding: 'utf8', env: { ...clean, CLAUDE_PROJECT_DIR: r, CLAUDE_CONFIG_DIR: cfg } })])
    .filter(([step, x]) => !/^The dream stopped: this folder is not in a git repository/.test(x.stdout) || /ENOENT/.test(x.stdout + x.stderr) || (x.stdout + x.stderr).includes(path.basename(tmp)) || x.status !== (step === 'prepare' ? 0 : 1));
  check('Q-11 dream with no .git', !bad.length, bad.map(([s, x]) => `${s}: ${x.status} ${x.stdout}${x.stderr}`).join(' | ').slice(0, 400));
});

if (savedCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = savedCfg;
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8k-dream ok');
process.exitCode = failed;
