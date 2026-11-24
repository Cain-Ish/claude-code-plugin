// 06, section 8, 8d, check 3: does the dream propose from use, and only where use shows a gap? One fixture repo per
// run (two packages, two repo skills), history sessions with no plugin, then one dream with the candidate, scored on
// what it leaves. Counts and flags only; no transcript text is kept.
//   D17_CLAUDE=<pinned CLI> node fixture8d.mjs <scratch> histories <first> <last>
//   D17_CLAUDE=<pinned CLI> S8D_PLUGIN=<plugin> node fixture8d.mjs <scratch> dream <first> <last>
//   S8D_RESULT=<name>.json node fixture8d.mjs <scratch> summary
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const [scratchArg, mode, firstArg = '1', lastArg = '5'] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const skill = (name, desc, body) => `---\nname: ${name}\ndescription: ${desc}\ndisable-model-invocation: true\n---\n${body}\n`;

const FILES = {
  'README.md': '# shop\n\nTwo packages: packages/api (the HTTP API) and packages/web (the views).\n',
  'packages/api/package.json': '{ "name": "api", "private": true }\n',
  'packages/api/src/errors.ts': 'export const errors: Record<string, { message: string }> = {};\n',
  'packages/api/src/log.ts': 'export const log = (m: string) => console.log(m);\n',
  'packages/web/package.json': '{ "name": "web", "private": true }\n',
  'packages/web/src/view.ts': 'export function render(name: string) { return `<p>${name}</p>`; }\n',
  'packages/web/src/log.ts': 'export const log = (m: string) => console.log(m);\n',
  'docs/api-conventions.md': '# API conventions\n\n- Endpoint paths are kebab-case.\n- Every error response carries a numeric `code` and a `message`.\n- Dates are ISO 8601 strings.\n',
  'CHANGELOG.md': '# Changelog\n\n## 1.1.0\n- Add the cart view.\n- Fix rounding of totals.\n',
  '.claude/skills/release-notes/SKILL.md': skill('release-notes', 'Writes the release notes for the next version from CHANGELOG.md. Use when asked for release notes.', 'Read CHANGELOG.md. Write the notes for the next version as three groups: Features, Fixes, Other.'),
  '.claude/skills/lint-fix/SKILL.md': skill('lint-fix', 'Trims trailing whitespace in the files changed since the last commit. Use when asked to tidy whitespace.', 'Find the files changed since the last commit. Remove trailing whitespace in each.'),
  '.project-map/decisions.md': '---\nname: decisions\ndescription: Team decisions.\n---\n### dates\n> Dates are ISO 8601 strings.\n\n- id: dates-iso\n- source: docs/api-conventions.md, 2026-11-01\n- when: ["api"]\n',
  '.project-map/dreams.md': '# Dream log\n\n',
};
// each session: a name, its prompts in turn (a later prompt resumes the session)
const SESSIONS = [
  ['A1', ['/release-notes', 'No: release notes always list breaking changes first, above every other group. Fix it.']],
  ['A2', ['/release-notes', 'Again: breaking changes come first in the release notes, before features and fixes. Please fix.']],
  ['B1', ['/lint-fix', 'Good, thank you.']],
  ['B2', ['/lint-fix', 'Fine, that is all for now.']],
  ['C1', ['Review packages/api/src/errors.ts against docs/api-conventions.md and list every convention it breaks, with the line.']],
  ['C2', ['Review packages/web/src/view.ts against docs/api-conventions.md and list every convention it breaks, with the line.']],
  ['D1', ['Add an error for an invalid email to packages/api/src/errors.ts.', 'In packages/api every error object carries a numeric code field. Add one to it.']],
  ['D2', ['Add an error for a missing name to packages/api/src/errors.ts.', 'Again: every error in packages/api carries a numeric code field. Please add it.']],
  ['E1', ['Add a log line when a view renders in packages/web/src/view.ts, and one when an error is created in packages/api/src/errors.ts.', 'Log messages in this repo are always lowercase. Fix both of them.']],
  ['E2', ['Add a startup log line in packages/api/src/log.ts and in packages/web/src/log.ts.', 'Again, log messages are lowercase everywhere in this repo. Fix them.']],
];

