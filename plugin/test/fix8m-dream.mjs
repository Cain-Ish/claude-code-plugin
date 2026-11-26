// 06, section 8, 8m (the dream's older gaps): one case per item, each in its own temp repo, on synthetic transcripts,
// run against the plugin folder given (default: this one). Every case prints pass or fail; the exit code is the number
// of failures. Run on 8k's copy it shows which cases that build fails.
//   node fix8m-dream.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const D = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'dream.mjs')).href);
const { stateDir } = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'map.mjs')).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8m-dream-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const savedCfg = process.env.CLAUDE_CONFIG_DIR;
const entry = (h, q, id, meta = '- when: ["work"]\n') => `### ${h}\n> ${q}\n\n- id: ${id}\n- source: the lead developer, 2026-11-20\n${meta}`;
const idsOf = (t) => (t.match(/^- id: \S+/gm) ?? []).map((l) => l.slice(6));
const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };

let n = 0;
// a repo, its config folder and its transcript folder; `deep` nests the repo under a long folder name
function world(files = {}, deep = '') {
  const r = path.join(tmp, deep, `r${++n}`);
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
  const J = (o) => JSON.stringify({ cwd: r, timestamp: '2026-11-20T10:00:00Z', ...o });
  const rec = {
    U: (text, o = {}) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: text }, ...o }),
    call: (id, name, input) => J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } }),
    res: (id, text, o = {}) => J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] }, ...o }),
    dream: () => J({ type: 'user', message: { role: 'user', content: '<command-message>second-brain:dream</command-message>\n<command-name>/second-brain:dream</command-name>' } }),
    meta: (said) => J({ ...JSON.parse(R.meta(said)), cwd: r }),
    step: (id, step) => [rec.call(id, 'Bash', { command: `node "/plugin/scripts/dream.mjs" ${step} "/plugin/data"` }), rec.res(id, `Dream ${step}ed.`)],
  };
  const session = (name, lines) => fs.writeFileSync(path.join(tdir, `${name}.jsonl`), `${lines.join('\n')}\n`);
  const more = (name, lines) => fs.appendFileSync(path.join(tdir, `${name}.jsonl`), `${lines.join('\n')}\n`);
  const run = path.join(r, '.project-map', '.dream-run');
  const names = () => { try { return fs.readdirSync(path.join(run, 'digests')).sort(); } catch { return []; } };
  const digests = () => names().map((f) => fs.readFileSync(path.join(run, 'digests', f), 'utf8')).join('\n');
  // "<digest>:<line>" of the first line holding the marker
  const at = (marker) => { for (const f of names()) { const k = fs.readFileSync(path.join(run, 'digests', f), 'utf8').split('\n').findIndex((l) => l.includes(marker)); if (k >= 0) return `${f}:${k + 1}`; } throw new Error(`no ${marker} in a digest`); };
  const propose = (p, s) => { fs.mkdirSync(path.dirname(path.join(run, 'proposals', p)), { recursive: true }); fs.writeFileSync(path.join(run, 'proposals', p), s); };
  return { r, cfg, data, g, tdir, rec, session, more, run, names, digests, at, propose, use: () => { process.env.CLAUDE_CONFIG_DIR = cfg; } };
}
// two sessions that each state a release procedure, for drafts that need evidence from two sessions
const twoSessions = (w) => { w.session('s1', [w.rec.U('Release steps: bump the version, marker R1.')]); w.session('s2', [w.rec.U('Release again: bump the version, marker R2.')]); };
const skill = (name, extra = '', ev = 'd1.digest:1, d2.digest:1') => `---\nname: ${name}\ndescription: Releases. Use when releasing.\n${extra}---\nBump the version.\n<!-- evidence: ${ev} -->\n`;

// a transcript's records straight through digestFrom, as prepare reads them
const J = (o) => JSON.stringify({ cwd: tmp, timestamp: '2026-11-20T10:00:00Z', ...o });
const R = {
  U: (text, o = {}) => J({ type: 'user', promptSource: 'sdk', message: { role: 'user', content: text }, ...o }),
  call: (id, name, input) => J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name, ...(input && { input }) }] } }),
  res: (id, text) => J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] } }),
  dream: () => J({ type: 'user', message: { role: 'user', content: '<command-message>second-brain:dream</command-message>\n<command-name>/second-brain:dream</command-name>' } }),
  // the skill's text as Claude Code records it, with prepare's output in it
  meta: (said) => J({ type: 'user', isMeta: true, message: { role: 'user', content: [{ type: 'text', text: `Base directory for this skill: /plugin/skills/dream\n\n${said}\n\nIf the line above says "The dream stopped", do no step below.` }] } }),
};
const digestOf = async (recs, rel) => { const f = path.join(tmp, `t${++n}.jsonl`); fs.writeFileSync(f, `${recs.join('\n')}\n`); return D.digestFrom(f, 0, () => true, new Set(), Infinity, rel); };
const has = (d, ...m) => m.every((x) => d.lines.some((l) => l.includes(`marker ${x}`)));
const lacks = (d, ...m) => m.every((x) => !d.lines.some((l) => l.includes(`marker ${x}`)));

