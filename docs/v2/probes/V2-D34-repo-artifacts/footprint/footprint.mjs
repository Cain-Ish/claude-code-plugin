// Measures what the second-brain plugin writes, step by step, in an isolated temp folder. Read-only on the plugin.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const PLUGIN = path.resolve(import.meta.dirname, '../../../../../plugin');
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');
const DREAM = path.join(PLUGIN, 'scripts', 'dream.mjs');
const STATUS = path.join(PLUGIN, 'scripts', 'status.mjs');
const OUT = process.argv[2];
const realTemp = os.tmpdir();
const realMarkers = () => fs.readdirSync(realTemp).filter((n) => /^project-map-/.test(n)).sort();
const realBefore = realMarkers();

const tmp = fs.realpathSync.native(fs.mkdtempSync(path.join(realTemp, 'sb-footprint-')));
const cfg = path.join(tmp, 'config');
const data = path.join(cfg, 'plugins', 'data', 'second-brain');
const ostemp = path.join(tmp, 'ostemp');
const repo0 = path.join(tmp, 'repo');
for (const d of [cfg, data, ostemp, repo0, path.join(tmp, 'no-v1')]) fs.mkdirSync(d, { recursive: true });
const repo = fs.realpathSync.native(repo0);
const env = { ...process.env, CLAUDE_PROJECT_DIR: repo, CLAUDE_CONFIG_DIR: cfg, CLAUDE_PLUGIN_DATA: data, CLAUDE_PLUGIN_ROOT: PLUGIN, BRAIN_DIR: path.join(tmp, 'no-v1', '.second-brain'), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp };
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: repo, encoding: 'utf8', env, ...opts });
const git = (...a) => sh('git', a);

// ---- fixture repo: a few docs, one committed map topic file (a teammate's), one commit
const w = (rel, text) => { const p = path.join(repo, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); };
git('init', '-q', '-b', 'main');
w('README.md', '# Demo\n\nA small demo project.\n');
w('docs/guide.md', '# Guide\n\nAll builds run through npm run build.\n');
w('docs/api.md', '# API\n\nThe API serves JSON.\n');
w('src/app.js', 'console.log("hi");\n');
w('.project-map/build.md', '---\nname: build\ndescription: How the project builds. Read before changing the build.\n---\n\n### build\n> All builds run through npm run build.\n\n- id: build-npm\n- source: the lead developer, 2026-11-20\n- when: ["build work"]\n- verified: 2026-11-20 stated by the lead\n');
git('add', '-A');
git('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '-m', 'init');

// ---- fake transcripts, as Claude Code writes them
const tdir = path.join(cfg, 'projects', repo.replace(/[^A-Za-z0-9]/g, '-'));
fs.mkdirSync(tdir, { recursive: true });
const S = ['11111111-aaaa-4bbb-8ccc-000000000001', '11111111-aaaa-4bbb-8ccc-000000000002', '22222222-aaaa-4bbb-8ccc-000000000003', '22222222-aaaa-4bbb-8ccc-000000000004'];
const U = (t, ts) => JSON.stringify({ type: 'user', promptSource: 'sdk', isMeta: false, cwd: repo, sessionId: 'x', timestamp: ts, message: { role: 'user', content: t } });
const A = (t, ts) => JSON.stringify({ type: 'assistant', cwd: repo, timestamp: ts, message: { role: 'assistant', content: [{ type: 'text', text: t }] } });
const T = (name, input, id) => JSON.stringify({ type: 'assistant', cwd: repo, message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
const R = (t, id) => JSON.stringify({ type: 'user', cwd: repo, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: t }] } });
fs.writeFileSync(path.join(tdir, `${S[0]}.jsonl`), [
  U('SENTINEL-ALPHA decision: all API responses use camelCase keys. Ask jane.doe@example.com; my notes are in C:\\Users\\jdoe\\notes.txt', '2026-11-20T10:00:00Z'),
  A('Understood, SENTINEL-ALPHA-REPLY.', '2026-11-20T10:00:05Z'),
  T('Read', { file_path: path.join(repo, '.project-map', 'build.md') }, 't1'),
  R('SENTINEL-TOOLOUT build.md contents', 't1'),
  U('Release steps: bump the patch version, update the changelog, then tag the release.', '2026-11-20T11:00:00Z'),
].join('\n') + '\n');
fs.writeFileSync(path.join(tdir, `${S[1]}.jsonl`), [
  U('SENTINEL-BETA rule: release tags are signed with the team key, and all API responses use camelCase keys.', '2026-11-21T10:00:00Z'),
  A('Noted.', '2026-11-21T10:00:05Z'),
  U('Release steps again: bump the patch version, update the changelog, then tag the release.', '2026-11-21T11:00:00Z'),
].join('\n') + '\n');
// the current session's own transcript (Claude Code writes it; sid S[2])
const tp = (sid) => path.join(tdir, `${sid}.jsonl`);
fs.writeFileSync(tp(S[2]), U('SENTINEL-CURRENT please check the build notes.', '2026-11-24T09:00:00Z') + '\n');

