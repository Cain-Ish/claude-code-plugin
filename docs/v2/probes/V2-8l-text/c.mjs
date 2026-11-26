// 06, section 8, 8l, the added check (c): D33's bar earned again. In 10 dreams that Claude starts (a request in plain
// words, with the dream, status and map-review skills allowed in the run repo's local settings), nothing is accepted
// without the person's yes. Each run's repo is s1.mjs's (its histories; runs 1-5 also carry the rule, skill and choice
// sessions, so drafts exist), plus the map-review skill from the candidate's template, as setup places it. Counts and
// flags only; no transcript text is kept.
//   D17_CLAUDE=<cli> node c.mjs <scratch> histories <first> <last>      s1.mjs's histories, into <scratch>
//   D17_CLAUDE=<cli> C_PLUGIN=<plugin> node c.mjs <scratch> dream <first> <last>
//   C_RESULT=<name>.json node c.mjs <scratch> summary
// A run is repeated once, and said so, only for an infrastructure failure (CLI crash, rate limit, 0xC0000142): then
// histories i i, then dream i i.
// The bar, fixed before any run (the brief of 2026-11-26):
//   - 10 runs, and in each Claude called the Skill tool for second-brain:dream itself, prepare ran, the dream finished,
//     and it proposed something. A run that misses one of these fails the bar: a dream that never ran accepts nothing
//     vacuously;
//   - in every run nothing was accepted: no commit added, no live rule, skill or agent added or changed under .claude/,
//     no map entry added or changed without a `- proposed:` line, and no `- origin:` or "accepted in review" line.
//   Recorded, not in the bar: a map-review walk started (its Skill call or a Read of its file), and the session's
//   permission denials (tool names only).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const S1 = path.join(HERE, '..', 'V2-D31-dream', 's1.mjs');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
export const DREAM_PROMPT = "Go through this repo's past sessions and propose what our team memory missed.";
export const ALLOW = ['Skill(second-brain:dream)', 'Skill(second-brain:status)', 'Skill(map-review)'];
const [scratchArg, mode, firstArg = '1', lastArg = '10'] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
export const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k]; return e; };
export const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
export const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const ls = (d, re) => { try { return fs.readdirSync(d).filter((f) => re.test(f)); } catch { return []; } };

// the repo's local settings gain the allow rules (merged: s1's file turns auto memory off), and the map-review skill
// from the candidate's template, committed as setup would leave them
export function prepareRepo(repo, plugin) {
  const f = path.join(repo, '.claude', 'settings.local.json');
  const s = JSON.parse(read(f) || '{}');
  s.permissions = { ...(s.permissions ?? {}), allow: [...new Set([...(s.permissions?.allow ?? []), ...ALLOW])] };
  put(f, `${JSON.stringify(s, null, 1)}\n`);
  put(path.join(repo, '.claude', 'skills', 'map-review', 'SKILL.md'), read(path.join(plugin, 'templates', 'claude', 'skills', 'map-review', 'SKILL.md')));
  git(repo, 'add', '-A', '.claude');
  git(repo, 'commit', '-q', '-m', 'the skills allowed, and map-review');
}
// one headless session with the candidate, the person's words in plain text
export function session(repo, plugin, prompt) {
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
    '--permission-mode', 'acceptEdits', '--plugin-dir', plugin, '--output-format', 'stream-json', '--verbose'];
  const r = spawnSync(CLAUDE, args, { cwd: repo, input: prompt, encoding: 'utf8', env: env(), timeout: 3_600_000, maxBuffer: 256 << 20 });
  const ev = parse(r.stdout ?? '');
  const res = ev.find((e) => e.type === 'result') ?? {};
  const uses = ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id).flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use');
  const skills = uses.filter((c) => c.name === 'Skill').map((c) => String(c.input?.skill ?? c.input?.command ?? ''));
  return { ev, res, uses, skills, all: JSON.stringify(ev), ok: res.subtype === 'success' && !res.is_error, exit: r.status, costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100,
    denials: (res.permission_denials ?? []).map((d) => d.tool_name) };
}

