// The trial (06, section 7, 7a; D34): tests one skill, agent or path rule of this repo, or a draft of one, against a
// run without it (or with its live version), each case in a scratch copy of the repo under the plugin's data folder,
// never inside the repo. It runs nested `claude -p` sessions and records what each did; it grades nothing (the trial
// skill's grader does, blind to the arm).
//   plan <name> <data>   prints what run would do, for the user to see before any session starts
//   run <name> <data>    runs it, then prints where the blind records and the key are
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { MAP, git, toplevel, inRepo, configDir } from './map.mjs';
import { PRIVATE } from './dream.mjs';

export const casesFile = (root, name) => path.join(root, MAP, 'evals', `${name}.json`);
const HOMES = /^\.claude\/(?:skills\/[\w.-]+\/SKILL\.md|agents\/(?:[\w.-]+\/)*[\w.-]+\.md|rules\/(?:[\w.-]+\/)*[\w.-]+\.md)(?:\.draft)?$/;

// (vi) the case file: an artifact in one of the three homes, three cases or more, one where it should not be used,
// each with a prompt, an outcome and the tools it may use, and nothing private (D31's scan)
export function validate(root, spec) {
  const errs = [];
  const a = String(spec?.artifact ?? '');
  if (!HOMES.test(a)) errs.push('the artifact must be a skill, agent or rule file under .claude/, a draft or live');
  else if (!fs.existsSync(path.join(root, a))) errs.push(`the artifact does not exist: ${a}`);
  const cases = Array.isArray(spec?.cases) ? spec.cases : [];
  if (cases.length < 3) errs.push('three cases or more');
  if (!cases.some((c) => c?.use === false)) errs.push('one case where it should not be used (use: false)');
  const ids = new Set();
  for (const c of cases) {
    if (!/^[\w-]+$/.test(String(c?.id ?? '')) || ids.has(c.id)) errs.push(`case id: ${c?.id}`);
    ids.add(c?.id);
    if (typeof c?.prompt !== 'string' || !c.prompt.trim()) errs.push(`case ${c?.id}: a prompt`);
    if (typeof c?.expect !== 'string' || !c.expect.trim()) errs.push(`case ${c?.id}: an outcome (expect)`);
    if (c?.tools !== undefined && (!Array.isArray(c.tools) || c.tools.some((t) => typeof t !== 'string' || !t.trim()))) errs.push(`case ${c?.id}: tools must be a list`);
  }
  if (spec?.old && HOMES.test(a) && (!a.endsWith('.draft') || !fs.existsSync(path.join(root, a.slice(0, -6))))) errs.push('"old" compares a draft with its live file, so both must exist');
  if (PRIVATE.test(JSON.stringify(cases))) errs.push('a case holds private data: a secret, a session id, an email address or an absolute path');
  return errs;
}

// the artifact's kind, its live path, and the name a call to it carries
export function describe(root, artifact) {
  const live = artifact.replace(/\.draft$/, '');
  const kind = live.startsWith('.claude/skills/') ? 'skill' : live.startsWith('.claude/agents/') ? 'agent' : 'rule';
  const text = fs.readFileSync(path.join(root, artifact), 'utf8');
  const named = (text.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1] ?? '').match(/^name:\s*["']?([^"'\r\n]+?)["']?\s*$/m)?.[1];
  const name = kind === 'skill' ? named || live.split('/')[2] : kind === 'agent' ? named || path.basename(live, '.md') : null;
  return { live, kind, name, text };
}

// (iii) whether a run used the artifact: a Skill call by its exact name (a plugin's "x:name" too), or an Agent call
// by its exact type. A path rule makes no call, so its use is not counted
export function usedIn(tools, kind, name) {
  if (kind === 'rule' || !name) return null;
  return tools.some((t) => (kind === 'skill'
    ? t.name === 'Skill' && String(t.input?.skill ?? '').split(':').pop() === name
    : (t.name === 'Agent' || t.name === 'Task') && String(t.input?.subagent_type ?? '') === name));
}

export function readStream(out) {
  const recs = String(out).split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const res = recs.find((r) => r.type === 'result') ?? {};
  const tools = recs.filter((r) => r.type === 'assistant').flatMap((r) => (r.message?.content ?? []).filter((x) => x?.type === 'tool_use').map((x) => ({ name: x.name, input: x.input })));
  return { reply: String(res.result ?? ''), ok: res.subtype === 'success' && !res.is_error, tools };
}