// 1. Q-6: a session that ran the dream is read up to the dream's start and after its finish or abort; the dream's own
// turns (its analyzers' Agent calls too) are not. A Skill call to second-brain:dream starts one as the typed command
// does. A read that begins at the running dream's prepare output (prepare took the session's size before it) starts
// inside the dream
await tryCheck('1 Q-6 a dream session read around the dream', async () => {
  const w = world();
  const { rec } = w;
  w.session('s1', [rec.U('Before the dream, marker A6.'), rec.dream(), rec.call('g1', 'Agent', { subagent_type: 'second-brain:dream-analyzer', prompt: 'x' }), rec.res('g1', 'CANDIDATE'),
    rec.U('Inside the dream, marker I6.'), ...rec.step('f1', 'finish'), rec.U('After the finish, marker Z6.')]);
  w.session('s2', [rec.U('Before the skill call, marker B6.'), rec.call('k1', 'Skill', { skill: 'second-brain:dream' }), rec.res('k1', 'Launching skill'), rec.U('Inside the skill-started dream, marker J6.')]);
  w.session('s3', [rec.U('Before a dream that ends later, marker P6.'), rec.dream()]);
  w.use();
  await D.prepare(w.r, w.data);
  const first = w.digests();
  const usage = JSON.parse(read(path.join(w.run, 'usage.json')) ?? '{}');
  D.finish(w.r, w.data);
  w.g('add', '-A');
  w.g('commit', '-qm', 'the dream kept');
  w.more('s3', [rec.meta('Dream prepared: 1 session digest(s)'), rec.U('Still inside it, marker L6.'), ...rec.step('a1', 'abort'), rec.U('After the abort, marker M6.')]);
  await D.prepare(w.r, w.data);
  const next = w.digests();
  D.abort(w.r, w.data);
  const want = ['A6', 'Z6', 'B6', 'P6'].every((m) => first.includes(`marker ${m}`)) && next.includes('marker M6');
  const none = ['I6', 'J6'].every((m) => !first.includes(`marker ${m}`)) && !['L6', 'P6', 'Z6'].some((m) => next.includes(`marker ${m}`)) && !usage.agent?.['second-brain:dream-analyzer'];
  check('1 Q-6 a dream session read around the dream', want && none, JSON.stringify({ first, next, agents: usage.agent }));
});

// 2. Q-7: a typed prompt with an image keeps its text; one that starts with < is kept unless it is Claude Code's wrapper
await tryCheck('2 Q-7 images and < prompts', () => {
  const T = (content) => D.tag({ type: 'user', promptSource: 'typed', message: { role: 'user', content } });
  const got = [
    T([{ type: 'text', text: 'See the screenshot, marker IM7.' }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } }]).join('|') === 'U: See the screenshot, marker IM7.',
    T('<b>Bold</b> headings are our rule, marker LT7.').join('|') === 'U: <b>Bold</b> headings are our rule, marker LT7.',
    ...['<command-message>x</command-message>\n<command-name>/x</command-name>', '<local-command-stdout>ok</local-command-stdout>', '<system-reminder>x</system-reminder>', '<task-notification>x</task-notification>'].map((t) => T(t).length === 0),
  ];
  check('2 Q-7 images and < prompts', got.every(Boolean), JSON.stringify(got));
});

// 3. Q-14: ordinary project text is not private; secrets, e-mail addresses and home paths are, and so are the temp roots
// D-3 redacts on Linux and macOS
await tryCheck('3 Q-14 PRIVATE takes no route, web path, file name, remote or config folder', () => {
  const fine = ['GET /users/:id returns one user.', 'Open /home/dashboard first.', 'Use avatar@2x.png for retina.', 'Clone git@github.com:org/repo then build.', 'Edit /etc/nginx/ then reload.', 'Binaries go in /opt/app/bin.'];
  const priv = ['see /Users/alice/notes.md', 'in /home/alice/work/x', 'C:\\Users\\alice\\x', 'mail alice@example.com today', 'mail alice@example.com: ok', '/tmp/pm-x/r1/a.md', '/var/folders/ab/T/x', '/private/var/folders/x', 'sk_live_51HxYzAbCdEfGhIjKl', 'file:///Users/bob/x'];
  const wrong = fine.filter((s) => D.PRIVATE.test(s)), missed = priv.filter((s) => !D.PRIVATE.test(s));
  check('3 Q-14 PRIVATE takes no route, web path, file name, remote or config folder', !wrong.length && !missed.length, `wrongly private ${JSON.stringify(wrong)}; missed ${JSON.stringify(missed)}`);
});

