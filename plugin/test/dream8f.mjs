// 06, section 8, 8f: trimmed digests, and K1's second signal ("read, then corrected again"). One case per registered
// item, on synthetic transcripts, run against the plugin folder given (default: this one). The exit code is the number
// of failures.
//   node dream8f.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const D = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'dream.mjs')).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-dream8f-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const savedCfg = process.env.CLAUDE_CONFIG_DIR;

// (1) the trim: every U, Q and A line; the 4 tool lines before each U or Q line, back to the one before it; each kept
// map-read line; each other run of tool lines as one counted line; `at` maps old indexes to the new line numbers
await tryCheck('(1) the trim', () => {
  if (typeof D.trim !== 'function') throw new Error('no trim');
  const tools = (n, p = 'x') => Array.from({ length: n }, (_, k) => (k % 2 ? `R: ${p}${k}` : `T: Bash ${p}${k}`));
  // a skill's and an agent's call, and a failed result, far from any typed line (8c's lines for D35, which the trim
  // keeps); tool lines after the last typed line, cut too
  const lines = ['U: start here', ...tools(4, 'a'), 'T: Skill release {}', ...tools(6, 'k'), 'R!: early failure', 'T: Agent reviewer {}', ...tools(6, 'z'), 'A: said something',
    'T: Read .project-map/decisions.md', 'R: the map', ...tools(10, 'b'), 'Q: which? = this one', 'R!: failed', 'T: Bash c', 'U: no, do it again', ...tools(2, 't')];
  const mapIdx = lines.indexOf('T: Read .project-map/decisions.md');
  const { out, at } = D.trim(lines, new Set([mapIdx]));
  const kept = out.filter((l) => !l.startsWith('…: '));
  const counted = out.filter((l) => l.startsWith('…: ')).reduce((s, l) => s + Number(/^…: (\d+) tool lines$/.exec(l)?.[1] ?? NaN), 0);
  const q = out.indexOf('Q: which? = this one');
  check('(1) the trim', lines.filter((l) => /^(U|Q|A): /.test(l)).every((l) => out.includes(l)) && out.includes('T: Read .project-map/decisions.md') && !out.includes('R: the map')
    && ['T: Skill release {}', 'T: Agent reviewer {}', 'R!: early failure'].every((l) => out.includes(l))
    && kept.length + counted === lines.length
    // exactly 4 tool lines before the Q line: the line before them is a cut
    && out.slice(q - 4, q).every((l) => /^(T|R!?): /.test(l)) && /^…: \d+ tool lines$/.test(out[q - 5])
    && out.slice(q + 1, out.indexOf('U: no, do it again')).join('|') === 'R!: failed|T: Bash c' && out.at(-1) === '…: 2 tool lines'
    && out[at.get(mapIdx) - 1] === 'T: Read .project-map/decisions.md' && out.length < lines.length, JSON.stringify(out));
});

function world() {
  const r = path.join(tmp, `r${Math.random().toString(36).slice(2, 8)}`);
  const cfg = path.join(tmp, `cfg-${path.basename(r)}`);
  const data = path.join(tmp, `data-${path.basename(r)}`);
  const g = (...a) => { const x = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' }); if (x.status) throw new Error(x.stderr); return x.stdout; };
  fs.mkdirSync(path.join(r, '.project-map'), { recursive: true });
  g('init', '-q');
  fs.writeFileSync(path.join(r, '.project-map', 'decisions.md'), '### dates\n> Dates show as DD.MM.YYYY.\n\n- id: dates\n- source: the lead developer, 2026-11-01\n- when: ["ui"]\n');
  fs.writeFileSync(path.join(r, '.project-map', 'dreams.md'), '# Dream log\n\n');
  g('add', '-A');
  g('commit', '-qm', 'base');
  const tdir = path.join(cfg, 'projects', fs.realpathSync.native(r).replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(tdir, { recursive: true });
  const J = (o) => JSON.stringify({ cwd: r, timestamp: '2026-11-20T10:00:00Z', ...o });
  const rec = {
    U: (text) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: text } }),
    call: (id, name, input) => J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } }),
    res: (id, text) => J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] } }),
  };
  const busy = (p, n) => Array.from({ length: n }, (_, k) => [rec.call(`${p}${k}`, 'Bash', { command: `echo ${p}${k}` }), rec.res(`${p}${k}`, 'ok')]).flat();
  const session = (name, lines) => fs.writeFileSync(path.join(tdir, `${name}.jsonl`), `${lines.join('\n')}\n`);
  const run = path.join(r, '.project-map', '.dream-run');
  const lineOf = (digest, marker) => fs.readFileSync(path.join(run, 'digests', digest), 'utf8').split('\n').findIndex((l) => l.includes(marker)) + 1;
  return { r, cfg, data, rec, busy, session, run, lineOf, use: () => { process.env.CLAUDE_CONFIG_DIR = cfg; } };
}