// (vii) the child's arguments: acceptEdits, every hook off, no MCP server, and only the tools the case lists
export const childArgs = (prompt, tools = []) => ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--permission-mode', 'acceptEdits',
  '--settings', JSON.stringify({ disableAllHooks: true }), '--strict-mcp-config', ...(tools.length ? ['--allowedTools', ...tools] : [])];
// (iv) the child's environment, without the variables that mark a session as nested inside Claude Code
export const childEnv = () => { const e = { ...process.env }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };

// (i) a copy of the repo's tracked and untracked, not ignored, files; never its .git. A fresh repository holds them,
// so the session's git commands see a clean tree
export function copyRepo(root, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const f of git(root, 'ls-files', '-z', '-co', '--exclude-standard').stdout.split('\0').filter(Boolean)) {
    const from = path.join(root, f);
    let st = null;
    try { st = fs.lstatSync(from); } catch {}
    if (!st?.isFile()) continue;
    fs.mkdirSync(path.dirname(path.join(to, f)), { recursive: true });
    fs.copyFileSync(from, path.join(to, f));
  }
  git(to, 'init', '-q');
  git(to, 'add', '-A');
  git(to, '-c', 'user.name=trial', '-c', 'user.email=trial@example.invalid', 'commit', '-qm', 'trial copy', '--allow-empty');
}

// (ii) the arm: "with" holds the artifact's text at its live path, "without" holds nothing there, "old" keeps the
// live text the repo has. The draft file itself never stays in a copy
export function place(copy, artifact, info, arm) {
  if (artifact !== info.live) fs.rmSync(path.join(copy, artifact), { force: true });
  const live = path.join(copy, info.live);
  if (arm === 'with') { fs.mkdirSync(path.dirname(live), { recursive: true }); fs.writeFileSync(live, info.text); }
  if (arm === 'without') fs.rmSync(live, { force: true });
  git(copy, 'add', '-A');
  git(copy, '-c', 'user.name=trial', '-c', 'user.email=trial@example.invalid', 'commit', '-qm', `arm ${arm}`, '--allow-empty');
}