// 4. Q-15: when finish or abort puts back an edit made during the dream, a note for the next session start names the
// file and where the edit is kept, in the repo's state folder (session start's reading of it is 8l's)
await tryCheck('4 Q-15 a note for the next session start', async () => {
  const ok = [];
  for (const step of ['finish', 'abort']) {
    const w = world();
    w.session('s1', [w.rec.U('Hello, marker H15.')]);
    w.use();
    await D.prepare(w.r, w.data);
    fs.appendFileSync(path.join(w.r, '.project-map', 'decisions.md'), '\nAn edit by another session, marker E15.\n');
    D[step](w.r, w.data);
    const dir = stateDir(w.r, w.data);
    const note = read(path.join(dir, 'undone.txt')) ?? '';
    const kept = fs.readdirSync(path.join(dir, 'undone')).map((s) => path.join(dir, 'undone', s)).find((d) => read(path.join(d, '.project-map', 'decisions.md'))?.includes('marker E15'));
    ok.push(Boolean(kept) && note.includes('.project-map/decisions.md') && note.includes(kept));
  }
  check('4 Q-15 a note for the next session start', ok.every(Boolean), JSON.stringify(ok));
});

// 5. Q-16: a quote's pieces come from one session's lines; a cut U or Q line says so in the digest, and the cut's own
// words are no source
await tryCheck("5 Q-16 one session's lines, and cuts recorded", async () => {
  const w = world();
  const { rec } = w;
  const q = `Which ${'long '.repeat(80)}question?`;
  w.session('s1', [rec.U('Alpha rule: tests run before each merge.'), rec.U('Gamma rule: reviews close within two days.'), rec.U(`A long prompt ${'word '.repeat(1000)}end.`),
    rec.call('q1', 'AskUserQuestion', { questions: [] }), rec.res('q1', 'answered', { toolUseResult: { answers: { [q]: 'Yes' } } })]);
  w.session('s2', [rec.U('Beta rule: builds stay green on main.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  w.propose('map/q16.md', [entry('stitched', 'Alpha rule: tests run … Beta rule: builds stay', 'stitched'), entry('one session', 'Alpha rule: tests run … Gamma rule: reviews close', 'one-session'),
    entry('the cut', 'cut at 4000 of', 'the-cut')].join('\n'));
  D.finish(w.r, w.data);
  const ids = idsOf(read(path.join(w.r, '.project-map', 'q16.md')) ?? '');
  check("5 Q-16 one session's lines, and cuts recorded", ids.join() === 'one-session' && /^U: A long prompt .* …\[cut at 4000 of \d+ characters\]$/m.test(dg) && /^Q: Which .*…\[cut at 300 of \d+ characters\] = Yes$/m.test(dg),
    JSON.stringify({ ids, dg: dg.split('\n').map((l) => l.slice(-60)) }));
});

// 6. J-1, J-2, J-4: a new skill draft with hooks or allowed-tools is refused; a change that removes disallowedTools is a
// widening; git check-ignore is given only paths it can take (a pathspec-magic name; a path past a link, which Git for
// Windows does not refuse through a junction), so it never exits mid-batch (1 is "none ignored")
await tryCheck('6 J-1 J-2 J-4', async () => {
  const ag = (name, extra = '') => `---\nname: ${name}\ndescription: Reviews.\ntools: Read\n${extra}---\nReview the diff.\n`;
  const w = world({ '.claude/agents/rev.md': ag('rev', 'disallowedTools: Write\n'), '.claude/agents/rev2.md': ag('rev2', 'disallowedTools: Write\n'), 'real/a.js': 'a\n' });
  const { rec } = w;
  fs.symlinkSync(path.join(w.r, 'real'), path.join(w.r, 'lnk'), 'junction');
  const uses = (p) => [rec.call(`${p}a`, 'Agent', { subagent_type: 'rev', prompt: 'x' }), rec.res(`${p}a`, 'ok'), rec.call(`${p}b`, 'Agent', { subagent_type: 'rev2', prompt: 'x' }), rec.res(`${p}b`, 'ok')];
  w.session('s1', [...uses('x'), rec.U('Release steps: bump the version, marker R1.'), rec.call('e1', 'Edit', { file_path: ':(glob)x.js' }), rec.res('e1', 'ok'), rec.call('e2', 'Edit', { file_path: 'src/x.js' }), rec.res('e2', 'ok'), rec.call('e3', 'Edit', { file_path: 'lnk/a.js' }), rec.res('e3', 'ok')]);
  w.session('s2', [...uses('y'), rec.U('Release again: bump the version, marker R2.')]);
  w.use();
  const cp = createRequire(import.meta.url)('node:child_process');
  const spawn = cp.spawnSync;
  const exits = [];
  cp.spawnSync = function (cmd, args, ...o) { const x = spawn.call(this, cmd, args, ...o); if (Array.isArray(args) && args[0] === 'check-ignore') exits.push(x.status); return x; };
  syncBuiltinESMExports();
  try { await D.prepare(w.r, w.data); } finally { cp.spawnSync = spawn; syncBuiltinESMExports(); }
  const touched = JSON.parse(read(path.join(w.run, 'usage.json')) ?? '{}').digests?.['d1.digest']?.touched;
  const ev = `<!-- evidence: ${w.at('marker R1')}, ${w.at('marker R2')} -->\n`;
  w.propose('skills/hooked/SKILL.md', skill('hooked', 'hooks:\n  PreToolUse: []\n', ev.slice(15, -5)));
  w.propose('skills/tooled/SKILL.md', skill('tooled', 'allowed-tools: Bash\n', ev.slice(15, -5)));
  w.propose('skills/plain/SKILL.md', skill('plain', '', ev.slice(15, -5)));
  w.propose('change/agents/rev.md', `${ag('rev')}Read it twice.\n${ev}`);
  w.propose('change/agents/rev2.md', `${ag('rev2', 'disallowedTools: Write\n')}Read it twice.\n${ev}`);
  D.finish(w.r, w.data);
  const sk = (d) => fs.existsSync(path.join(w.r, '.claude', 'skills', d, 'SKILL.md.draft'));
  const got = { hooked: sk('hooked'), tooled: sk('tooled'), plain: sk('plain'), rev: fs.existsSync(path.join(w.r, '.claude', 'agents', 'rev.md.draft')), rev2: fs.existsSync(path.join(w.r, '.claude', 'agents', 'rev2.md.draft')), exits, touched };
  check('6 J-1 J-2 J-4', !got.hooked && !got.tooled && got.plain && !got.rev && got.rev2 && exits.length > 0 && exits.every((x) => x <= 1) && JSON.stringify(touched) === '["src/x.js"]', JSON.stringify(got));
});

// 7. the user's word: finish no longer adds disable-model-invocation to a skill draft
await tryCheck('7 no disable-model-invocation added', async () => {
  const w = world();
  twoSessions(w);
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('skills/release/SKILL.md', skill('release'));
  D.finish(w.r, w.data);
  const t = read(path.join(w.r, '.claude', 'skills', 'release', 'SKILL.md.draft'));
  check('7 no disable-model-invocation added', t !== null && !t.includes('disable-model-invocation') && t.startsWith('---\nname: release\n'), String(t));
});

// 8. Audit 1: a dream committed on another branch, then the first branch checked out, is still kept: its sessions are
// not read again
await tryCheck('8 Audit 1 a dream kept on another branch', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Branch rule: keep it, marker BR8.')]);
  w.use();
  await D.prepare(w.r, w.data);
  D.finish(w.r, w.data);
  w.g('checkout', '-qb', 'feat');
  w.g('add', '-A');
  w.g('commit', '-qm', 'the dream kept on feat');
  w.g('checkout', '-q', '-');
  const said = await D.prepare(w.r, w.data);
  const dg = w.digests();
  D.abort(w.r, w.data);
  // with no branch at all, the dream's line only in the working tree still waits for review (git grep with no revision
  // would search the working tree)
  const v = world();
  v.session('s1', [v.rec.U('No branch yet, marker NB8.')]);
  v.g('update-ref', '-d', 'HEAD');
  v.use();
  await D.prepare(v.r, v.data);
  D.finish(v.r, v.data);
  const again = await D.prepare(v.r, v.data).then(() => 'prepared', (e) => e.message);
  check('8 Audit 1 a dream kept on another branch', !dg.includes('marker BR8') && said.includes('Nothing new to read') && /still waiting for review/.test(again), `${said} | ${again}`);
});