// ---- snapshots
const walk = (base, skip = []) => {
  const out = {};
  const rec = (rel) => {
    const p = path.join(base, rel);
    let es = [];
    try { es = fs.readdirSync(p, { withFileTypes: true }); } catch { return; }
    for (const e of es) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (skip.some((s) => r === s || r.startsWith(`${s}/`))) continue;
      if (e.isDirectory()) { out[`${r}/`] = 'dir'; rec(r); }
      else { const b = fs.readFileSync(path.join(base, r)); out[r] = `${b.length}:${crypto.createHash('sha256').update(b).digest('hex').slice(0, 12)}`; }
    }
  };
  rec('');
  return out;
};
const snap = () => ({
  config: walk(cfg, ['plugins/data/second-brain']),
  data: walk(data),
  repo: walk(repo, ['.git']),
  git: walk(path.join(repo, '.git')),
  ostemp: walk(ostemp),
  status: git('--no-optional-locks', 'status', '--porcelain', '--untracked-files=all', '--ignored').stdout,
  realTemp: realMarkers(),
});
const diff = (a, b) => {
  const res = {};
  for (const k of ['config', 'data', 'repo', 'git', 'ostemp']) {
    const created = Object.keys(b[k]).filter((f) => !(f in a[k])).map((f) => `${f} ${b[k][f] === 'dir' ? '' : `(${b[k][f].split(':')[0]} B)`}`.trim());
    const deleted = Object.keys(a[k]).filter((f) => !(f in b[k]));
    const changed = Object.keys(b[k]).filter((f) => f in a[k] && a[k][f] !== b[k][f]).map((f) => `${f} (${a[k][f].split(':')[0]} -> ${b[k][f].split(':')[0]} B)`);
    if (created.length || deleted.length || changed.length) res[k] = { created, deleted, changed };
  }
  if (a.status !== b.status) res.gitStatus = b.status;
  if (a.realTemp.join() !== b.realTemp.join()) res.realTemp = b.realTemp;
  return res;
};
const log = { tmp, repo, data, ostemp, baseline: null, steps: [] };
let prev = snap();
log.baseline = { status: prev.status, config: prev.config, repo: prev.repo };
const step = (name, fn) => {
  const r = fn();
  const now = snap();
  log.steps.push({ name, out: r, diff: diff(prev, now) });
  prev = now;
  return r;
};
const hook = (which, input) => { const r = sh('node', [HOOK, which], { input: JSON.stringify(input) }); return { status: r.status, stdout: r.stdout, stderr: r.stderr }; };
const base = (sid) => ({ session_id: sid, transcript_path: tp(sid), cwd: repo });
const ok = (cond, msg) => { if (!cond) { log.failed = msg; throw new Error(msg); } };