function session(cwd, prompt, tools) {
  const stub = process.env.SECOND_BRAIN_TRIAL_CLAUDE; // the self-test's stand-in for claude
  const [cmd, args] = stub ? [process.execPath, [stub, ...childArgs(prompt, tools)]] : ['claude', childArgs(prompt, tools)];
  return new Promise((done) => {
    const c = spawn(cmd, args, { cwd, env: childEnv(), stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    const stop = setTimeout(() => c.kill(), 900_000);
    c.stdout.on('data', (d) => { out += d; });
    c.on('error', () => {});
    c.on('close', () => { clearTimeout(stop); done(out); });
  });
}

function load(root, name) {
  if (!/^[\w.-]+$/.test(name)) throw new Error(`a name of letters, digits, dots and dashes: ${name}`);
  const file = casesFile(root, name);
  let spec;
  try { spec = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new Error(`no readable case file at ${path.relative(root, file).split(path.sep).join('/')}`); }
  const errs = validate(root, spec);
  if (errs.length) throw new Error(`the case file needs: ${errs.join('; ')}`);
  return { spec, info: describe(root, spec.artifact), runs: Math.min(3, Math.max(1, Number(spec.runs) || 1)), arms: ['with', spec.old ? 'old' : 'without'] };
}

export function plan(root, name) {
  const { spec, info, runs, arms } = load(root, name);
  const n = spec.cases.length * runs * arms.length;
  return [`Trial of ${spec.artifact} (${info.kind}${info.name ? ` "${info.name}"` : ''}): arms ${arms.join(' and ')}.`,
    `Each case runs ${runs} time(s) per arm, each in a scratch copy of this repo outside it, as claude -p with acceptEdits, every hook off, no MCP server, and only the tools listed: ${n} sessions, each one costs usage.`,
    ...spec.cases.map((c) => `- case ${c.id} (${c.use === false ? 'should not be used' : 'should be used'})\n  prompt: ${c.prompt}\n  expect: ${c.expect}\n  tools: ${(c.tools ?? []).join(', ') || 'none beyond reading and editing files'}`)].join('\n');
}

export async function run(root, name, data, concurrency = 2) {
  const { spec, info, runs, arms } = load(root, name);
  const base = path.join(path.resolve(data), 'trial', `${name}-${Date.now()}`);
  if (inRepo(root, base)) throw new Error('the data folder lies inside the repo; the trial runs only outside it');
  // the copies go under the system's temporary folder: Claude Code guards its own configuration folder, where the
  // plugin's data folder lies, so a session there could edit nothing (the fourth attempt), and the repo is never used
  const copies = fs.mkdtempSync(path.join(os.tmpdir(), 'second-brain-trial-'));
  const real = (p) => fs.realpathSync.native(p);
  const within = (dir, p) => { try { const r = path.relative(real(dir), real(p)); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)); } catch { return false; } };
  if (inRepo(root, copies) || within(configDir(), copies)) { fs.rmSync(copies, { recursive: true, force: true }); throw new Error("the temporary folder lies inside the repo or Claude Code's configuration folder"); }
  const jobs = arms.flatMap((arm) => spec.cases.flatMap((c) => Array.from({ length: runs }, (_, r) => ({ arm, c, r }))));
  const order = jobs.map((_, i) => i);
  for (let k = order.length - 1; k > 0; k--) { const j = crypto.randomInt(k + 1); [order[k], order[j]] = [order[j], order[k]]; }
  const ids = order.map((i, k) => ({ i, id: `R${k + 1}` }));
  fs.mkdirSync(path.join(base, 'records'), { recursive: true });
  const key = {};
  const records = [];
  let next = 0;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (next < ids.length) {
      const { i, id } = ids[next++];
      const { arm, c } = jobs[i];
      const copy = path.join(copies, id);
      copyRepo(root, copy);
      place(copy, spec.artifact, info, arm);
      const s = readStream(await session(copy, c.prompt, c.tools ?? []));
      const changed = git(copy, 'status', '--porcelain').stdout.trim();
      git(copy, 'add', '-A');
      const diff = git(copy, 'diff', '--cached', '--no-color').stdout;
      const rec = { id, case: c.id, prompt: c.prompt, expect: c.expect, finished: s.ok, reply: s.reply.slice(0, 2000), changed, diff: diff.length > 6000 ? `${diff.slice(0, 6000)}\n(cut at 6,000 characters)` : diff };
      fs.writeFileSync(path.join(base, 'records', `${id}.json`), JSON.stringify(rec, null, 1));
      records.push(rec);
      key[id] = { arm, case: c.id, use: c.use !== false, used: usedIn(s.tools, info.kind, info.name) };
      fs.rmSync(copy, { recursive: true, force: true }); // (v)
    }
  }));
  fs.rmSync(copies, { recursive: true, force: true });
  fs.writeFileSync(path.join(base, 'key.json'), JSON.stringify({ artifact: spec.artifact, kind: info.kind, name: info.name, arms, runs: key }, null, 1));
  records.sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)));
  return { run: path.basename(base), key: path.join(base, 'key.json'), records, sessions: ids.length };
}

// the counts, from the grader's PASS and FAIL per record joined to the key, which only this script reads, so Claude
// sees the arms only after grading and never opens a file outside the repo
export function score(data, runId, grades) {
  if (!/^[\w.-]+-\d+$/.test(String(runId))) throw new Error(`not a trial run: ${runId}`);
  const k = JSON.parse(fs.readFileSync(path.join(path.resolve(data), 'trial', runId, 'key.json'), 'utf8'));
  const g = Object.fromEntries([...String(grades).matchAll(/\b(R\d+)\s*[:|]?\s*(PASS|FAIL)\b/gi)].map((m) => [m[1].toUpperCase(), m[2].toUpperCase()]));
  const [armA, armB] = k.arms;
  const cases = [...new Set(Object.values(k.runs).map((r) => r.case))];
  const rows = cases.map((c) => {
    const of = (arm) => Object.entries(k.runs).filter(([, r]) => r.case === c && r.arm === arm);
    const pass = (arm) => of(arm).filter(([id]) => g[id] === 'PASS').length;
    const used = (arm) => (k.kind === 'rule' ? '-' : `${of(arm).filter(([, r]) => r.used).length}/${of(arm).length}`);
    const use = of(armA)[0]?.[1].use !== false;
    return { c, use, a: pass(armA), b: pass(armB), n: of(armA).length, ua: used(armA), ub: used(armB) };
  });
  const missing = Object.keys(k.runs).filter((id) => !g[id]);
  const useRows = rows.filter((r) => r.use);
  const a = useRows.reduce((s, r) => s + r.a, 0), b = useRows.reduce((s, r) => s + r.b, 0);
  const broad = k.kind !== 'rule' && rows.some((r) => !r.use && !r.ua.startsWith('0/'));
  return [`Trial of ${k.artifact}: passes with "${armA}" against "${armB}", per case.`,
    `| case | should use it | ${armA} | ${armB} | used, ${armA} | used, ${armB} |`, '| --- | --- | --- | --- | --- | --- |',
    ...rows.map((r) => `| ${r.c} | ${r.use ? 'yes' : 'no'} | ${r.a} of ${r.n} | ${r.b} of ${r.n} | ${r.ua} | ${r.ub} |`),
    missing.length ? `Not graded: ${missing.join(', ')}.` : 'Every record was graded.',
    a > b ? `It helps on these cases: ${a} passes with it, ${b} ${armB === 'old' ? 'with the old version' : 'without it'}.`
      : `It adds nothing here: ${a} passes with it, ${b} ${armB === 'old' ? 'with the old version' : 'without it'}. Retiring it is an option.`,
    ...(broad ? ['It was used on a case where it should not be: its description is too broad.'] : [])].join('\n');
}