// 9. Audit 3: a new skill draft is dropped when its folder holds a live skill or a draft, or its name is not its
// folder's; no -2 folder is made
await tryCheck('9 Audit 3 skill draft clashes', async () => {
  const w = world({ '.claude/skills/live/SKILL.md': skill('live'), '.claude/skills/waits/SKILL.md.draft': 'an earlier draft\n' });
  twoSessions(w);
  w.use();
  await D.prepare(w.r, w.data);
  for (const d of ['live', 'waits', 'fresh']) w.propose(`skills/${d}/SKILL.md`, skill(d));
  w.propose('skills/named/SKILL.md', skill('other'));
  D.finish(w.r, w.data);
  const sd = path.join(w.r, '.claude', 'skills');
  const got = fs.readdirSync(sd).sort().join();
  check('9 Audit 3 skill draft clashes', got === 'fresh,live,waits' && !fs.existsSync(path.join(sd, 'live', 'SKILL.md.draft')) && read(path.join(sd, 'waits', 'SKILL.md.draft')) === 'an earlier draft\n', got);
});

// 10. Audit 4: evidence may name the digest with its folder, as the candidates' parser takes it
await tryCheck("10 Audit 4 evidence with the digest's folder", async () => {
  const w = world();
  twoSessions(w);
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('skills/release/SKILL.md', skill('release', '', '.project-map/.dream-run/digests/d1.digest:1, .project-map/.dream-run/digests/d2.digest:1'));
  const fin = D.finish(w.r, w.data);
  check("10 Audit 4 evidence with the digest's folder", fs.existsSync(path.join(w.r, '.claude', 'skills', 'release', 'SKILL.md.draft')), fin);
});