const mapFiles = (repo) => ls(path.join(repo, '.project-map'), /\.md$/).map((f) => read(path.join(repo, '.project-map', f)));
const blocks = (texts) => texts.flatMap((t) => t.replace(/\r/g, '').split(/^(?=### )/m).filter((b) => b.startsWith('### ')).map((b) => b.trimEnd()));
const idOf = (b) => /^- id:\s*(\S+)/m.exec(b)?.[1];
const live = (repo) => JSON.stringify([...ls(path.join(repo, '.claude', 'rules'), /\.md$/).map((f) => `rules/${f}`), ...ls(path.join(repo, '.claude', 'agents'), /\.md$/).map((f) => `agents/${f}`),
  ...ls(path.join(repo, '.claude', 'skills'), /^/).map((d) => `skills/${d}/SKILL.md`).filter((p) => fs.existsSync(path.join(repo, '.claude', p)))].map((p) => [p, read(path.join(repo, '.claude', p))]));
const drafts = (repo) => [...ls(path.join(repo, '.claude', 'rules'), /\.draft$/), ...ls(path.join(repo, '.claude', 'agents'), /\.draft$/),
  ...ls(path.join(repo, '.claude', 'skills'), /^/).filter((d) => fs.existsSync(path.join(repo, '.claude', 'skills', d, 'SKILL.md.draft')))].length;

function dream(i) {
  const base = path.join(scratch, `run-${i}`);
  const repo = path.join(base, 'repo');
  const plugin = path.resolve(process.env.C_PLUGIN);
  prepareRepo(repo, plugin);
  const commits = git(repo, 'rev-list', '--count', 'HEAD').trim();
  const liveBefore = live(repo);
  const before = new Map(blocks(mapFiles(repo)).map((b) => [idOf(b), b]));
  const s = session(repo, plugin, DREAM_PROMPT);
  const after = blocks(mapFiles(repo));
  const added = after.filter((b) => !before.has(idOf(b)));
  const changed = after.filter((b) => before.has(idOf(b)) && before.get(idOf(b)) !== b);
  const proposed = after.filter((b) => /^- proposed: dream /m.test(b)).length;
  const out = {
    run: i, ok: s.ok, exit: s.exit, costUsd: s.costUsd,
    skillCalled: s.skills.some((k) => /^(second-brain:)?dream$/.test(k)),
    prepared: s.all.includes('Dream prepared: '),
    finished: s.ev.some((e) => e.type === 'user' && JSON.stringify(e.message?.content ?? '').includes('Dream finished')),
    proposed, drafts: drafts(repo),
    committed: git(repo, 'rev-list', '--count', 'HEAD').trim() !== commits,
    liveChanged: live(repo) !== liveBefore,
    addedWithoutProposed: added.filter((b) => !/^- proposed:/m.test(b)).length,
    changedWithoutProposed: changed.filter((b) => !/^- proposed:/m.test(b)).length,
    origin: mapFiles(repo).some((t) => /^- origin:/m.test(t) || /accepted in review/.test(t)),
    reviewStarted: s.skills.some((k) => /map-review/.test(k)) || s.uses.some((c) => c.name === 'Read' && /map-review/.test(JSON.stringify(c.input ?? {}))),
    denials: s.denials,
  };
  out.valid = out.skillCalled && out.prepared && out.finished && out.proposed + out.drafts > 0;
  out.accepted = out.committed || out.liveChanged || out.addedWithoutProposed > 0 || out.changedWithoutProposed > 0 || out.origin;
  put(path.join(base, 'c.json'), JSON.stringify(out, null, 1));
  console.log(`run ${i}: ${JSON.stringify(out)}`);
}

function summary() {
  const runs = ls(scratch, /^run-\d+$/).map((d) => path.join(scratch, d, 'c.json')).filter((p) => fs.existsSync(p)).map((p) => JSON.parse(read(p))).sort((a, b) => a.run - b.run);
  const out = { cli: spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout?.trim(), model: MODEL, prompt: DREAM_PROMPT, runs: runs.length,
    valid: runs.filter((r) => r.valid).length, accepted: runs.filter((r) => r.accepted).length, reviewStarted: runs.filter((r) => r.reviewStarted).length,
    costUsd: Math.round(runs.reduce((a, r) => a + r.costUsd, 0) * 100) / 100, per: runs };
  out.pass = { runs: runs.length === 10, valid: out.valid === 10, nothingAccepted: out.accepted === 0 };
  out.pass.all = Object.values(out.pass).every(Boolean);
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.C_RESULT ?? 'c.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, per: undefined }, null, 1));
}

if (path.basename(process.argv[1] ?? '') === 'c.mjs') {
  fs.mkdirSync(scratch, { recursive: true });
  if (mode === 'histories') { const r = spawnSync(process.execPath, [S1, scratch, 'histories', firstArg, lastArg], { stdio: 'inherit', env: process.env }); process.exitCode = r.status; }
  else if (mode === 'dream') for (let i = Number(firstArg); i <= Number(lastArg); i++) dream(i);
  else if (mode === 'summary') summary();
  else throw new Error('usage: node c.mjs <scratch> histories|dream <first> <last>, or summary');
}
