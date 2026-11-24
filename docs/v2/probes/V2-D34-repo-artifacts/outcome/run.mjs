// 06, section 7, 7a, checks 0 and 3: maker runs and held-out runs in fresh copies of the fixture. Paths come as
// arguments, results go under <out>/<arm>/, and a run whose result file exists is skipped, so the script resumes.
//   node run.mjs <out> <arm> --plugins <dir>[,<dir>] [--held <dir>[,<dir>]] [--makers 3] [--runs 3] [-j 3]
// An arm with --makers 0 is N: the two held-out tasks, --runs times each, with no artifact.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { grade, TASKS } from './grade.mjs';
import { grade2, TASKS2, PROCEDURE } from './grade2.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// --fixture <dir> runs another fixture (a floor without the map entries, a hardened one); the default is ./fixture
const fixtureArg = process.argv.indexOf('--fixture');
const FIXTURE = fixtureArg > 0 ? path.resolve(process.argv[fixtureArg + 1]) : path.join(HERE, 'fixture');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
export const REQUEST = 'Make a skill or an agent for this repo that adds a database migration the way this project does it.';
// --suite 2 (check 0, attempt 2): fixture 2's tasks and grader; the maker's request, or with --tell the T arm's note
const SUITE2 = process.argv.includes('--suite') && process.argv[process.argv.indexOf('--suite') + 1] === '2';
const askArg = process.argv.indexOf('--ask');
const ASK = askArg > 0 ? process.argv[askArg + 1] : !SUITE2 ? REQUEST : process.argv.includes('--tell') ? `Note for this repo: ${PROCEDURE}` : `Make a skill or an agent for this repo that does our pricing check: ${PROCEDURE}`;
const HELD = SUITE2 ? ['rate', 'round'] : ['phone', 'tags'];
const SHOULD_NOT = 'rename';
const PROMPTS = SUITE2 ? TASKS2 : TASKS;

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const walk = (d, base = d) => (fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name), base) : [path.relative(base, path.join(d, e.name)).split(path.sep).join('/')])) : []);

function fresh(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(FIXTURE, dir, { recursive: true });
  git(dir, 'init', '-q');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', 'fixture');
}

// the tools every run may use without a prompt, alike in every arm; PowerShell is off so shell calls go through Bash
const ALLOWED = ['Bash(node:*)', 'Bash(npm:*)', 'Bash(ls:*)', 'Bash(cat:*)', 'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)'];

// in a maker run, a denied Write or Edit of a skill, agent, rule or command inside the copy's own .claude/ (which
// Claude Code protects even under acceptEdits) is applied here, standing in for the person who would approve the
// prompt. Settings files and everything outside those four folders are never touched
function approve(dir, denials) {
  const roots = ['skills', 'agents', 'rules', 'commands'].map((d) => path.resolve(dir, '.claude', d) + path.sep);
  let n = 0;
  for (const d of denials ?? []) {
    const i = d.tool_input ?? {};
    const f = path.resolve(dir, String(i.file_path ?? ''));
    if (!roots.some((r) => f.startsWith(r))) continue;
    if (d.tool_name === 'Write' && typeof i.content === 'string') { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, i.content); n++; }
    if (d.tool_name === 'Edit' && fs.existsSync(f) && typeof i.old_string === 'string') {
      const t = fs.readFileSync(f, 'utf8');
      if (t.includes(i.old_string)) { fs.writeFileSync(f, i.replace_all ? t.split(i.old_string).join(i.new_string) : t.replace(i.old_string, () => i.new_string)); n++; }
    }
  }
  return n;
}