// 11. Audit 8: a session listed twice (its folder learned in another spelling) is read once
await tryCheck('11 Audit 8 one session counted once', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Once only, marker O11.')]);
  const dir = stateDir(w.r, w.data);
  fs.mkdirSync(dir, { recursive: true });
  const other = process.platform === 'win32' ? w.tdir.toUpperCase() : `${w.tdir}${path.sep}`;
  fs.writeFileSync(path.join(dir, 'dirs.log'), `${other}\n`);
  w.use();
  await D.prepare(w.r, w.data);
  const got = w.names();
  D.abort(w.r, w.data);
  check('11 Audit 8 one session counted once', got.join() === 'd1.digest', got.join());
});

// 12. a status line's "by <id>" follows finish's rename of a clashing new id
await tryCheck('12 by follows the rename', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Dates now show as YYYY-MM-DD everywhere, marker DT12.')]);
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('map/decisions.md', entry('iso dates', 'Dates now show as YYYY-MM-DD everywhere', 'dates'));
  w.propose('status.md', 'dates | - status: superseded 2026-11-20 by dates: the ISO format holds\n');
  D.finish(w.r, w.data);
  const m = read(path.join(w.r, '.project-map', 'decisions.md')) ?? '';
  check('12 by follows the rename', m.includes('- status: superseded 2026-11-20 by dates-2: the ISO format holds') && idsOf(m).join() === 'dates,dates-2', m);
});

// 13. L-8: a typed line from a session run through claude -p (entrypoint sdk-cli) is marked in the digest
await tryCheck('13 L-8 sdk-cli lines marked', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Headless words, marker H13.', { entrypoint: 'sdk-cli' }), w.rec.U('Typed words, marker T13.', { entrypoint: 'cli' })]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  D.abort(w.r, w.data);
  check('13 L-8 sdk-cli lines marked', dg.includes("U: [sdk-cli: not shown to be the person's] Headless words, marker H13.") && dg.includes('U: Typed words, marker T13.'), dg);
});

// 14. L-9: a correction that names the topic file it corrects counts for that file only
await tryCheck('14 L-9 a correction counts for the topic it names', async () => {
  const w = world({ '.project-map/api.md': entry('api', 'API errors are wrapped.', 'api') });
  const { rec } = w;
  const rd = (id, f) => [rec.call(id, 'Read', { file_path: path.join(w.r, '.project-map', f) }), rec.res(id, 'the map')];
  w.session('s1', [rec.U('Start, marker S14.'), ...rd('m1', 'decisions.md'), ...rd('m2', 'api.md'), rec.U('No: wrap it as a | b, marker C14.'), rec.U('No: wrong again, marker D14.')]);
  w.use();
  await D.prepare(w.r, w.data);
  fs.writeFileSync(path.join(w.run, 'candidates.txt'), [`CANDIDATE | correction | ${w.at('marker C14')} | No: wrap it as a | b | api.md`, `CANDIDATE | correction | ${w.at('marker D14')} | No: wrong again | other.md`].join('\n'));
  const fin = D.finish(w.r, w.data);
  const line = fin.split('\n').find((l) => l.startsWith('Read, then corrected')) ?? '';
  check('14 L-9 a correction counts for the topic it names', line === 'Read, then corrected again in the same session: api.md (1 session).', fin);
});