function session(cwd, prompt, resume) {
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'Bash,WebFetch,WebSearch',
    '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose', ...(resume ? ['--resume', resume] : [])];
  const r = spawnSync(CLAUDE, args, { cwd, input: prompt, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 256 << 20 });
  const ev = parse(r.stdout ?? '');
  const res = ev.find((e) => e.type === 'result') ?? {};
  return { sid: res.session_id ?? ev.find((e) => e.session_id)?.session_id, ok: res.subtype === 'success' && !res.is_error, edits: ev.filter((e) => e.type === 'assistant').flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use' && /^(Edit|Write|MultiEdit)$/.test(c.name)).length };
}

function histories(i) {
  const base = path.join(scratch, `run-${i}`);
  const repo = path.join(base, 'repo');
  fs.rmSync(base, { recursive: true, force: true });
  for (const [f, t] of Object.entries(FILES)) put(path.join(repo, f), t);
  git(repo, 'init', '-q');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'the fixture');
  const list = [];
  for (const [name, prompts] of SESSIONS) {
    let sid = null, ok = true, edits = 0;
    for (const p of prompts) { const r = session(repo, p, sid); sid = r.sid ?? sid; ok &&= r.ok; edits += r.edits; }
    list.push({ name, ok, edits });
  }
  // the edits the sessions made stay, as they would in a real repo; they are committed so the dream sees a clean tree
  git(repo, 'add', '-A');
  try { git(repo, 'commit', '-q', '-m', 'the sessions\' work'); } catch {}
  put(path.join(base, 'sessions.json'), JSON.stringify(list, null, 1));
  console.log(`run ${i}: ${list.map((s) => `${s.name}${s.ok ? '' : '!'}${s.edits ? `(${s.edits})` : ''}`).join(' ')}`);
}