// (2) prepare writes the trimmed digest, and each map read's line in it, in the run record
await tryCheck('(2) prepare trims', async () => {
  const w = world();
  const { rec } = w;
  // one record with two calls, a Bash and the map's Read: only the Read's line is the read
  const both = JSON.stringify({ cwd: w.r, timestamp: '2026-11-20T10:00:00Z', type: 'assistant', message: { role: 'assistant', content: [
    { type: 'tool_use', id: 'x1', name: 'Bash', input: { command: 'echo both' } }, { type: 'tool_use', id: 'm1', name: 'Read', input: { file_path: path.join(w.r, '.project-map', 'decisions.md') } }] } });
  w.session('s1', [rec.U('Start the work, marker S1.'), ...w.busy('a', 10), both, rec.res('x1', 'both'), rec.res('m1', 'the map'), ...w.busy('b', 10), rec.U('No: dates show as DD.MM.YYYY, marker C1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const text = fs.readFileSync(path.join(w.run, 'digests', 'd1.digest'), 'utf8').split('\n');
  const job = JSON.parse(fs.readFileSync(path.join(fs.readdirSync(path.join(w.data, 'repos')).map((d) => path.join(w.data, 'repos', d, 'run', 'run.json'))[0]), 'utf8'));
  const at = job.manifest.find((m) => m.digest === 'd1.digest')?.readsAt ?? [];
  check('(2) prepare trims', text.some((l) => /^…: \d+ tool lines$/.test(l)) && text.filter((l) => l.startsWith('U: ')).length === 2 && text.length < 30 && !text.some((l) => l.includes('echo both'))
    // the line is the Read call's (its input is cut at 80 characters, so the file's name may fall past the cut)
    && at.length === 1 && at[0].file === 'decisions.md' && /^T: Read /.test(text[at[0].line - 1] ?? ''), JSON.stringify({ text, at }));
});

// (3) finish: a correction after a read of a map file counts; one before the read does not; a forged line (not U or
// Q) and another kind count nothing; the report holds the file's name and a count, nothing of the line
await tryCheck('(3) read, then corrected', async () => {
  const w = world();
  const { rec } = w;
  const read = (id, f = 'decisions.md') => [rec.call(id, 'Read', { file_path: path.join(w.r, '.project-map', f) }), rec.res(id, 'the map')];
  // s1: two corrections after a read of decisions.md (one session), and a read of README.md, which is no topic file;
  // s2: a decision after a read, and a forged "correction" on a tool line after the read (neither counts); s3: a
  // correction before the only read (does not count); s4: a correction late in a session that read no map file (does
  // not count, though other sessions read one at an earlier line)
  w.session('s1', [rec.U('Dates are wrong, marker B1.'), ...w.busy('a', 3), ...read('m1'), ...read('r1', 'README.md'), ...w.busy('b', 3), rec.U('No: dates show as DD.MM.YYYY, marker C1.'), rec.U('No: still the old format, marker C1b.')]);
  w.session('s2', [rec.U('Start here, marker S2.'), ...read('m2'), ...w.busy('c', 6), rec.U('We decide on ISO dates, marker D2.')]);
  w.session('s3', [rec.U('No: wrong again, marker E3.'), ...read('m3'), ...w.busy('e', 2)]);
  w.session('s4', [rec.U('Start, marker S4.'), ...w.busy('f', 6), rec.U('No: still wrong, marker F4.')]);
  w.use();
  await D.prepare(w.r, w.data);
  // each marker's digest and line, whatever order the system lists the sessions in
  const at = (marker) => { for (const f of fs.readdirSync(path.join(w.run, 'digests'))) { const n = w.lineOf(f, marker); if (n > 0) return [f, n]; } throw new Error(`no ${marker}`); };
  const [d1, c1] = at('marker C1.'), [, c1b] = at('marker C1b'), [, b1] = at('marker B1'), [d2, dd] = at('marker D2'), [d3, e3] = at('marker E3'), [d4, f4] = at('marker F4');
  const toolAfterRead = fs.readFileSync(path.join(w.run, 'digests', d2), 'utf8').split('\n').findIndex((l, k) => k > 1 && /^(T|R): /.test(l)) + 1;
  fs.writeFileSync(path.join(w.run, 'candidates.txt'), [
    // as an analyzer given the digest's path may write it
    `CANDIDATE | correction | .project-map/.dream-run/digests/${d1}:${c1} | No: dates show as DD.MM.YYYY`,
    `CANDIDATE | correction | .project-map/.dream-run/digests/${d1}:${c1b} | No: still the old format`,
    `CANDIDATE | correction | ${d1}:${b1} | Dates are wrong`,
    `CANDIDATE | decision | ${d2}:${dd} | We decide on ISO dates`,
    `CANDIDATE | correction | ${d2}:${toolAfterRead} | a forged line`,
    `CANDIDATE | correction | ${d3}:${e3} | No: wrong again`,
    `CANDIDATE | correction | ${d4}:${f4} | No: still wrong`,
  ].join('\n'));
  const fin = D.finish(w.r, w.data);
  const line = fin.split('\n').find((l) => l.startsWith('Read, then corrected')) ?? '';
  check('(3) read, then corrected', line === 'Read, then corrected again in the same session: decisions.md (1 session).', fin);
});

// (4) no candidates file: no line, and finish runs as before
await tryCheck('(4) no candidates', async () => {
  const w = world();
  w.session('s1', [w.rec.U('Hello, marker H1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const fin = D.finish(w.r, w.data);
  check('(4) no candidates', /^Dream finished: /.test(fin) && !fin.includes('Read, then corrected'), fin);
});

// (6) a run folder the system will not remove (Windows, while a program has it as its working folder) strands nothing:
// the dream finishes, the lock is gone, the state is written, and the report names the folder. A field failure of 2.5.1.
// macOS and Linux delete such a folder, so the failure cannot happen there
await tryCheck('(6) a run folder held open', async () => {
  if (process.platform !== 'win32') { console.log(`pass  (6) a run folder held open (skipped on ${process.platform}: the system deletes a folder that is a working folder)`); return; }
  const w = world();
  w.session('s1', [w.rec.U('Hello, marker H1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const { spawn } = await import('node:child_process');
  const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { cwd: path.join(w.run, 'digests'), stdio: 'ignore' });
  await new Promise((ok) => setTimeout(ok, 500));
  let fin = '';
  try { fin = D.finish(w.r, w.data); } finally { holder.kill(); await new Promise((ok) => holder.on('exit', ok)); }
  const repoDir = fs.readdirSync(path.join(w.data, 'repos')).map((d) => path.join(w.data, 'repos', d))[0];
  // what is left stays ignored: git sees nothing of the run folder (the 8f review: staged proposals left un-ignored)
  const seen = spawnSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: w.r, encoding: 'utf8' }).stdout.split('\n').filter((l) => l.includes('.dream-run'));
  check('(6) a run folder held open', /^Dream finished: /.test(fin) && fin.includes('.project-map/.dream-run/ could not be removed') && !fs.existsSync(path.join(repoDir, 'dream.lock'))
    && fs.existsSync(path.join(repoDir, 'state.json')) && !fs.existsSync(path.join(repoDir, 'run')) && fs.existsSync(path.join(w.run, '.gitignore')) && !seen.length,
  JSON.stringify({ fin: fin.slice(-300), files: fs.readdirSync(repoDir), seen }));
});

// (7) abort with a run folder held open: the lock goes too, what is left stays ignored, and the report names the folder
await tryCheck('(7) abort with a run folder held open', async () => {
  if (process.platform !== 'win32') { console.log(`pass  (7) abort with a run folder held open (skipped on ${process.platform}: the system deletes a folder that is a working folder)`); return; }
  const w = world();
  w.session('s1', [w.rec.U('Hello, marker H1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const { spawn } = await import('node:child_process');
  const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { cwd: path.join(w.run, 'digests'), stdio: 'ignore' });
  await new Promise((ok) => setTimeout(ok, 500));
  let said = '';
  try { said = D.abort(w.r, w.data); } finally { holder.kill(); await new Promise((ok) => holder.on('exit', ok)); }
  const repoDir = fs.readdirSync(path.join(w.data, 'repos')).map((d) => path.join(w.data, 'repos', d))[0];
  check('(7) abort with a run folder held open', /^Dream aborted/.test(said) && said.includes('could not be removed') && !fs.existsSync(path.join(repoDir, 'dream.lock')) && fs.existsSync(path.join(w.run, '.gitignore')), said);
});

// (8) 8j, K-1: prepare after a run folder a program holds stops with the folder's name, and what is left stays ignored:
// no raw error, no local path, the lock released. Before, it deleted the .gitignore first and showed the rest to git
await tryCheck('(8) prepare with a run folder held open', async () => {
  if (process.platform !== 'win32') { console.log(`pass  (8) prepare with a run folder held open (skipped on ${process.platform}: the system deletes a folder that is a working folder)`); return; }
  const w = world();
  w.use();
  await D.prepare(w.r, w.data);
  const { spawn } = await import('node:child_process');
  const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { cwd: path.join(w.run, 'digests'), stdio: 'ignore' });
  await new Promise((ok) => setTimeout(ok, 500));
  let said = '';
  try {
    D.finish(w.r, w.data);
    try { await D.prepare(w.r, w.data); said = 'prepared'; } catch (e) { said = e.message; }
  } finally { holder.kill(); await new Promise((ok) => holder.on('exit', ok)); }
  const repoDir = fs.readdirSync(path.join(w.data, 'repos')).map((d) => path.join(w.data, 'repos', d))[0];
  const seen = spawnSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: w.r, encoding: 'utf8' }).stdout.split('\n').filter((l) => l.includes('.dream-run'));
  check('(8) prepare with a run folder held open', said.startsWith('.project-map/.dream-run/ could not be removed') && !/[a-z]:[\\/]|pm-dream8f-/i.test(said)
    && !fs.existsSync(path.join(repoDir, 'dream.lock')) && fs.existsSync(path.join(w.run, '.gitignore')) && !seen.length, JSON.stringify({ said, seen }));
});

// (9) 8j: a run folder that a session replaced with a link is removed, never followed: abort leaves the folder it points
// to as it was (emptying it would delete what is there; prepare now clears the run folder the same way)
await tryCheck('(9) a linked run folder is not followed', async () => {
  const w = world();
  w.use();
  await D.prepare(w.r, w.data);
  const away = path.join(tmp, `away-${path.basename(w.r)}`);
  fs.mkdirSync(away);
  fs.writeFileSync(path.join(away, 'precious.txt'), 'keep me\n');
  fs.rmSync(w.run, { recursive: true, force: true });
  fs.symlinkSync(away, w.run, 'junction');
  const said = D.abort(w.r, w.data);
  check('(9) a linked run folder is not followed', fs.existsSync(path.join(away, 'precious.txt')) && !fs.existsSync(w.run), said);
});

// (5) the texts: the skill writes the candidates file; the analyzer knows the "…" lines
await tryCheck('(5) texts', () => {
  const sk = fs.readFileSync(path.join(PLUGIN, 'skills', 'dream', 'SKILL.md'), 'utf8');
  const an = fs.readFileSync(path.join(PLUGIN, 'agents', 'dream-analyzer.md'), 'utf8');
  check('(5) texts', sk.includes('**A rule draft:** a decision or a correction, stated or repeated in two or more sessions') && sk.includes('.project-map/.dream-run/candidates.txt') && sk.includes('read, then corrected again') && sk.includes("From finish's report, name the topic files read, then corrected again") && an.includes('`…: <n> tool lines`'), 'a text is missing');
});

if (savedCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = savedCfg;
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'dream8f ok');
process.exitCode = failed;