// 15. a tool line's 80-character cut comes after the repo's paths are made relative, so a long root is not cut short
// and redacted
await tryCheck('15 the tool line cut after paths are made relative', async () => {
  const w = world({}, 'a-long-folder-name-so-the-root-runs-past-eighty-characters-x');
  w.session('s1', [w.rec.call('t1', 'Read', { file_path: path.join(w.r, 'src', 'k15.js') }), w.rec.res('t1', 'ok'), w.rec.U('Read it, marker U15.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  D.abort(w.r, w.data);
  check('15 the tool line cut after paths are made relative', dg.includes(`T: Read ${JSON.stringify({ file_path: path.join('src', 'k15.js') })}`), dg);
});

// ---------- the outside review of 8m (R<n>: its claim n) ----------
// R1-R3. Q-14: a bare home path (a T line cut right after the name too), a user name with + or $, an address on a
// digit domain or before a password, a Git Bash file URL are private; a git remote with a dotted host is not
await tryCheck('R1-R3 Q-14 bare homes, addresses, Git Bash file URLs', async () => {
  const priv = ['HOME=/Users/alice', 'cd /home/alice', 'ls "/Users/alice"', '{"command":"ls \\"/home/alice\\""}', 'see /Users/al+ice/x', 'see /home/a$b/x', 'alice@10x.dev', 'bob@1x.com', 'alice@example.com:password123', 'mail alice@example.com.', 'file:///c/Users/alice/notes.md', 'file:///cygdrive/c/Users/alice/x'];
  const fine = ['git@ssh.github.com:org/repo', 'Clone git@github.com:org/repo then build.', 'Use avatar@2x.png for retina.', 'npm i react@18.3.1', 'GET /users/:id returns one user.', 'Open /home/dashboard first.'];
  const wrong = fine.filter((s) => D.PRIVATE.test(s)), missed = priv.filter((s) => !D.PRIVATE.test(s));
  // the cut: 12 characters of {"command":" and 68 of the command end right after the user name
  const w = world();
  w.session('s1', [w.rec.call('t1', 'Bash', { command: `echo ${'a'.repeat(51)} /home/alice/more` }), w.rec.res('t1', 'ok'), w.rec.U('Ran it, marker H1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const dg = w.digests();
  D.abort(w.r, w.data);
  check('R1-R3 Q-14 bare homes, addresses, Git Bash file URLs', !wrong.length && !missed.length && dg.includes('marker H1') && !dg.includes('/home/alice'), `wrongly private ${JSON.stringify(wrong)}; missed ${JSON.stringify(missed)}; ${dg}`);
});

// R4-R5. Q-16, L-8: a cut's mark counts only where prepare puts it (a U line's end, a Q line's question and answer
// ends), so a typed mark cannot splice words; the sdk-cli mark is no one's words
await tryCheck('R4-R5 Q-16 L-8 marks are no source', async () => {
  const w = world();
  const { rec } = w;
  const q = `Which ${'long '.repeat(80)}question?`;
  w.session('s1', [rec.U('Alpha rule: tests run …[cut at 9 of 99 characters] never on main, marker F4.'), rec.U('Headless words stay here, marker H5.', { entrypoint: 'sdk-cli' }),
    rec.call('q1', 'AskUserQuestion', { questions: [] }), rec.res('q1', 'answered', { toolUseResult: { answers: { [q]: 'Yes', 'Which format do we use here?': 'ok '.repeat(150) } } })]);
  w.use();
  await D.prepare(w.r, w.data);
  w.propose('map/marks.md', [entry('spliced', 'Alpha rule: tests run never on main', 'spliced'), entry('q mark', `long long long cut at 300 of ${q.length} characters = Yes`, 'q-mark'),
    entry('sdk mark', "not shown to be the person's headless words", 'sdk-mark'), entry('sdk words', 'Headless words stay here', 'sdk-words'), entry('q plain', 'Which long long = Yes', 'q-plain'), entry('q answer', `Which format do we use = ${'ok '.repeat(100).trim()}`, 'q-answer')].join('\n'));
  D.finish(w.r, w.data);
  const ids = idsOf(read(path.join(w.r, '.project-map', 'marks.md')) ?? '');
  check('R4-R5 Q-16 L-8 marks are no source', ids.join() === 'sdk-words,q-plain,q-answer', JSON.stringify(ids));
});

// R6-R10. Q-6: an end with no start is read, not a wipe; a dream refused at prepare ends at its refusal; a finish
// run after cd, or from a folder with a space, ends it; a sdk-cli prompt starts it; a read that begins at the running
// dream's prepare output starts inside it
await tryCheck('R6-R10 Q-6 the dream gate', async () => {
  const got = {
    abortOnly: await digestOf([R.U('Earlier words, marker E6.', { timestamp: '2026-11-19T09:00:00Z' }), R.call('a', 'Bash', { command: 'node "/p/scripts/dream.mjs" abort "/d"' }), R.res('a', 'Dream aborted'), R.U('Later, marker L6.')]),
    refused: await digestOf([R.U('Before, marker B7.'), R.dream(), R.meta('The dream stopped: another dream is running in this repo'), R.U('After the refusal, marker A7.')]),
    cdSpace: await digestOf([R.U('Before, marker B8.'), R.dream(), R.meta('Dream prepared: 1 session digest(s)'), R.U('Inside, marker I8.'), R.call('f', 'Bash', { command: 'cd /r && node "/my plugins/scripts/dream.mjs" finish "/d"' }), R.res('f', 'Dream finished'), R.U('After, marker A8.')]),
    sdk: await digestOf([R.U('Before, marker B9.', { entrypoint: 'sdk-cli' }), R.U('/second-brain:dream', { entrypoint: 'sdk-cli' }), R.U('Inside, marker I9.', { entrypoint: 'sdk-cli' })]),
    // the read begins where prepare took the session's size: before the record of its output
    begun: await digestOf([R.meta('Dream prepared: 2 session digest(s)'), R.U('Inside, marker I10.', { timestamp: '2026-11-21T09:00:00Z' }), ...['finish'].flatMap((s) => [R.call('f', 'Bash', { command: `node "/p/scripts/dream.mjs" ${s} "/d"` }), R.res('f', 'Dream finished')]), R.U('After, marker A10.', { timestamp: '2026-11-22T09:00:00Z' })]),
  };
  const ok = { abortOnly: has(got.abortOnly, 'E6', 'L6') && got.abortOnly.first === '2026-11-19T09:00:00Z', refused: has(got.refused, 'B7', 'A7'), cdSpace: has(got.cdSpace, 'B8', 'A8') && lacks(got.cdSpace, 'I8'), sdk: has(got.sdk, 'B9') && lacks(got.sdk, 'I9'),
    begun: has(got.begun, 'A10') && lacks(got.begun, 'I10') && got.begun.first === '2026-11-22T09:00:00Z' && got.begun.last === '2026-11-22T09:00:00Z' };
  check('R6-R10 Q-6 the dream gate', Object.values(ok).every(Boolean), JSON.stringify({ ok, lines: Object.fromEntries(Object.entries(got).map(([k, v]) => [k, v.lines])) }));
});

// R11. a tool call with no input makes a T line, never a throw
await tryCheck('R11 a tool call with no input', async () => {
  const d = await digestOf([R.call('z', 'Foo'), R.U('Typed, marker T11.')], (s) => s.replace(/x/g, 'y'));
  check('R11 a tool call with no input', d.lines.join('|') === 'T: Foo |U: Typed, marker T11.', JSON.stringify(d.lines));
});

// R12. Audit 1: a dream committed on a detached HEAD is kept; with HEAD unborn, a branch holding the line keeps it
await tryCheck('R12 Audit 1 a detached HEAD', async () => {
  const said = [];
  for (const how of ['detached', 'orphan']) {
    const w = world();
    w.session('s1', [w.rec.U(`Kept on ${how}, marker K12.`)]);
    w.use();
    await D.prepare(w.r, w.data);
    D.finish(w.r, w.data);
    if (how === 'detached') { w.g('checkout', '-q', '--detach'); w.g('add', '-A'); w.g('commit', '-qm', 'the dream kept'); } else { w.g('add', '-A'); w.g('commit', '-qm', 'the dream kept'); w.g('checkout', '-q', '--orphan', 'other'); }
    said.push(await D.prepare(w.r, w.data).then((s) => { const t = `${s} ${w.digests().includes('marker K12') ? 'READ AGAIN' : ''}`; D.abort(w.r, w.data); return t; }, (e) => e.message));
  }
  check('R12 Audit 1 a detached HEAD', said.every((s) => s.includes('Nothing new to read') && !s.includes('READ AGAIN')), JSON.stringify(said));
});

// R13. L-9: a topic named with its path counts for that file only
await tryCheck('R13 L-9 a topic named with its path', async () => {
  const w = world({ '.project-map/api.md': entry('api', 'API errors are wrapped.', 'api') });
  const { rec } = w;
  const rd = (id, f) => [rec.call(id, 'Read', { file_path: path.join(w.r, '.project-map', f) }), rec.res(id, 'the map')];
  w.session('s1', [rec.U('Start, marker S13.'), ...rd('m1', 'decisions.md'), ...rd('m2', 'api.md'), rec.U('No: wrap it, marker C13.')]);
  w.use();
  await D.prepare(w.r, w.data);
  fs.writeFileSync(path.join(w.run, 'candidates.txt'), `CANDIDATE | correction | ${w.at('marker C13')} | No: wrap it | .project-map/api.md\n`);
  const line = D.finish(w.r, w.data).split('\n').find((l) => l.startsWith('Read, then corrected')) ?? '';
  check('R13 L-9 a topic named with its path', line === 'Read, then corrected again in the same session: api.md (1 session).', line);
});

// R14. J-4: a file in a submodule never reaches git check-ignore (it exits 128 there)
await tryCheck('R14 J-4 a submodule file', async () => {
  const w = world({ 'src/a.js': 'a\n' });
  const { rec } = w;
  w.g('update-index', '--add', '--cacheinfo', `160000,${w.g('rev-parse', 'HEAD').trim()},sub`);
  fs.mkdirSync(path.join(w.r, 'sub'));
  fs.writeFileSync(path.join(w.r, 'sub', '.git'), 'gitdir: ../.git/modules/sub\n');
  w.session('s1', [rec.U('Edit both, marker S14.'), rec.call('e1', 'Edit', { file_path: 'sub/f.js' }), rec.res('e1', 'ok'), rec.call('e2', 'Edit', { file_path: 'src/a.js' }), rec.res('e2', 'ok')]);
  w.use();
  const cp = createRequire(import.meta.url)('node:child_process');
  const spawn = cp.spawnSync;
  const exits = [];
  cp.spawnSync = function (cmd, args, ...o) { const x = spawn.call(this, cmd, args, ...o); if (Array.isArray(args) && args[0] === 'check-ignore') exits.push(x.status); return x; };
  syncBuiltinESMExports();
  try { await D.prepare(w.r, w.data); } finally { cp.spawnSync = spawn; syncBuiltinESMExports(); }
  const touched = JSON.parse(read(path.join(w.run, 'usage.json')) ?? '{}').digests?.['d1.digest']?.touched;
  D.abort(w.r, w.data);
  check('R14 J-4 a submodule file', exits.length > 0 && exits.every((x) => x <= 1) && JSON.stringify(touched) === '["src/a.js"]', JSON.stringify({ exits, touched }));
});

// R15. J-2, X-4: a live skill whose file starts with a byte-order mark keeps what it may run, and its
// disable-model-invocation, as for any other file
await tryCheck('R15 J-2 a live file with a BOM', async () => {
  const sk = (name, extra = '') => `---\nname: ${name}\ndescription: Releases.\n${extra}---\nBump the version.\n`;
  const live = 'allowed-tools: Bash(git:*)\ndisable-model-invocation: true\n';
  const w = world({ '.claude/skills/rel/SKILL.md': `\uFEFF${sk('rel', live)}`, '.claude/skills/pub/SKILL.md': `\uFEFF${sk('pub', live)}` });
  const { rec } = w;
  const uses = (p) => ['rel', 'pub'].flatMap((k) => [rec.call(`${p}${k}`, 'Skill', { skill: k }), rec.res(`${p}${k}`, 'ok')]);
  w.session('s1', [...uses('x'), rec.U('Release it, marker V1.')]);
  w.session('s2', [...uses('y'), rec.U('Release again, marker V2.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const ev = `Then tag it.\n<!-- evidence: ${w.at('marker V1')}, ${w.at('marker V2')} -->\n`;
  w.propose('change/skills/rel/SKILL.md', `${sk('rel')}${ev}`);
  w.propose('change/skills/pub/SKILL.md', `${sk('pub', 'allowed-tools: Bash(git:*)\n')}${ev}`);
  D.finish(w.r, w.data);
  const pub = read(path.join(w.r, '.claude', 'skills', 'pub', 'SKILL.md.draft')) ?? '';
  check('R15 J-2 a live file with a BOM', !fs.existsSync(path.join(w.r, '.claude', 'skills', 'rel', 'SKILL.md.draft')) && pub.includes('disable-model-invocation: true'), pub);
});

// R16. Audit 3: a file where a draft's folder would go drops the draft; finish ends and releases the lock
await tryCheck('R16 Audit 3 a file in the folder\'s place', async () => {
  const got = [];
  for (const [kind, f, p, t] of [['skill', '.claude/skills/fresh', 'skills/fresh/SKILL.md', skill('fresh')], ['agent', '.claude/agents', 'agents/helper.md', `---\nname: helper\ndescription: Helps.\ntools: Read\n---\nHelp.\n<!-- evidence: d1.digest:1, d2.digest:1 -->\n`],
    ['rule', '.claude/rules', 'rules/style.md', '---\npaths: ["**/*.js"]\n---\nUse tabs.\n<!-- evidence: d1.digest:1, d2.digest:1 -->\n']]) {
    const w = world({ [f]: 'a file\n' });
    twoSessions(w);
    w.use();
    await D.prepare(w.r, w.data);
    w.propose(p, t);
    const fin = (() => { try { return D.finish(w.r, w.data); } catch (e) { return `THREW ${e.message}`; } })();
    got.push({ kind, ok: fin.startsWith('Dream finished') && !fs.existsSync(path.join(stateDir(w.r, w.data), 'dream.lock')) && read(path.join(w.r, f)) === 'a file\n', fin: fin.split('\n')[0] });
  }
  check('R16 Audit 3 a file in the folder\'s place', got.every((g) => g.ok), JSON.stringify(got));
});

if (savedCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = savedCfg;
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8m-dream ok');
process.exitCode = failed;
