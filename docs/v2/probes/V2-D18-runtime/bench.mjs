// V2-D18 bench, attempt 2: the hook scripts as separate processes against P2's full map, timed wall-clock with the
// spawn, at 1 and 8 concurrent (Windows), each next to an empty Node process timed just before it at the same
// concurrency; plus the label, boundary, nested-converter and missing-runtime checks. The bench repo is a worktree of
// the scratch clone at the pinned commit, with the map rendered as committed Markdown; it stays outside this repo.
// Only counts come back here (results/).
//   node bench.mjs build  <config> <bench-dir>       (also asserts every piece lib.mjs copied equals its original)
//   node bench.mjs load   <config> <bench-dir> [calls=200]
//   node bench.mjs checks <config> <bench-dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as lib from './lib.mjs';
import { render as render15, parseMap as parse15 } from '../V2-D15-onboarding/onboard.mjs';
import { foundIn as found16, normOf as norm16 } from '../V2-D16-freshness/fresh.mjs';
import { keyedFor as keyed22 } from '../V2-D22-selection/keys.mjs';
import { HASH } from '../V2-D14-capture/instruction.mjs';
import { convert } from '../V2-D13-selection/convert.mjs';

const { MAP } = lib;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, cfgArg, benchArg, callsArg] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
const RAW = path.dirname(path.resolve(cfgArg));
const BENCH = path.resolve(benchArg);
const task = cfg.tasks.find((t) => t.id.startsWith('P2-'));
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=bench', '-c', 'user.email=bench@example.invalid', ...a], { cwd, encoding: 'utf8' });
const write = (name, obj) => { fs.mkdirSync(path.join(HERE, 'results'), { recursive: true }); fs.writeFileSync(path.join(HERE, 'results', name), `${JSON.stringify(obj, null, 1)}\n`); };
const q = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const mapFiles = () => git(BENCH, 'ls-files', MAP).stdout.split('\n').filter((f) => f.endsWith('.md'));
const sourceOf = (mapRel) => mapRel.slice(MAP.length + 1, -3);
// error text may name local paths; only its shape comes back
const scrub = (s) => String(s).replace(/[A-Za-z]:[\\/][^\s"']*/g, '<path>').replace(/\/(?:tmp|Users|home|c)\/[^\s"']*/g, '<path>').slice(0, 160);

const loadEntries = () => {
  const all = JSON.parse(fs.readFileSync(path.join(RAW, 'd13', 'maps', 'P2.json'), 'utf8')).all;
  const dir = path.join(RAW, 'd15', 'full', 'P2');
  return fs.readdirSync(dir).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')))
    .flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file, heads: all[x.blocks[0]].heads })));
};

