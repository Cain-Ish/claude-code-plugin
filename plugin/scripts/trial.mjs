// The trial (06, section 8, 8e; D34's option T): tests one skill, agent or path rule of this repo, or a draft of one,
// against a run without it, each case judged by its own check script. No model starts, runs or judges it: a person
// types /second-brain:tailor show <name>, reads it, then types the line it printed with Claude Code's ! prefix, and
// this script does the rest, detached.
//   cli                        the tailor skill's ! block, the person's words on stdin: "show <name>" shows a trial;
//                              any other words hand over to the making steps. It never starts a trial
//   run <name> <hash>          the person's yes, typed with ! as show printed it
//   draft <name> <kind>        the making steps' only write
//   exec <name> <hash>         the detached run that `run` starts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { MAP, toplevel, inRepo } from './map.mjs';
import { PRIVATE } from './dream.mjs';

export const casesFile = (root, name) => path.join(root, MAP, 'evals', `${name}.json`);
const CHECKS = `${MAP}/evals/checks/`;
const HOMES = /^\.claude\/(?:skills\/[\w.-]+\/SKILL\.md|agents\/[\w.-]+\.md|rules\/[\w.-]+\.md)(?:\.draft)?$/;
const FIELDS = ['artifact', 'cases', 'runs'];
const CASE_FIELDS = ['id', 'prompt', 'tools', 'check', 'use', 'runs'];
// a case with no tools listed gets these; a skill's case must list Skill, an agent's the subagent tool, or the arms
// cannot differ (the tools are limited to the list)
export const DEFAULT_TOOLS = ['Read', 'Write', 'Edit', 'Glob', 'Grep'];
const NEEDS = { skill: ['Skill'], agent: ['Agent', 'Task'], rule: [] };
const kindOf = (a) => (a.startsWith('.claude/skills/') ? 'skill' : a.startsWith('.claude/agents/') ? 'agent' : 'rule');
const plainFile = (p) => { try { return fs.lstatSync(p).isFile(); } catch { return false; } };
const runsOk = (n) => Number.isInteger(n) && n >= 3 && n <= 5;

// git with no console window: the detached run has no console, so on Windows each console program it starts would
// otherwise get a console of its own, at a cost of seconds per call
const git = (cwd, ...args) => spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 64 << 20, windowsHide: true });
const blob = (root, commit, rel) => spawnSync('git', ['show', `${commit}:${rel}`], { cwd: root, maxBuffer: 64 << 20, windowsHide: true });
// a file the commit holds, which the working tree has not changed since, as git compares them (so core.autocrlf's
// line ends are no change)
const committed = (root, commit, rel) => git(root, 'cat-file', '-e', `${commit}:${rel}`).status === 0 && git(root, 'diff', '--quiet', commit, '--', rel).status === 0;

// the case file: an artifact in one of the three homes; three cases or more, one where it should not be used; each
// with a prompt (none that reads as a flag), the tools it may use (none that reads as a flag, and the one its kind
// needs) and a check script under the evals' checks folder; runs from 3 to 5; no field it does not know, no path that
// climbs, and nothing private (D31's scan)
export function validate(root, spec, text = JSON.stringify(spec)) {
  const errs = [];
  const unknown = (o, known) => Object.keys(o ?? {}).filter((k) => !known.includes(k));
  if (unknown(spec, FIELDS).length) errs.push(`fields it does not know: ${unknown(spec, FIELDS).join(', ')}`);
  const a = String(spec?.artifact ?? '');
  if (!HOMES.test(a) || a.split('/').includes('..')) errs.push('the artifact must be a skill, agent or rule file under .claude/, a draft or live');
  else if (!plainFile(path.join(root, a)) || !inRepo(root, path.join(root, a))) errs.push(`the artifact is not a plain file in the repo: ${a}`);
  const cases = Array.isArray(spec?.cases) ? spec.cases : [];
  if (cases.length < 3) errs.push('three cases or more');
  if (!cases.some((c) => c?.use === false)) errs.push('one case where it should not be used (use: false)');
  const ids = new Set();
  for (const c of cases) {
    if (unknown(c, CASE_FIELDS).length) errs.push(`case ${c?.id}: fields it does not know: ${unknown(c, CASE_FIELDS).join(', ')}`);
    if (!/^[\w-]+$/.test(String(c?.id ?? '')) || ids.has(c.id)) errs.push(`case id: ${c?.id}`);
    ids.add(c?.id);
    if (typeof c?.prompt !== 'string' || !c.prompt.trim() || c.prompt.trim().startsWith('-')) errs.push(`case ${c?.id}: a prompt, not starting with -`);
    if (c?.tools !== undefined && (!Array.isArray(c.tools) || c.tools.some((t) => typeof t !== 'string' || !t.trim() || t.trim().startsWith('-')))) errs.push(`case ${c?.id}: tools must be a list of tool names`);
    else if (NEEDS[kindOf(a)].length && !(c?.tools ?? DEFAULT_TOOLS).some((t) => NEEDS[kindOf(a)].includes(t.trim()))) errs.push(`case ${c?.id}: tools must list ${NEEDS[kindOf(a)].join(' or ')}`);
    const k = String(c?.check ?? '');
    if (!k.startsWith(CHECKS) || k.split('/').includes('..') || !k.endsWith('.mjs') || !plainFile(path.join(root, k)) || !inRepo(root, path.join(root, k))) errs.push(`case ${c?.id}: a check script under ${CHECKS}`);
    if (c?.runs !== undefined && !runsOk(c.runs)) errs.push(`case ${c?.id}: runs from 3 to 5`);
  }
  if (spec?.runs !== undefined && !runsOk(spec.runs)) errs.push('runs from 3 to 5');
  if (PRIVATE.test(text)) errs.push('it holds private data: a secret, a session id, an email address or an absolute path');
  return errs;
}