// the made artifact, staged by Claude in .project-map/drafts/<name>/ (a folder Claude Code does not guard), moved into
// .claude/ as an inert draft, as the dream's finish writes its drafts: never over a file, never through a path that
// leaves the repo, only with the front matter it needs, and never holding private data (D31's scan)
const HOME = { skill: (n) => [`.claude/skills/${n}/SKILL.md.draft`, 'SKILL.md'], agent: (n) => [`.claude/agents/${n}.md.draft`, 'agent.md'], rule: (n) => [`.claude/rules/${n}.md.draft`, 'rule.md'] };
export function draft(root, name, kind) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(String(name))) throw new Error(`a name of lowercase letters, digits and dashes: ${name}`);
  if (!HOME[kind]) throw new Error('the kind is skill, agent or rule');
  const src = path.join(root, MAP, 'drafts', name);
  const [target, main] = HOME[kind](name);
  const text = fs.existsSync(path.join(src, main)) ? fs.readFileSync(path.join(src, main), 'utf8') : null;
  if (text === null) throw new Error(`no ${MAP}/drafts/${name}/${main}`);
  const fm = text.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1] ?? '';
  const need = kind === 'rule' ? ['paths'] : ['name', 'description'];
  for (const k of need) if (!new RegExp(`^${k}:\\s*\\S`, 'm').test(fm)) throw new Error(`the front matter needs ${k}`);
  const files = [[path.join(src, main), target], ...(kind === 'skill' ? fs.readdirSync(src).filter((f) => f !== main) : [])
    .map((f) => [path.join(src, f), `.claude/skills/${name}/${f}`])];
  for (const [from, to] of files) {
    if (!fs.lstatSync(from).isFile()) throw new Error(`not a plain file: ${path.basename(from)}`);
    if (PRIVATE.test(fs.readFileSync(from, 'utf8'))) throw new Error(`${path.basename(from)} holds private data`);
    if (!inRepo(root, path.join(root, to))) throw new Error(`${to} resolves outside the repo`);
    if (fs.existsSync(path.join(root, to))) throw new Error(`${to} exists; nothing is overwritten`);
  }
  for (const [from, to] of files) {
    fs.mkdirSync(path.dirname(path.join(root, to)), { recursive: true });
    fs.writeFileSync(path.join(root, to), fs.readFileSync(from), { flag: 'wx' });
  }
  fs.rmSync(src, { recursive: true, force: true });
  return files.map(([, to]) => to);
}

if (path.basename(process.argv[1] ?? '') === 'trial.mjs') {
  const [cmd, name, data, grades] = process.argv.slice(2);
  const root = toplevel(process.cwd());
  try {
    if (cmd === 'plan') console.log(plan(root, name));
    else if (cmd === 'run') {
      if (!data) throw new Error('the plugin data folder is needed');
      const r = await run(root, name, data);
      console.log([`The trial ran ${r.sessions} sessions. Run: ${r.run}`,
        'Grade each record below against its expect, blind to the arm; then score this run with the grades.',
        ...r.records.map((x) => `=== ${x.id} ===\n${JSON.stringify(x)}`)].join('\n'));
    } else if (cmd === 'score') console.log(score(data, name, grades));
    else if (cmd === 'draft') console.log(`Written, as drafts: ${draft(root, name, data).join(', ')}`);
    else throw new Error('use: trial.mjs plan <name> | run <name> <data folder> | score <run> <data folder> "<grades>" | draft <name> <skill|agent|rule>');
  } catch (e) {
    console.log(`The trial stopped: ${e.message}`);
    process.exitCode = 1;
  }
}
