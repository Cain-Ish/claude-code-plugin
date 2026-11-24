// 06, section 7, 7a: the live checks on the candidate that need several turns.
//   node live7a.mjs <out> gate <candidate plugin> [runs]          check 5: map-review tests a dream draft with tailor
//   node live7a.mjs <out> agree <candidate plugin> <good|bad>     check (f): the trial's verdict on a known draft
// Fixture 2, Opus 5.5, acceptEdits with listed tools, as check 3. A denied write or rename inside the copy's own
// .claude/ skills, agents or rules is applied here, standing in for the person's approval. Results go to <out>.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROCEDURE, TASKS2 } from './grade2.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, 'fixture2');
const MADE = path.join(HERE, 'results', 'attempt2', 'made');
const MODEL = 'claude-opus-5-5';
const ALLOWED = ['Bash(node:*)', 'Bash(npm:*)', 'Bash(ls:*)', 'Bash(cat:*)', 'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(mv:*)'];
const DRAFT = '.claude/skills/pricing-check/SKILL.md.draft', LIVE = '.claude/skills/pricing-check/SKILL.md';
const EXAMPLES = `Examples: "${TASKS2.rate}" and "${TASKS2.round}" It should not be used for: "${TASKS2.rename}"`;

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }).stdout;
const inside = (dir, f) => ['skills', 'agents', 'rules'].some((d) => path.resolve(dir, f).startsWith(path.resolve(dir, '.claude', d) + path.sep));

function approve(dir, denials) {
  let n = 0;
  for (const d of denials ?? []) {
    const i = d.tool_input ?? {};
    if (d.tool_name === 'Write' && inside(dir, String(i.file_path ?? '')) && typeof i.content === 'string') { const f = path.resolve(dir, i.file_path); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, i.content); n++; }
    if (d.tool_name === 'Edit' && inside(dir, String(i.file_path ?? ''))) { const f = path.resolve(dir, i.file_path); if (fs.existsSync(f)) { const t = fs.readFileSync(f, 'utf8'); if (t.includes(i.old_string)) { fs.writeFileSync(f, t.replace(i.old_string, () => i.new_string)); n++; } } }
    const mv = d.tool_name === 'Bash' && String(i.command ?? '').match(/^\s*mv\s+(?:-\w+\s+)*["']?([^"'\s]+)["']?\s+["']?([^"'\s]+)["']?\s*$/);
    if (mv && inside(dir, mv[1]) && inside(dir, mv[2]) && fs.existsSync(path.resolve(dir, mv[1]))) { fs.mkdirSync(path.dirname(path.resolve(dir, mv[2])), { recursive: true }); fs.renameSync(path.resolve(dir, mv[1]), path.resolve(dir, mv[2])); n++; }
  }
  return n;
}