// the files beside a skill draft (a script it calls), as they are on disk: "with" adds them
function extrasOf(root, dir) {
  const out = [];
  const walk = (d) => { for (const e of fs.readdirSync(path.join(root, d), { withFileTypes: true })) { const p = `${d}/${e.name}`; if (e.isDirectory()) walk(p); else if (e.isFile() && !/^SKILL\.md(\.draft)?$/.test(p.slice(dir.length + 1))) out.push({ rel: p, body: fs.readFileSync(path.join(root, p)) }); } };
  if (fs.lstatSync(path.join(root, dir), { throwIfNoEntry: false })?.isDirectory()) walk(dir);
  return out.sort((x, y) => (x.rel < y.rel ? -1 : 1));
}

// the artifact's kind, its live path, its name, its text, and what each arm holds: a new draft against nothing, a
// change draft against the file as the commit holds it, a live artifact (as the commit holds it) against its removal
export function describe(root, commit, artifact) {
  const live = artifact.replace(/\.draft$/, '');
  const kind = kindOf(live);
  const draft = artifact !== live;
  if (!draft && !committed(root, commit, artifact)) throw new Error(`${artifact} must be committed and unchanged: a live artifact runs as the commit holds it`);
  const text = draft ? fs.readFileSync(path.join(root, artifact), 'utf8') : blob(root, commit, artifact).stdout.toString('utf8');
  const named = (text.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1] ?? '').match(/^name:[ \t]*["']?([^"'\r\n]+?)["']?[ \t]*$/m)?.[1];
  const name = kind === 'skill' ? named || live.split('/')[2] : kind === 'agent' ? named || path.basename(live, '.md') : null;
  const change = draft && git(root, 'cat-file', '-e', `${commit}:${live}`).status === 0;
  const extras = kind === 'skill' && draft ? extrasOf(root, path.posix.dirname(live)) : [];
  return { live, kind, name, text, draft, change, extras };
}

function load(root, name) {
  if (!/^[\w.-]+$/.test(String(name ?? ''))) throw new Error(`a name of letters, digits, dots and dashes: ${name}`);
  const commit = git(root, 'rev-parse', '--verify', '-q', 'HEAD^{commit}').stdout.trim();
  if (!commit) throw new Error('the repo has no commit yet');
  const file = casesFile(root, name);
  const rel = path.relative(root, file).split(path.sep).join('/');
  if (!plainFile(file) || !inRepo(root, file)) throw new Error(`no case file at ${rel} (a plain file, not a link)`);
  if (!committed(root, commit, rel)) throw new Error(`${rel} must be committed and unchanged since: only what a commit has seen runs`);
  const text = blob(root, commit, rel).stdout.toString('utf8');
  let spec;
  try { spec = JSON.parse(text); } catch { throw new Error(`${rel} is not JSON`); }
  const errs = validate(root, spec, text);
  if (errs.length) throw new Error(`the case file needs: ${errs.join('; ')}`);
  const checks = {};
  for (const k of [...new Set(spec.cases.map((c) => c.check))].sort()) {
    if (!committed(root, commit, k)) throw new Error(`${k} must be committed and unchanged since: only what a commit has seen runs`);
    checks[k] = blob(root, commit, k).stdout.toString('utf8');
  }
  const info = describe(root, commit, spec.artifact);
  // the person's yes covers all of it: the commit every copy comes from (which holds the case file and each check
  // script, both unchanged since, as above), the artifact, and the files beside a skill draft
  const h = crypto.createHash('sha256').update(`${commit}\0`).update(info.text);
  for (const e of info.extras) h.update(`\0${e.rel}\0`).update(e.body);
  return { spec, info, commit, checks, rel, hash: h.digest('hex').slice(0, 12), runs: (c) => c.runs ?? spec.runs ?? 3 };
}