// ---- where transcript text and personal data ended up (excluding the transcripts themselves)
const NEEDLES = ['SENTINEL-ALPHA', 'SENTINEL-BETA', 'SENTINEL-CURRENT', 'SENTINEL-TOOLOUT', 'jane.doe@example.com', 'jdoe', ...S, os.userInfo().username, tmp, tmp.replace(/\\/g, '/'), tmp.replace(/\\/g, '\\\\'), repo.replace(/[^A-Za-z0-9]/g, '-')];
const grep = () => {
  const hits = {};
  const scan = (dir, label) => { for (const [f, v] of Object.entries(walk(dir, label === 'config' ? ['projects'] : []))) { if (v === 'dir') continue; if (label === 'git' && /^objects\//.test(f)) continue; const t = fs.readFileSync(path.join(dir, f), 'latin1'); const n = NEEDLES.filter((x) => t.includes(x)); if (n.length) hits[`${label}:${f}`] = [...new Set(n.map((x) => (x === tmp || x.includes('sb-footprint') ? '<tmp path>' : x === os.userInfo().username ? '<os username>' : x)))]; } };
  scan(cfg, 'config'); scan(repo, 'repo'); scan(ostemp, 'ostemp');
  return hits;
};
try {
  // 1
  let r = step('1 SessionStart', () => hook('session-start', { ...base(S[2]), hook_event_name: 'SessionStart', source: 'startup' }));
  ok(JSON.parse(r.stdout).hookSpecificOutput.additionalContext.includes('.project-map'), 'session start gave no context');
  // 2
  r = step('2 UserPromptSubmit', () => hook('prompt', { ...base(S[2]), hook_event_name: 'UserPromptSubmit', prompt: 'SENTINEL-CURRENT please check the build notes.' }));
  ok(/Before you start/.test(r.stdout), 'prompt did not take the force');
  // 3
  const mapFile = path.join(repo, '.project-map', 'build.md');
  r = step('3 PostToolUse Read', () => hook('read', { ...base(S[2]), hook_event_name: 'PostToolUse', tool_name: 'Read', tool_input: { file_path: mapFile }, tool_response: { type: 'text', file: { filePath: mapFile, content: fs.readFileSync(mapFile, 'utf8') } } }));
  ok(/additionalContext/.test(r.stdout), 'read gave no labels');
  // 4
  r = step('4 setup', () => { const x = sh('node', [HOOK, 'setup']); return { status: x.status, stdout: x.stdout, stderr: x.stderr }; });
  ok(/^Created \(/.test(r.stdout), 'setup failed');
  // 5
  r = step('5 status', () => { const x = sh('node', [STATUS, data]); return { status: x.status, stdout: x.stdout, stderr: x.stderr }; });
  ok(/^second-brain status/.test(r.stdout), 'status failed');
  // 6a prepare
  r = step('6a dream prepare', () => { const x = sh('node', [DREAM, 'prepare', data]); return { status: x.status, stdout: x.stdout, stderr: x.stderr }; });
  ok(/^Dream prepared: [2-9] session digest/.test(r.stdout), 'prepare failed');
  // 6b what the model would stage, plus one stray edit to a watched file
  const run = path.join(repo, '.project-map', '.dream-run');
  const dg = Object.fromEntries(fs.readdirSync(path.join(run, 'digests')).map((d) => [d, fs.readFileSync(path.join(run, 'digests', d), 'utf8').split('\n')]));
  log.digests = dg;
  const ln = (re) => { for (const [d, ls] of Object.entries(dg)) { const i = ls.findIndex((l) => re.test(l)); if (i >= 0) return `${d}:${i + 1}`; } return null; };
  const ev = [ln(/^U: Release steps: bump/), ln(/^U: Release steps again/)];
  const evr = [ln(/^U: SENTINEL-ALPHA/), ln(/^U: SENTINEL-BETA/)];
  step('6b model stages proposals + a stray edit', () => {
    const P = path.join(run, 'proposals');
    const add = (rel, s) => { fs.mkdirSync(path.dirname(path.join(P, rel)), { recursive: true }); fs.writeFileSync(path.join(P, rel), s); };
    add('map/api.md', '### API responses\n> all API responses use camelCase keys\n\n- id: api-camel\n- source: the user, 2026-11-20\n- when: ["api work"]\n');
    add('rules/api-keys.md', `---\npaths: ["src/api/**"]\n---\nAPI responses use camelCase keys.\n<!-- evidence: ${evr.join(', ')} -->\n`);
    add('skills/release/SKILL.md', `---\nname: release\ndescription: Cuts a release. Use when asked to release or tag.\n---\n1. Bump the patch version.\n2. Update the changelog.\n3. Tag the release.\n<!-- evidence: ${ev.join(', ')} -->\n`);
    fs.appendFileSync(path.join(repo, '.project-map', 'build.md'), '\nstray edit during the dream\n');
    return { ev, evr };
  });
  log.midDreamGrep = grep();
  // 6c finish
  r = step('6c dream finish', () => { const x = sh('node', [DREAM, 'finish', data]); return { status: x.status, stdout: x.stdout, stderr: x.stderr }; });
  ok(/^Dream finished/.test(r.stdout), 'finish failed');
  // 7
  r = step('7 second SessionStart', () => hook('session-start', { ...base(S[3]), hook_event_name: 'SessionStart', source: 'startup' }));
  ok(JSON.parse(r.stdout).hookSpecificOutput.additionalContext.length > 0, 'second session start gave no context');
} catch (e) { log.error = String(e.stack); }

log.finalGrep = grep();
log.realTempBefore = realBefore;
log.realTempAfter = realMarkers();
fs.writeFileSync(OUT, JSON.stringify(log, null, 1));
console.log(log.error ?? 'ok', tmp);