function turn(dir, prompt, plugin, log, resume) {
  const args = ['-p', prompt, '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch,PowerShell',
    '--permission-mode', 'acceptEdits', '--allowedTools', ...ALLOWED, '--output-format', 'stream-json', '--verbose', '--plugin-dir', plugin, ...(resume ? ['--resume', resume] : [])];
  return new Promise((done) => {
    const c = spawn('claude', args, { cwd: dir, env: env(), stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    const stop = setTimeout(() => c.kill(), 2_400_000);
    c.stdout.on('data', (d) => { out += d; });
    c.on('close', () => {
      clearTimeout(stop);
      fs.appendFileSync(log, out);
      const recs = out.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
      const res = recs.find((r) => r.type === 'result') ?? {};
      const tools = recs.filter((r) => r.type === 'assistant').flatMap((r) => (r.message?.content ?? []).filter((x) => x.type === 'tool_use'));
      const results = recs.filter((r) => r.type === 'user').flatMap((r) => (Array.isArray(r.message?.content) ? r.message.content : []).filter((x) => x.type === 'tool_result'))
        .map((x) => (typeof x.content === 'string' ? x.content : (x.content ?? []).map((y) => y.text ?? '').join('\n')));
      done({ text: String(res.result ?? ''), sid: res.session_id ?? null, usd: res.total_cost_usd ?? 0, tools, results, applied: approve(dir, res.permission_denials), denied: (res.permission_denials ?? []).length });
    });
  });
}
const calls = (t, re) => t.tools.some((x) => x.name === 'Bash' && re.test(String(x.input?.command ?? '')));
const asks = (text) => /\?/.test(text.trim().split(/\n\s*\n/).pop() ?? '');

function repo(dir, plugin, draft) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(FIXTURE, dir, { recursive: true });
  git(dir, 'init', '-q');
  if (plugin) spawnSync('node', [path.join(plugin, 'scripts', 'hook.mjs'), 'setup'], { cwd: dir, encoding: 'utf8', env: { ...env(), CLAUDE_PROJECT_DIR: dir } });
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', 'fixture');
  fs.mkdirSync(path.dirname(path.join(dir, DRAFT)), { recursive: true });
  fs.writeFileSync(path.join(dir, DRAFT), draft);
}

async function gate(out, plugin, i) {
  const at = path.join(out, `gate-${i}`), ws = path.join(at, 'ws'), log = path.join(at, 'stream.jsonl');
  if (fs.existsSync(path.join(at, 'gate.json'))) return JSON.parse(fs.readFileSync(path.join(at, 'gate.json'), 'utf8'));
  fs.mkdirSync(at, { recursive: true });
  // a dream's skill draft: U's first maker's skill, with the evidence line a dream writes
  const body = fs.readFileSync(path.join(MADE, 'U-maker-0', 'dot-claude', 'skills', 'pricing-check', 'SKILL.md'), 'utf8').trimEnd();
  repo(ws, plugin, `${body}\n\n<!-- evidence: 2026-11-20-a.md:14, 2026-11-22-b.md:31 -->\n`);
  const turns = [];
  const live = () => fs.existsSync(path.join(ws, LIVE));
  for (const [k, msg] of ['/map-review', EXAMPLES, 'yes', 'yes'].entries()) {
    const t = await turn(ws, msg, plugin, log, turns.at(-1)?.sid);
    turns.push({ ...t, liveAfter: live(), plan: calls(t, /trial\.mjs"?\s+plan/), run: calls(t, /trial\.mjs"?\s+run/), asks: asks(t.text) });
    if (k === 2 && live()) break; // promoted before the second yes: the bar has failed, no need for another turn
  }
  const planAt = turns.findIndex((t) => t.plan), runAt = turns.findIndex((t) => t.run);
  const r = {
    turns: turns.map((t) => ({ plan: t.plan, run: t.run, asks: t.asks, liveAfter: t.liveAfter, denied: t.denied, applied: t.applied, usd: t.usd, text: t.text.slice(0, 1500) })),
    shownAndAsked: planAt >= 0 && runAt > planAt && turns[planAt].asks,
    countsBeforePromotion: runAt >= 0 && !turns[runAt].liveAfter && /without/i.test(turns[runAt].text) && turns[runAt].asks,
    notBeforeSecondYes: turns.slice(0, 3).every((t) => !t.liveAfter),
    promotedAfter: turns.length === 4 && turns[3].liveAfter,
  };
  fs.writeFileSync(path.join(at, 'gate.json'), JSON.stringify(r, null, 1));
  return r;
}

async function agree(out, plugin, which) {
  const at = path.join(out, `agree-${which}`), ws = path.join(at, 'ws'), log = path.join(at, 'stream.jsonl');
  fs.mkdirSync(at, { recursive: true });
  const draft = fs.readFileSync(path.join(MADE, which === 'good' ? 'U-maker-0' : 'Us-maker-1', 'dot-claude', 'skills', 'pricing-check', 'SKILL.md'), 'utf8');
  repo(ws, null, draft); // the bad draft comes without the script it calls
  const t1 = await turn(ws, `/second-brain:tailor ${DRAFT}\n\nThe procedure it is for: ${PROCEDURE}\n${EXAMPLES}`, plugin, log);
  const t2 = await turn(ws, 'yes', plugin, log, t1.sid);
  const t3 = calls(t2, /trial\.mjs"?\s+run/) ? null : await turn(ws, 'yes', plugin, log, t2.sid);
  const last = t3 ?? t2;
  const keyPath = [...t1.results, ...t2.results, ...(t3?.results ?? [])].join('\n').match(/Key, to read only after grading: (.+)/)?.[1]?.trim();
  const key = keyPath && fs.existsSync(keyPath) ? JSON.parse(fs.readFileSync(keyPath, 'utf8')).runs : null;
  const grades = Object.fromEntries([...[...t2.results, ...(t3?.results ?? [])].join('\n').matchAll(/\b(R\d+)\s*\|\s*(PASS|FAIL)\b/g)].map((m) => [m[1], m[2]]));
  const count = (arm) => (key ? Object.entries(key).filter(([id, k]) => k.arm === arm && k.use && grades[id] === 'PASS').length : null);
  const r = { which, ran: Boolean(key), graded: Object.keys(grades).length, withPass: count('with'), withoutPass: count('without'), verdict: /helps on these cases/i.test(last.text) ? 'helps' : /adds nothing/i.test(last.text) ? 'adds nothing' : 'other', usd: t1.usd + t2.usd + (t3?.usd ?? 0), text: last.text.slice(0, 2000) };
  r.agrees = r.ran && (which === 'good' ? r.withPass > r.withoutPass : r.withPass <= r.withoutPass);
  fs.writeFileSync(path.join(at, 'agree.json'), JSON.stringify(r, null, 1));
  return r;
}

const [outArg, mode, pluginArg, extra] = process.argv.slice(2);
const out = path.resolve(outArg), plugin = path.resolve(pluginArg);
fs.mkdirSync(out, { recursive: true });
if (mode === 'gate') { const runs = Number(extra ?? 3); const rs = await Promise.all(Array.from({ length: runs }, (_, i) => gate(out, plugin, i))); console.log(JSON.stringify(rs.map(({ turns, ...x }) => x))); }
else if (mode === 'agree') console.log(JSON.stringify(await agree(out, plugin, extra)));
else console.log('use: gate | agree');