// what run would do, for the person to read before they type its line; nothing runs
export function show(root, name, self = fileURLToPath(import.meta.url)) {
  const { spec, info, checks, hash, runs } = load(root, name);
  const fm = info.text.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1];
  const bangs = info.text.split('\n').filter((l) => /!`|^\s*```!/.test(l));
  const sessions = spec.cases.reduce((s, c) => s + runs(c) * 2, 0);
  return [`Trial of ${spec.artifact} (${info.kind}${info.name ? ` "${info.name}"` : ''}): "with" ${info.draft ? 'has the draft in place' : 'has it as the commit holds it'}, "without" ${info.change ? 'has the file as the commit holds it' : info.draft ? 'has nothing there' : 'has it removed'}.`,
    `${sessions} sessions, each in its own copy of the last commit outside the repo, as claude -p with acceptEdits, only the case's tools, project settings only, every hook off, no MCP server and no transcript kept. Each one costs usage. Each case's check script decides a pass.`,
    fm ? `Its front matter:\n${fm.split(/\r?\n/).map((l) => `  ${l}`).join('\n')}` : 'It has no front matter.',
    bangs.length ? `Its command lines:\n${bangs.map((l) => `  ${l.trim()}`).join('\n')}` : 'It runs no command lines.',
    ...(info.extras.length ? [`Files beside it, which "with" adds: ${info.extras.map((e) => e.rel).join(', ')}`] : []),
    ...spec.cases.map((c) => `- case ${c.id} (${c.use === false ? 'should not be used' : 'should be used'}), ${runs(c)} run(s) per arm\n  prompt: ${c.prompt}\n  tools: ${(c.tools ?? DEFAULT_TOOLS).join(', ')}\n  check: ${c.check}`),
    ...Object.entries(checks).map(([k, t]) => `The check script ${k}, which runs with node on each session's work:\n${t.split(/\r?\n/).map((l) => `  | ${l}`).join('\n')}`),
    'To run it, type this line yourself; the ! runs it in your shell, so no model starts it:',
    `! node "${self.split(path.sep).join('/')}" run ${name} ${hash}`].join('\n');
}

// the person's yes: the hash show printed, against the files as they are now; then the run starts detached and this
// returns at once
export function start(root, name, hash, self = fileURLToPath(import.meta.url)) {
  const { hash: now } = load(root, name);
  if (hash !== now) throw new Error(`the hash ${hash || '(none)'} is not this case file and artifact as they are now: type /second-brain:tailor show ${name} again`);
  spawn(process.execPath, [self, 'exec', name, hash], { cwd: root, detached: true, stdio: 'ignore', windowsHide: true, env: childEnv() }).unref();
  return `The trial of ${name} started. Its verdict lands in ${MAP}/.trial/${name}.json when it ends, and /map-review shows it.`;
}

// the session: its tools limited to the case's (--tools takes the names, --allowedTools approves them as written),
// acceptEdits, project settings only, every hook off, no MCP server, no transcript kept, and one JSON result; its
// environment, without the variables that link a session to the Claude Code session that started it (its id, its
// messaging socket and token, its child notes), so it starts as from a plain terminal; login and configuration stay
export const childArgs = (prompt, tools) => ['-p', prompt, '--output-format', 'json', '--permission-mode', 'acceptEdits', '--setting-sources', 'project,local', '--no-session-persistence',
  '--settings', JSON.stringify({ disableAllHooks: true }), '--strict-mcp-config', '--tools', ...new Set(tools.map((t) => t.replace(/\(.*$/s, '').trim())), '--allowedTools', ...tools];
const LINKS = /^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_(ENTRYPOINT|SESSION_\w+|BRIDGE_\w+|CHILD_\w+|MESSAGING_\w+))$/i;
export const childEnv = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !LINKS.test(k)));
// a check script's environment: what node and git need to run, and nothing else of the user's
const checkEnv = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(PATH|PATHEXT|SYSTEMROOT|WINDIR|COMSPEC|HOME|USERPROFILE|TEMP|TMP|TMPDIR|LANG|LC_ALL)$/i.test(k)));