const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const ls = (d, re) => { try { return fs.readdirSync(d).filter((f) => re.test(f)); } catch { return []; } };
const pathsOf = (t) => (/^paths:\s*(.*(?:\n[ \t]+-.*)*)/m.exec(t)?.[1] ?? '').replace(/\s+/g, ' ');
const onePackage = (p) => { const k = new Set([...p.matchAll(/packages\/(api|web)/g)].map((m) => m[1])); return k.size === 1 && !/(^|[\s"'[,])(\*\*|src)\//.test(p); };

function dream(i) {
  const base = path.join(scratch, `run-${i}`);
  const repo = path.join(base, 'repo');
  const plugin = path.resolve(process.env.S8D_PLUGIN);
  const commits = git(repo, 'rev-list', '--count', 'HEAD').trim();
  // the live files with their text, so a change draft promoted over its own file shows too (the decision-checker's finding)
  const live = () => JSON.stringify([...ls(path.join(repo, '.claude', 'rules'), /\.md$/).map((f) => `rules/${f}`), ...ls(path.join(repo, '.claude', 'agents'), /\.md$/).map((f) => `agents/${f}`),
    ...ls(path.join(repo, '.claude', 'skills'), /^/).map((d) => `skills/${d}/SKILL.md`).filter((p) => fs.existsSync(path.join(repo, '.claude', p)))].map((p) => [p, read(path.join(repo, '.claude', p))]));
  const liveBefore = live();
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
    '--permission-mode', 'acceptEdits', '--plugin-dir', plugin, '--output-format', 'stream-json', '--verbose'];
  const r = spawnSync(CLAUDE, args, { cwd: repo, input: '/second-brain:dream', encoding: 'utf8', env: env(), timeout: 3_600_000, maxBuffer: 256 << 20 });
  const ev = parse(r.stdout ?? '');
  const res = ev.find((e) => e.type === 'result') ?? {};
  const s = {
    run: i, finished: ev.some((e) => e.type === 'user' && JSON.stringify(e.message?.content ?? '').includes('Dream finished')), costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100,
    ...scored(repo),
    nothingLive: live() === liveBefore,
    nothingCommitted: git(repo, 'rev-list', '--count', 'HEAD').trim() === commits,
  };
  put(path.join(base, 'dream.json'), JSON.stringify(s, null, 1));
  console.log(`run ${i}: ${JSON.stringify(s)}`);
}
// what the dream left, as the bars read it. The pilot found the first match too literal: drafts write
// "numeric `code` field", with backticks, so the words may be parted by any non-word run
function scored(repo) {
  const rules = ls(path.join(repo, '.claude', 'rules'), /\.md\.draft$/).map((f) => read(path.join(repo, '.claude', 'rules', f)));
  const codeRules = rules.filter((t) => /numeric\W+code|code\W+field/i.test(t));
  const lowerRules = rules.filter((t) => /lowercase/i.test(t));
  return {
    a: /breaking/i.test(read(path.join(repo, '.claude', 'skills', 'release-notes', 'SKILL.md.draft'))),
    b: !fs.existsSync(path.join(repo, '.claude', 'skills', 'lint-fix', 'SKILL.md.draft')),
    // an agent draft for the review task C1 and C2 typed, as (c) names it, not any agent draft (the decision-checker's)
    c: ls(path.join(repo, '.claude', 'agents'), /\.md\.draft$/).some((f) => /review/i.test(read(path.join(repo, '.claude', 'agents', f)))),
    d: codeRules.some((t) => onePackage(pathsOf(t)) && /packages\/api/.test(pathsOf(t))),
    e: lowerRules.every((t) => !onePackage(pathsOf(t))),
    lowerRules: lowerRules.length,
  };
}
// scores a finished run again from what it left (a scorer fix after the pilot), keeping its run facts
function rescore(i) {
  const f = path.join(scratch, `run-${i}`, 'dream.json');
  const s = { ...JSON.parse(read(f)), ...scored(path.join(scratch, `run-${i}`, 'repo')) };
  put(f, JSON.stringify(s, null, 1));
  console.log(`run ${i}: ${JSON.stringify(s)}`);
}

function summary() {
  const runs = fs.readdirSync(scratch).filter((d) => /^run-\d+$/.test(d)).map((d) => path.join(scratch, d, 'dream.json')).filter((p) => fs.existsSync(p)).map((p) => JSON.parse(fs.readFileSync(p, 'utf8'))).sort((x, y) => x.run - y.run);
  const count = (k) => runs.filter((r) => r[k]).length;
  const sessions = fs.readdirSync(scratch).filter((d) => /^run-\d+$/.test(d)).map((d) => JSON.parse(read(path.join(scratch, d, 'sessions.json')) || '[]'));
  const out = { runs: runs.length, finished: count('finished'), a: count('a'), b: count('b'), c: count('c'), d: count('d'), e: count('e'), lowerRules: runs.map((r) => r.lowerRules), nothingLive: count('nothingLive'), nothingCommitted: count('nothingCommitted'),
    sessionsFailed: sessions.flat().filter((s) => !s.ok).length, costUsd: Math.round(runs.reduce((x, r) => x + r.costUsd, 0) * 100) / 100, per: runs };
  // 06, 8d, check 3's bars, fixed before any run
  out.pass = { a: out.a >= 4, b: out.b === runs.length, c: out.c >= 4, d: out.d >= 4, e: out.e === runs.length, live: out.nothingLive === runs.length, committed: out.nothingCommitted === runs.length };
  out.pass.all = Object.values(out.pass).every(Boolean) && runs.length === 5 && out.finished === 5;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.S8D_RESULT ?? 'check3.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, per: undefined }, null, 1));
}

const first = Number(firstArg), last = Number(lastArg);
if (mode === 'histories') for (let i = first; i <= last; i++) histories(i);
else if (mode === 'dream') for (let i = first; i <= last; i++) dream(i);
else if (mode === 'rescore') for (let i = first; i <= last; i++) rescore(i);
else if (mode === 'summary') summary();
else throw new Error('usage: node fixture8d.mjs <scratch> histories|dream <first> <last>, or summary');