if (mode === 'build') {
  git(task.repo, 'worktree', 'remove', '--force', BENCH);
  fs.rmSync(BENCH, { recursive: true, force: true });
  git(task.repo, 'worktree', 'prune');
  const r = git(task.repo, 'worktree', 'add', '-q', '--detach', BENCH, task.commit);
  if (r.status !== 0) throw new Error(r.stderr);
  const date = git(BENCH, 'log', '-1', '--format=%cs').stdout.trim();
  const text = new Map();
  const doc = (f) => { if (!text.has(f)) { const p = path.join(BENCH, f); const t = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null; text.set(f, t && { t, n: lib.normOf(t) }); } return text.get(f); };
  // D16: verified is the re-find on the file at the capture commit
  const entries = loadEntries().sort((a, b) => a.blocks[0] - b.blocks[0]).map((e) => { const d = doc(e.file); return { ...e, verified: !!d && lib.foundIn(e, d.t, d.n), date }; });
  // the copies equal their originals
  assert.equal(crypto.createHash('sha256').update(lib.INSTRUCTION).digest('hex').slice(0, 12), HASH);
  // both of lib's paths: the regex (no word list) and attempt 3's word list
  for (const e of entries) {
    const d = doc(e.file);
    if (d) { const want = found16(e, d.t, d.n); assert.equal(d.n, norm16(d.t)); assert.equal(lib.foundIn(e, d.t, d.n), want); assert.equal(lib.foundIn(e, d.t, d.n, () => ('w' in d ? d.w : (d.w = lib.wordsAt(d.t)))), want); }
  }
  const byFile = Map.groupBy(entries, (e) => e.file);
  const strip = (es) => es.map(({ file, heads, area, quote, context, when, blocks }) => ({ file, heads, area, quote, context, when, blocks }));
  for (const [file, es] of byFile) {
    assert.deepEqual(strip(lib.parseMap(file, lib.render(file, es))), strip(parse15(file, render15(file, es))));
    const f = path.join(BENCH, MAP, `${file}.md`);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, lib.render(file, es));
  }
  git(BENCH, 'add', MAP);
  git(BENCH, 'commit', '-q', '-m', 'map');
  const t0 = performance.now();
  lib.buildCache(BENCH);
  const ms = Math.round(performance.now() - t0);
  const keyed = JSON.parse(fs.readFileSync(path.join(BENCH, MAP, '.cache', fs.readFileSync(path.join(BENCH, MAP, '.cache', 'current'), 'utf8'), 'keys.json'), 'utf8'));
  const probeFiles = [...git(BENCH, 'ls-files').stdout.split('\n').filter((f) => f && !f.startsWith(MAP)).slice(0, 200), ...byFile.keys()];
  for (const f of probeFiles) assert.deepEqual(lib.keyedFor(keyed, f), keyed22(keyed, f));
  const unverified = entries.filter((e) => !e.verified).length;
  console.log(`bench at ${byFile.size} map files, ${entries.length} entries (${unverified} unverified); cache built in ${ms} ms; copies equal on ${entries.length} entries, ${byFile.size} files, ${probeFiles.length} key lookups`);
  write('build.json', { date: new Date().toISOString().slice(0, 10), mapFiles: byFile.size, entries: entries.length, unverified, cacheBuildMs: ms, copiesEqual: { instructionHash: HASH, entries: entries.length, mapFiles: byFile.size, keyLookups: probeFiles.length } });
} else if (mode === 'load') {
  const calls = Number(callsArg ?? 200);
  const files = git(BENCH, 'ls-files').stdout.split('\n').filter((f) => f && !f.startsWith(MAP));
  const hash = (s) => crypto.createHash('sha1').update(s).digest('hex');
  const pickFiles = files.sort((a, b) => hash(a).localeCompare(hash(b))).slice(0, 40);
  // attempt 3: reads of documents too (40 map sources in hash order); Claude reads them often and their entries cost most
  const pickDocs = mapFiles().map(sourceOf).sort((a, b) => hash(a).localeCompare(hash(b))).slice(0, 40);
  const big = mapFiles().map(sourceOf).find((s) => lib.shard(BENCH, s).length >= 30);
  const input = (which, k) => (which === 'session-start' ? { hook_event_name: 'SessionStart', source: 'startup', cwd: BENCH }
    : which === 'deliver30' ? { hook_event_name: 'UserPromptSubmit', cwd: BENCH, source: big }
      : { hook_event_name: 'PostToolUse', tool_name: which === 'on-write' ? 'Write' : 'Read', cwd: BENCH,
        tool_input: { file_path: path.join(BENCH, which === 'on-read-doc' ? pickDocs[k % pickDocs.length] : pickFiles[k % pickFiles.length]) } });
  const gitBash = ['C:/Program Files/Git/bin/bash.exe'].find((p) => fs.existsSync(p)) ?? 'bash';
  // exec form, as the hooks are registered: the executable and its arguments, no shell. The floor reports its
  // in-process time the same way the hooks do (V2_BENCH).
  const FLOOR = "process.on('exit',()=>process.stderr.write('elapsed='+performance.now()+'\\n'))";
  const argv = (which) => (which === 'floor' ? ['node', ['-e', FLOOR]] : which === 'shell-floor' ? [gitBash, ['-c', "node -e ''"]] : ['node', [path.join(HERE, 'hooks.mjs'), which.replace('-doc', '')]]);
  const one = (which, k) => new Promise((resolve) => {
    const t0 = performance.now();
    const [cmd, args] = argv(which);
    const p = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, CLAUDE_PROJECT_DIR: BENCH, V2_BENCH: '1' } });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', (e) => resolve({ ms: performance.now() - t0, code: -1, bytes: 0, err: String(e) }));
    p.on('close', (code) => resolve({ ms: performance.now() - t0, code, bytes: out.length, err, inproc: Number(/elapsed=([\d.]+)/.exec(err)?.[1] ?? NaN) }));
    p.stdin.on('error', () => {});
    p.stdin.end(JSON.stringify(which.includes('floor') ? {} : input(which, k)));
  });
  const stats = (rs) => {
    const ms = rs.map((r) => r.ms);
    const ip = rs.map((r) => r.inproc).filter((x) => !Number.isNaN(x));
    const errs = rs.filter((r) => r.code);
    return { p50: Math.round(q(ms, 0.5)), p95: Math.round(q(ms, 0.95)), max: Math.round(Math.max(...ms)), inprocP95: ip.length ? Math.round(q(ip, 0.95)) : null,
      errors: errs.length, errorText: [...new Set(errs.map((r) => scrub(r.err.split('\n').find((l) => /Error/.test(l)) ?? r.err)))].slice(0, 3), emptyOutputs: rs.filter((r) => !r.bytes).length };
  };
  // paired blocks: `conc` floor calls at once, then `conc` hook calls at once, until `calls` of each; the floor is
  // contemporaneous with the hook and the hooks still run `conc` at a time against each other
  const paired = async (which, conc) => {
    const fl = [];
    const hk = [];
    for (let k = 0; k < calls; k += conc) {
      fl.push(...await Promise.all(Array.from({ length: conc }, () => one('floor', 0))));
      hk.push(...await Promise.all(Array.from({ length: conc }, (_, j) => one(which, k + j))));
    }
    const f = stats(fl);
    const h = stats(hk);
    return { ...h, floorP95: f.p95, floorInprocP95: f.inprocP95, floorErrors: f.errors, addedP95: h.p95 - f.p95, addedInprocP95: h.inprocP95 - f.inprocP95 };
  };
  const res = {};
  for (const which of ['session-start', 'on-read', 'on-read-doc', 'on-write', 'deliver30']) {
    res[which] = {};
    for (const conc of [1, 8]) res[which][conc] = await paired(which, conc);
    console.log(which, JSON.stringify(res[which]));
  }
  const shellBatch = async (conc) => { const rs = []; for (let k = 0; k < calls; k += conc) rs.push(...await Promise.all(Array.from({ length: conc }, () => one('shell-floor', 0)))); return stats(rs); };
  const shell = { 1: await shellBatch(1), 8: await shellBatch(8) };
  console.log('shell-form floor', JSON.stringify(shell));
  // reported, no bar: a map file touched, then 8 on-read hooks at once, all finding the cache stale together
  fs.utimesSync(path.join(BENCH, mapFiles()[0]), new Date(), new Date());
  const stale = stats(await Promise.all(Array.from({ length: 8 }, (_, j) => one('on-read', j))));
  console.log('stale cache under 8 concurrent', JSON.stringify(stale));
  const pass = Object.values(res).every((r) => r[8].addedP95 <= 100 && r[8].addedInprocP95 <= 100 && r[8].errors === 0 && r[1].errors === 0);
  write('load-a3.json', { attempt: 3, date: new Date().toISOString().slice(0, 10), os: `${os.platform()} ${os.release()}`, node: process.version, calls, entries: 14119,
    bar: 'at 8 concurrent, both p95(hook) - p95(empty node) by wall clock and by in-process time at most 100 ms; no errors at 1 or 8',
    pass, scripts: res, shellFormFloor: shell, staleUnder8: stale });
  console.log('pass', pass);
} else if (mode === 'nonode') {
  // the user's answer: session start in shell form says once that Node is missing; the other hooks stay in exec form
  const MSG = 'The project map needs Node 20 or later; install it, or disable the plugin.';
  const script = path.join(HERE, 'hooks.mjs').replace(/\\/g, '/');
  const hooks = {
    SessionStart: [{ hooks: [{ type: 'command', shell: 'bash', command: `command -v node >/dev/null 2>&1 && exec node "${script}" session-start || echo '{"systemMessage":"${MSG}"}'` }] }],
    PostToolUse: [{ matcher: 'Read', hooks: [{ type: 'command', command: 'node', args: [script, 'on-read'] }] }],
  };
  const session = (withNode) => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'd18-nonode-'));
    spawnSync('git', ['init', '-q', tmp]);
    fs.writeFileSync(path.join(tmp, 'NOTES.md'), '# Notes\n\nThe build uses a single config file.\n');
    fs.mkdirSync(path.join(tmp, '.claude'));
    fs.writeFileSync(path.join(tmp, '.claude', 'settings.local.json'), JSON.stringify({ hooks }));
    const env = { ...process.env, DISABLE_AUTOUPDATER: '1', MSYS_NO_PATHCONV: '1' };
    for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
    const pathKey = Object.keys(env).find((k) => k.toUpperCase() === 'PATH');
    if (!withNode) env[pathKey] = env[pathKey].split(path.delimiter).filter((d) => !fs.existsSync(path.join(d, process.platform === 'win32' ? 'node.exe' : 'node'))).join(path.delimiter);
    const r = spawnSync('claude', ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'Bash,WebFetch,WebSearch',
      '--output-format', 'stream-json', '--verbose', '--include-hook-events'], { cwd: tmp, input: 'Read NOTES.md and tell me in one line what it says.', encoding: 'utf8', env, timeout: 300_000 });
    const evs = (r.stdout ?? '').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
    const result = evs.findLast((e) => e.type === 'result');
    const hookEv = evs.filter((e) => /hook/i.test(`${e.type ?? ''} ${e.subtype ?? ''}`));
    const ofEvent = (name) => hookEv.filter((e) => JSON.stringify(e).includes(name));
    const summary = (name) => ({ events: ofEvent(name).length, errors: ofEvent(name).filter((e) => (e.outcome ?? e.subtype) === 'error' || /"outcome":"error"/.test(JSON.stringify(e))).length,
      shown: [...new Set(ofEvent(name).map((e) => scrub(e.stderr ?? e.error ?? '')).filter(Boolean))].slice(0, 2) });
    // shown = hook outputs carrying the message (started events carry no output); other events that echo it are counted apart
    return { completed: result?.subtype === 'success', costUsd: result?.total_cost_usd, messageShown: hookEv.filter((e) => JSON.stringify(e).includes('needs Node 20')).length,
      messageEchoes: evs.filter((e) => !hookEv.includes(e) && JSON.stringify(e).includes('needs Node 20')).length,
      sessionStart: summary('SessionStart'), afterRead: summary('PostToolUse'), outcomes: [...new Set(hookEv.map((e) => `${e.subtype ?? e.type}:${e.outcome ?? ''}`))] };
  };
  const res = { noNode: session(false), withNode: session(true) };
  res.pass = res.noNode.completed && res.noNode.messageShown === 1 && res.noNode.sessionStart.errors === 0
    && res.withNode.completed && res.withNode.messageShown === 0 && res.withNode.sessionStart.errors === 0 && res.withNode.afterRead.errors === 0;
  write('nonode-a3.json', { date: new Date().toISOString().slice(0, 10), ...res });
  console.log(JSON.stringify(res, null, 1));
} else if (mode === 'checks') {
  const res = {};
  const files = mapFiles();
  const [mapFile, other] = files;
  const source = sourceOf(mapFile);
  const all = () => files.flatMap((f) => lib.shard(BENCH, sourceOf(f)));
  const labelled = (out, l) => out.filter((o) => o.labels.some((x) => x.startsWith(l))).length;
  lib.refresh(BENCH);
  // 2. labels. The unchanged tree: no entry stale, exactly the unverified ones labelled so, none unreviewed.
  const base = lib.deliver(BENCH, all(), Infinity);
  const unverified = all().filter((e) => !e.verified).length;
  res.labels = { unchangedTree: { delivered: base.length, stale: labelled(base, 'source changed'), unverified: labelled(base, 'unverified quote'), expectedUnverified: unverified, unreviewed: labelled(base, 'unreviewed') } };
  // one entry appended to a committed map file, picked up by a non-session hook's refresh (mtime rule)
  const before = lib.shard(BENCH, source).length;
  fs.appendFileSync(path.join(BENCH, mapFile), '\n### probe\n> An uncommitted entry added for the label check.\n\n- source: probe, 2026-10-22\n- when: []\n');
  // a new map file, untracked
  const fresh = path.join(BENCH, MAP, 'probe-new.md');
  fs.writeFileSync(fresh, '# Map entries\n\n### probe\n> A second uncommitted entry, in a new map file.\n\n- source: probe, 2026-10-22\n- when: []\n');
  lib.refresh(BENCH);
  const a = lib.deliver(BENCH, lib.shard(BENCH, source), Infinity);
  const b = lib.deliver(BENCH, lib.shard(BENCH, sourceOf(other)), Infinity);
  const c = lib.deliver(BENCH, lib.shard(BENCH, 'probe-new'), Infinity);
  const isNew = (o) => o.block.includes('An uncommitted entry added');
  res.labels.sameFile = { entries: a.length, newSeen: a.length === before + 1, newLabelled: a.filter(isNew).every((o) => o.labels.includes('unreviewed, not yet committed')) && a.some(isNew),
    committedUnlabelled: a.filter((o) => !isNew(o)).every((o) => !o.labels.includes('unreviewed, not yet committed')), newNotStale: a.filter(isNew).every((o) => !o.labels.some((l) => l.startsWith('source changed'))) };
  res.labels.otherFileUnlabelled = b.every((o) => !o.labels.includes('unreviewed, not yet committed'));
  res.labels.newFileLabelled = c.length === 1 && c[0].labels.includes('unreviewed, not yet committed');
  // attempt 3: git's own files are the trigger. A commit is clean at the next hook; a soft reset that un-commits the
  // entries labels them again at the next hook (the dangerous direction); the hard reset leaves the tree as it was.
  const probeLabelled = () => lib.deliver(BENCH, lib.shard(BENCH, 'probe-new'), Infinity)[0]?.labels.includes('unreviewed, not yet committed');
  git(BENCH, 'add', MAP);
  git(BENCH, 'commit', '-q', '-m', 'probe entries');
  lib.refresh(BENCH);
  res.labels.afterCommitCleanAtNextHook = probeLabelled() === false;
  git(BENCH, 'reset', '-q', '--soft', 'HEAD~1');
  lib.refresh(BENCH);
  res.labels.afterSoftResetLabelledAtNextHook = probeLabelled() === true;
  git(BENCH, 'reset', '-q', '--hard', 'HEAD');
  lib.refresh(BENCH);
  res.labels.restored = lib.shard(BENCH, 'probe-new').length === 0 && lib.shard(BENCH, source).length === before;
  // every delivery path goes through deliver(): one emit per path, the session start's instruction excepted
  const hooksSrc = fs.readFileSync(path.join(HERE, 'hooks.mjs'), 'utf8');
  res.labels.allPathsGuarded = (hooksSrc.match(/emit\(/g) ?? []).length - 1 === (hooksSrc.match(/deliver\(/g) ?? []).length;
  const u = res.labels.unchangedTree;
  res.labels.pass = u.stale === 0 && u.unverified === u.expectedUnverified && u.unreviewed === 0 && res.labels.sameFile.newSeen && res.labels.sameFile.newLabelled
    && res.labels.sameFile.committedUnlabelled && res.labels.sameFile.newNotStale && res.labels.otherFileUnlabelled && res.labels.newFileLabelled
    && res.labels.afterCommitCleanAtNextHook && res.labels.afterSoftResetLabelledAtNextHook && res.labels.restored && res.labels.allPathsGuarded;
  // 3. boundary: child_process gives only spawnSync, which runs only git; no eval or Function; the argument lists recorded
  const src = ['lib.mjs', 'hooks.mjs'].map((f) => fs.readFileSync(path.join(HERE, f), 'utf8')).join('\n');
  const cp = [...src.matchAll(/import\s*\{([^}]*)\}\s*from\s*'node:child_process'/g)].flatMap((m) => m[1].split(',').map((s) => s.trim()));
  const calls = [...src.matchAll(/spawnSync\(\s*'([^']+)',\s*(\[[^\]]*\])/g)].map((m) => ({ cmd: m[1], args: m[2] }));
  res.boundary = { childProcess: cp, spawns: calls, noEval: !/\beval\(|new Function\(/.test(src), noOtherProcessApi: !/\b(?:execSync|execFile|execFileSync|fork)\(|(?<![.\w])exec\(/.test(src) };
  res.boundary.pass = cp.length === 1 && cp[0] === 'spawnSync' && calls.length > 0 && calls.every((s) => s.cmd === 'git') && res.boundary.noEval && res.boundary.noOtherProcessApi;
  // --local: the two checks that depend on the hook code only; nested and runtime-missing are platform behaviour
  if (process.argv.includes('--local')) {
    write('checks-a3.json', { attempt: 3, date: new Date().toISOString().slice(0, 10), ...res, carried: 'nested and noRuntime: checks-a2.json', pass: res.labels.pass && res.boundary.pass });
    console.log(JSON.stringify(res, null, 1));
    process.exit(0);
  }
  // 4. nested converter: a logging hook on every event in the project settings (the converter loads project settings
  // only), exec form; one window converted with V2_NESTED=1. Pass needs hooks to have run at all, each one guarded.
  const log = path.join(os.tmpdir(), `d18-hooklog-${Date.now()}.txt`);
  const logger = path.join(os.tmpdir(), 'd18-logger.mjs');
  fs.writeFileSync(logger, `import fs from 'node:fs';\nconst i = JSON.parse(fs.readFileSync(0, 'utf8'));\nfs.appendFileSync(${JSON.stringify(log)}, (process.env.V2_NESTED === '1' ? 'nested ' : 'outer ') + i.hook_event_name + '\\n');\nif (process.env.V2_NESTED === '1') process.exit(0);\n`);
  fs.mkdirSync(path.join(BENCH, '.claude'), { recursive: true });
  const hook = { type: 'command', command: 'node', args: [logger.replace(/\\/g, '/')] };
  // the repo's own .claude/ holds tracked documents: only settings.json is replaced, and restored after
  const tracked = git(BENCH, 'ls-files', '--error-unmatch', '.claude/settings.json').status === 0;
  fs.writeFileSync(path.join(BENCH, '.claude', 'settings.json'), JSON.stringify({ hooks: Object.fromEntries(['SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Stop'].map((ev) => [ev, [{ hooks: [hook] }]])) }));
  const doc = fs.readFileSync(path.join(BENCH, source), 'utf8').slice(0, 3500);
  const win = { file: source, part: [{ i: 0, e: { heads: [], text: doc } }], k: 0, bytes: Buffer.byteLength(doc) };
  console.log(`nested converter: one window of ${win.bytes} bytes, estimated cost under 0.05 USD`);
  process.env.V2_NESTED = '1';
  const conv = await convert(win, BENCH);
  delete process.env.V2_NESTED;
  const lines = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [];
  res.nested = { converted: !conv.error && conv.entries.length > 0, entries: conv.entries.length, costUsd: conv.cost, hookCalls: lines.length, events: [...new Set(lines.map((l) => l.split(' ')[1]))], outerCalls: lines.filter((l) => l.startsWith('outer')).length };
  res.nested.pass = res.nested.converted && res.nested.hookCalls > 0 && res.nested.outerCalls === 0;
  if (tracked) git(BENCH, 'checkout', '--', '.claude/settings.json');
  else fs.rmSync(path.join(BENCH, '.claude', 'settings.json'));
  res.nested.repoSettingsReplaced = tracked;
  // 5. runtime missing: a SessionStart hook naming a binary that does not exist, in exec form (as registered; the
  // pass) and in shell form (reported); the session must complete
  const session = (h) => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'd18-noruntime-'));
    spawnSync('git', ['init', '-q', tmp]);
    fs.mkdirSync(path.join(tmp, '.claude'));
    fs.writeFileSync(path.join(tmp, '.claude', 'settings.local.json'), JSON.stringify({ hooks: { SessionStart: [{ hooks: [h] }] } }));
    const env = { ...process.env, DISABLE_AUTOUPDATER: '1', MSYS_NO_PATHCONV: '1' };
    for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
    const r = spawnSync('claude', ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
      { cwd: tmp, input: 'Say hello in one word.', encoding: 'utf8', env, timeout: 300_000 });
    const evs = (r.stdout ?? '').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
    const result = evs.findLast((e) => e.type === 'result');
    const hookEv = evs.filter((e) => /hook/i.test(`${e.type ?? ''} ${e.subtype ?? ''}`));
    return { completed: result?.subtype === 'success', costUsd: result?.total_cost_usd, hookEvents: hookEv.length,
      outcomes: [...new Set(hookEv.map((e) => e.outcome ?? e.subtype).filter(Boolean))], shown: hookEv.map((e) => scrub(e.stderr ?? e.output ?? e.error ?? '')).filter(Boolean).slice(0, 2) };
  };
  res.noRuntime = { exec: session({ type: 'command', command: 'nodex-missing-runtime', args: ['hooks.mjs', 'session-start'] }), shell: session({ type: 'command', command: 'nodex-missing-runtime hooks.mjs session-start' }) };
  res.noRuntime.pass = res.noRuntime.exec.completed;
  write('checks-a3.json', { attempt: 3, date: new Date().toISOString().slice(0, 10), ...res, pass: res.labels.pass && res.boundary.pass && res.nested.pass && res.noRuntime.pass });
  console.log(JSON.stringify(res, null, 1));
}