// a commit in a copy, with no signing and no hooks of the user's (a hooks folder that does not exist), and the same
// message in every arm; a failure stops that run, so a session never runs on a tree it was not meant to see
const GIT_COPY = ['-c', 'user.name=trial', '-c', 'user.email=trial@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=.git/no-hooks', '-c', 'core.autocrlf=false'];
const commit = (dir) => { for (const a of [['add', '-A'], ['commit', '-qm', 'trial copy', '--allow-empty']]) { const r = git(dir, ...GIT_COPY, ...a); if (r.status !== 0) throw new Error(`git ${a[0]} failed in a copy: ${String(r.stderr).trim()}`); } };
// a copy of one commit, with no history: each blob it holds (no links, no submodules, no path with a backslash, a
// colon, a .git or .. segment), then a fresh repository, so the session's git sees a clean tree. The evals folder
// never reaches a copy
export function copyHead(root, commitId, to) {
  const tree = git(root, 'ls-tree', '-r', '-z', commitId).stdout.split('\0').filter(Boolean).map((l) => { const [meta, p] = l.split('\t'); const [mode, type, oid] = meta.split(' '); return { mode, type, oid, p }; })
    .filter((e) => e.type === 'blob' && e.mode !== '120000' && !`${e.p}/`.startsWith(`${MAP}/evals/`) && !/[\\:]/.test(e.p) && !e.p.split('/').some((s) => s === '..' || s.toLowerCase() === '.git'));
  const out = spawnSync('git', ['cat-file', '--batch'], { cwd: root, input: tree.map((e) => e.oid).join('\n') + '\n', maxBuffer: 1 << 30, windowsHide: true }).stdout;
  let at = 0;
  for (const e of tree) {
    const nl = out.indexOf(10, at);
    const size = Number(out.toString('latin1', at, nl).split(' ')[2]);
    const body = out.subarray(nl + 1, nl + 1 + size);
    at = nl + 1 + size + 1;
    fs.mkdirSync(path.dirname(path.join(to, e.p)), { recursive: true });
    fs.writeFileSync(path.join(to, e.p), body, { mode: e.mode === '100755' ? 0o755 : 0o644 });
  }
  fs.mkdirSync(to, { recursive: true });
  const r = git(to, ...GIT_COPY, 'init', '-q');
  if (r.status !== 0) throw new Error(`git init failed in a copy: ${String(r.stderr).trim()}`);
  commit(to);
}

// one arm at the artifact's live path; a draft file itself never stays in a copy
export function place(copy, info, arm) {
  const live = path.join(copy, info.live);
  fs.rmSync(`${live}.draft`, { force: true });
  if (arm === 'with' && info.draft) {
    for (const e of info.extras) { fs.mkdirSync(path.dirname(path.join(copy, e.rel)), { recursive: true }); fs.writeFileSync(path.join(copy, e.rel), e.body); }
    fs.mkdirSync(path.dirname(live), { recursive: true });
    fs.writeFileSync(live, info.text);
  } else if (arm === 'without' && !info.change) {
    // a new skill has no folder at all; a live artifact is removed; a change keeps the file as the commit holds it
    if (info.kind === 'skill' && info.draft) fs.rmSync(path.dirname(live), { recursive: true, force: true });
    else fs.rmSync(live, { force: true });
  }
  commit(copy);
}