// one claude -p turn; the stream is kept beside the result
function session(dir, prompt, plugins, log, resume, maker = false) {
  const args = ['-p', prompt, '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch,PowerShell',
    '--permission-mode', 'acceptEdits', '--allowedTools', ...ALLOWED, '--output-format', 'stream-json', '--verbose', ...plugins.flatMap((p) => ['--plugin-dir', p]), ...(resume ? ['--resume', resume] : [])];
  return new Promise((done) => {
    const c = spawn(CLAUDE, args, { cwd: dir, env: env(), stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    const kill = setTimeout(() => c.kill(), 1_500_000);
    c.stdout.on('data', (d) => { out += d; });
    c.stderr.on('data', () => {});
    c.on('close', () => {
      clearTimeout(kill);
      fs.appendFileSync(log, out);
      const recs = out.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
      const res = recs.find((r) => r.type === 'result') ?? {};
      const tools = recs.filter((r) => r.type === 'assistant').flatMap((r) => (r.message?.content ?? []).filter((x) => x.type === 'tool_use').map((x) => ({ name: x.name, input: x.input })));
      const applied = maker ? approve(dir, res.permission_denials) : 0;
      done({ ok: res.subtype === 'success' && !res.is_error, text: String(res.result ?? ''), sid: res.session_id ?? null, usd: res.total_cost_usd ?? 0, tools, applied, denied: (res.permission_denials ?? []).length });
    });
  });
}

const asks = (text) => /\?/.test(text.trim().split(/\n\s*\n/).pop() ?? '');
const skillCalls = (tools) => tools.filter((t) => t.name === 'Skill').map((t) => String(t.input?.skill ?? ''));
const agentCalls = (tools) => tools.filter((t) => t.name === 'Agent' || t.name === 'Task').map((t) => String(t.input?.subagent_type ?? ''));
const isArtifact = (f) => /^\.claude\/(skills|agents|rules|commands)\//.test(f) || /^CLAUDE\.md$/.test(f) || /^\.claude\/CLAUDE\.md$/.test(f);
const fm = (text, key) => (text.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'))?.[1] ?? '').trim();

// the artifacts a maker left: files under .claude/ skills, agents, rules or commands, an instruction file, and any
// new file elsewhere that one of those names by its path (a helper script), since the protocol takes an artifact from
// wherever the maker wrote it (06, 7a, check 3)
function artifacts(dir) {
  const own = [...walk(path.join(dir, '.claude')).map((f) => `.claude/${f}`), ...(fs.existsSync(path.join(dir, 'CLAUDE.md')) ? ['CLAUDE.md'] : [])].filter(isArtifact);
  const text = own.map((f) => fs.readFileSync(path.join(dir, f), 'utf8')).join('\n');
  const fixed = new Set(walk(FIXTURE));
  const named = walk(dir).filter((f) => !f.startsWith('.git/') && !f.startsWith('.claude/') && !f.startsWith('.project-map/') && !fixed.has(f) && text.includes(f));
  const files = [...own, ...named];
  const skills = [], agents = [];
  for (const f of files) {
    const text = fs.readFileSync(path.join(dir, f), 'utf8');
    const live = f.replace(/\.draft$/, '');
    let m = live.match(/^\.claude\/skills\/([^/]+)\/SKILL\.md$/);
    if (m) skills.push(fm(text, 'name') || m[1]);
    m = live.match(/^\.claude\/agents\/(?:.*\/)?([^/]+)\.md$/);
    if (m) agents.push(fm(text, 'name') || m[1]);
  }
  return { files, skills, agents };
}

async function maker(out, i, o) {
  const at = path.join(out, `maker-${i}`);
  if (fs.existsSync(path.join(at, 'maker.json'))) return JSON.parse(fs.readFileSync(path.join(at, 'maker.json'), 'utf8'));
  fs.mkdirSync(at, { recursive: true });
  const ws = path.join(at, 'ws');
  fresh(ws);
  const log = path.join(at, 'maker.jsonl');
  fs.rmSync(log, { force: true });
  const turns = [await session(ws, ASK, o.plugins, log, null, true)];
  // resumed with "yes" when the reply asks, or when a write it was denied has just been applied, at most twice
  while ((asks(turns.at(-1).text) || turns.at(-1).applied) && turns.length < 3 && turns.at(-1).sid) turns.push(await session(ws, 'yes', o.plugins, log, turns.at(-1).sid, true));
  const a = artifacts(ws);
  fs.mkdirSync(path.join(at, 'artifacts'), { recursive: true });
  for (const f of a.files) { fs.mkdirSync(path.dirname(path.join(at, 'artifacts', f)), { recursive: true }); fs.copyFileSync(path.join(ws, f), path.join(at, 'artifacts', f)); }
  const tools = turns.flatMap((t) => t.tools);
  const r = {
    turns: turns.map((t) => ({ ok: t.ok, text: t.text.slice(0, 3000), usd: t.usd, denied: t.denied, applied: t.applied })),
    artifacts: a,
    drafts: a.files.filter((f) => f.endsWith('.draft')),
    commits: Number(git(ws, 'rev-list', '--count', 'HEAD').trim()) - 1,
    skillCalls: skillCalls(tools), agentCalls: agentCalls(tools),
    migrationsTouched: walk(path.join(ws, 'db/migrations')).length - walk(path.join(FIXTURE, 'db/migrations')).length,
  };
  fs.writeFileSync(path.join(at, 'maker.json'), JSON.stringify(r, null, 1));
  return r;
}

async function held(at, task, o, made) {
  const file = path.join(at, `held-${task}.json`);
  if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  const ws = path.join(at, `ws-${task}`);
  fresh(ws);
  // suite 2 carries the maker copy's .project-map/ too, in every arm, since capture may keep what the request said
  if (SUITE2 && made?.map && fs.existsSync(made.map)) fs.cpSync(made.map, path.join(ws, '.project-map'), { recursive: true });
  if (made) for (const f of made.files) { const to = path.join(ws, f.replace(/\.draft$/, '')); fs.mkdirSync(path.dirname(to), { recursive: true }); fs.copyFileSync(path.join(at, 'artifacts', f), to); }
  const log = path.join(at, `held-${task}.jsonl`);
  fs.rmSync(log, { force: true });
  const s = await session(ws, PROMPTS[task], o.held, log);
  const sk = skillCalls(s.tools), ag = agentCalls(s.tools);
  const used = Boolean(made) && (sk.some((n) => made.skills.includes(n.split(':').pop())) || ag.some((n) => made.agents.includes(n)));
  const r = { task, ok: s.ok, used, skillCalls: sk, agentCalls: ag, usd: s.usd, text: s.text.slice(0, 1500), ...(SUITE2 ? await grade2(ws, FIXTURE, task) : grade(ws, FIXTURE, task)) };
  fs.writeFileSync(file, JSON.stringify(r, null, 1));
  return r;
}

async function pool(jobs, n) { const res = []; let k = 0; await Promise.all(Array.from({ length: n }, async () => { while (k < jobs.length) { const j = k++; res[j] = await jobs[j](); } })); return res; }

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [outArg, arm, ...rest] = process.argv.slice(2);
  const opt = (k, d) => { const i = rest.indexOf(k); return i < 0 ? d : rest[i + 1]; };
  const o = { plugins: opt('--plugins', '').split(',').filter(Boolean).map((p) => path.resolve(p)) };
  o.held = (opt('--held', '') ? opt('--held').split(',') : o.plugins).map((p) => path.resolve(p));
  const makers = Number(opt('--makers', '3')), runs = Number(opt('--runs', '3')), j = Number(opt('-j', '3'));
  const out = path.join(path.resolve(outArg), arm);
  fs.mkdirSync(out, { recursive: true });
  if (makers === 0) {
    await pool(HELD.flatMap((t) => Array.from({ length: runs }, (_, r) => () => { const at = path.join(out, `run-${r}`); fs.mkdirSync(at, { recursive: true }); return held(at, t, o, null); })), j);
  } else {
    const made = await pool(Array.from({ length: makers }, (_, i) => () => maker(out, i, o)), j);
    await pool(made.flatMap((m, i) => [...HELD, SHOULD_NOT].map((t) => () => held(path.join(out, `maker-${i}`), t, o, { ...m.artifacts, map: path.join(out, `maker-${i}`, 'ws', '.project-map') }))), j);
  }
  console.log(`${arm}: done`);
}