// a session counts only when it ran to its end: a JSON result that is not an error, exit 0, and no stop at 15 minutes
function session(cwd, prompt, tools) {
  const stub = process.env.SECOND_BRAIN_TRIAL_CLAUDE; // the self-test's stand-in for claude
  const [cmd, args] = stub ? [process.execPath, [stub, ...childArgs(prompt, tools)]] : ['claude', childArgs(prompt, tools)];
  return new Promise((done) => {
    let out = '';
    let killed = false;
    const c = spawn(cmd, args, { cwd, env: childEnv(), stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
    c.stdout.on('data', (d) => { if (out.length < 1 << 22) out += d; });
    const stop = setTimeout(() => { killed = true; c.kill(); }, 900_000);
    c.on('error', () => { clearTimeout(stop); done(false); });
    c.on('close', (code) => {
      clearTimeout(stop);
      let r = null;
      try { r = JSON.parse(out); } catch {}
      done(!killed && code === 0 && r?.type === 'result' && r.is_error === false);
    });
  });
}

// a check script, from the text read at the start, fed to node on stdin after the session: it never touches the disk,
// so no session can change what judges it (06, 8e, attempt 3). It runs on the session's copy, with a reduced
// environment
const judged = (text, copy) => spawnSync(process.execPath, ['--input-type=module', '-'], { cwd: copy, input: text, env: checkEnv(), timeout: 120_000, windowsHide: true }).status === 0;

// the verdict, fixed before any run (06, 8e, attempt 2): "not judged" when a session or a copy failed, or a case where
// it should not be used fails without it; "hurts" when that case fails with it. A case where it should be used is
// better or worse only by a margin of half its runs, rounded up: one pass in three was seen without the artifact on
// cases that need it. Then "mixed", "helps", "hurts" or "adds nothing" (a case where it should not be used has
// passed every run in both arms by then, so it adds no difference)
export function verdict(rows, failed = 0) {
  if (failed || rows.some((r) => !r.use && r.without < r.runs)) return 'not judged';
  if (rows.some((r) => !r.use && r.with < r.runs)) return 'hurts';
  const margin = (r) => Math.ceil(r.runs / 2);
  const better = rows.some((r) => r.with - r.without >= margin(r));
  const worse = rows.some((r) => r.without - r.with >= margin(r));
  return better && worse ? 'mixed' : better ? 'helps' : worse ? 'hurts' : 'adds nothing';
}

// the verdict file, inside the repo and git-ignored, privacy-scanned, and never written through a file or link
// already at its path
export function record(root, name, out) {
  const text = `${JSON.stringify(out, null, 1)}\n`;
  if (PRIVATE.test(text)) throw new Error('the verdict would hold private data');
  const dir = path.join(root, MAP, '.trial');
  if (!inRepo(root, dir)) throw new Error(`${MAP}/.trial is a link out of the repo`);
  fs.mkdirSync(dir, { recursive: true });
  for (const [f, body] of [['.gitignore', '*\n'], [`${name}.json`, text]]) { const p = path.join(dir, f); fs.rmSync(p, { force: true }); fs.writeFileSync(p, body, { flag: 'wx' }); }
}
// git's blob id of a file, which /map-review can compute again to tell a stale verdict
const blobId = (root, rel) => git(root, 'hash-object', '--', rel).stdout.trim();

// the run: one session at a time (06, 8e, attempt 3), so no session runs while another job's copy exists
export async function exec(root, name, hash) {
  const t = load(root, name);
  if (hash !== t.hash) throw new Error('the case file or the artifact changed after the run started');
  const jobs = ['with', 'without'].flatMap((arm) => t.spec.cases.flatMap((c) => Array.from({ length: t.runs(c) }, () => ({ arm, c }))));
  const pass = {};
  let failed = 0;
  for (const { arm, c } of jobs) {
    let copy = null;
    try {
      copy = fs.mkdtempSync(path.join(os.tmpdir(), 'second-brain-trial-'));
      if (inRepo(root, copy)) throw new Error('the temporary folder lies inside the repo');
      copyHead(root, t.commit, copy);
      place(copy, t.info, arm);
      if (!(await session(copy, c.prompt, c.tools ?? DEFAULT_TOOLS))) { failed++; continue; }
      if (judged(t.checks[c.check], copy)) pass[`${c.id}\0${arm}`] = (pass[`${c.id}\0${arm}`] ?? 0) + 1;
    } catch { failed++; } finally { if (copy) fs.rmSync(copy, { recursive: true, force: true }); }
  }
  const rows = t.spec.cases.map((c) => ({ id: c.id, use: c.use !== false, runs: t.runs(c), with: pass[`${c.id}\0with`] ?? 0, without: pass[`${c.id}\0without`] ?? 0 }));
  const out = { artifact: t.spec.artifact, kind: t.info.kind, hash, artifactBlob: blobId(root, t.spec.artifact), casesBlob: blobId(root, t.rel), date: new Date().toISOString().slice(0, 10), failed, cases: rows, verdict: verdict(rows, failed) };
  record(root, name, out);
  return out;
}

// the made artifact, staged by Claude in .project-map/drafts/<name>/ (a folder Claude Code does not guard), moved into
// .claude/ as an inert draft, as the dream's finish writes its drafts: never over a file, never through a link or a
// path that leaves the repo, only with the front matter it needs and its own name, and never holding private data
const HOME = { skill: (n) => [`.claude/skills/${n}/SKILL.md.draft`, 'SKILL.md'], agent: (n) => [`.claude/agents/${n}.md.draft`, 'agent.md'], rule: (n) => [`.claude/rules/${n}.md.draft`, 'rule.md'] };
export function draft(root, name, kind) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(String(name))) throw new Error(`a name of lowercase letters, digits and dashes: ${name}`);
  if (!HOME[kind]) throw new Error('the kind is skill, agent or rule');
  const src = path.join(root, MAP, 'drafts', name);
  if (!fs.lstatSync(src, { throwIfNoEntry: false })?.isDirectory() || !inRepo(root, src)) throw new Error(`no folder ${MAP}/drafts/${name} (a plain folder, not a link)`);
  const [target, main] = HOME[kind](name);
  if (!plainFile(path.join(src, main))) throw new Error(`no ${MAP}/drafts/${name}/${main}`);
  const text = fs.readFileSync(path.join(src, main), 'utf8');
  const fm = text.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1] ?? '';
  for (const k of kind === 'rule' ? ['paths'] : kind === 'agent' ? ['name', 'description', 'tools'] : ['name', 'description']) if (!new RegExp(`^${k}:[ \\t]*\\S`, 'm').test(fm)) throw new Error(`the front matter needs ${k}`);
  // Claude Code knows a skill or an agent by its name, so the name is the draft's own (8d's rule)
  if (kind !== 'rule' && fm.match(/^name:[ \t]*["']?([^"'\r\n]+?)["']?[ \t]*$/m)?.[1] !== name) throw new Error(`the front matter's name must be ${name}`);
  const files = [[path.join(src, main), target], ...(kind === 'skill' ? fs.readdirSync(src).filter((f) => f !== main) : []).map((f) => [path.join(src, f), `.claude/skills/${name}/${f}`])];
  for (const [from, to] of files) {
    if (!plainFile(from)) throw new Error(`not a plain file: ${path.basename(from)}`);
    if (PRIVATE.test(fs.readFileSync(from, 'utf8'))) throw new Error(`${path.basename(from)} holds private data`);
    if (!inRepo(root, path.join(root, to))) throw new Error(`${to} resolves outside the repo`);
    if (fs.existsSync(path.join(root, to)) || fs.existsSync(path.join(root, to.replace(/\.draft$/, '')))) throw new Error(`${to} or its live file exists; nothing is overwritten`);
  }
  for (const [from, to] of files) {
    fs.mkdirSync(path.dirname(path.join(root, to)), { recursive: true });
    fs.writeFileSync(path.join(root, to), fs.readFileSync(from), { flag: 'wx' });
  }
  fs.rmSync(src, { recursive: true, force: true });
  return files.map(([, to]) => to);
}

if (path.basename(process.argv[1] ?? '') === 'trial.mjs') {
  const [cmd, ...rest] = process.argv.slice(2);
  const root = toplevel(process.cwd());
  try {
    if (cmd === 'cli') {
      // the person's words, on stdin from the skill's quoted heredoc, so the shell never reads them
      const words = process.stdin.isTTY ? '' : fs.readFileSync(0, 'utf8').trim();
      const m = /^show\s+(\S+)$/.exec(words);
      if (m) console.log(show(root, m[1]));
      else if (/^run\b/.test(words)) console.log('A trial starts only from the line that /second-brain:tailor show <name> prints, typed by you with its ! at the start.');
      else console.log('Tailor: make one agent, skill or path rule for a gap this repo shows. Follow the steps below.');
    } else if (cmd === 'run') console.log(start(root, rest[0], rest[1]));
    else if (cmd === 'exec') {
      try { await exec(root, rest[0], rest[1]); } catch (e) {
        // a trial that stopped is never a verdict: the record says so, and /map-review offers nothing on it
        if (/^[\w.-]+$/.test(String(rest[0] ?? ''))) try { record(root, rest[0], { date: new Date().toISOString().slice(0, 10), verdict: 'not judged', stopped: true }); } catch {}
        throw e;
      }
    } else if (cmd === 'draft') console.log(`Written, as drafts: ${draft(root, rest[0], rest[1]).join(', ')}`);
    else throw new Error('use: trial.mjs cli (words on stdin) | run <name> <hash> | draft <name> <skill|agent|rule>');
  } catch (e) {
    console.log(`The trial stopped: ${e.message}`);
    // a failed ! line aborts the skill; the message is the report, so the skill still renders it
    process.exitCode = cmd === 'cli' ? 0 : 1;
  }
}
