// 06, section 8, 8l, check 3, C-4: a skill draft the dream made, with no case file, gets its cases through
// `/second-brain:tailor cases <path>`, then `show` and a trial; its verdict is judged as in 8e's check 3 (the trial's own
// verdict). Built from fixture8e.mjs. Each run copies one repo S7's check 2 dreamed (its fixture runs 1-5 leave a skill
// draft of the release procedure; the first three that hold one), never writing into S7's folder. The runner's commit of
// the case file and its checks stands in for the person's, as the skill asks; the trial's "! node" line is run as the
// person's ! would run it. Counts and flags only; each reply is kept in the scratch folder, never in results/.
//   C4_PLUGIN=<plugin> node c4.mjs <scratch> <S7's scratch> <k>       one run, k = 1..3
//   C4_RESULT=<name>.json node c4.mjs <scratch> summary
// The bar, fixed before any run (the brief of 2026-11-26): 3 runs, each ends with a verdict ("helps", "hurts" or "adds
// nothing"; "not judged" is none), and none promotes (the draft stays a draft, no live SKILL.md for it) or commits (no
// model session adds a commit). Recorded, not in the bar: the verdict, whether cases made a new draft, and the cases.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [scratchArg, s7Arg, kArg] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const v of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[v]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const plugin = () => path.resolve(process.env.C4_PLUGIN);
const claude = (cwd, prompt) => {
  const s = spawnSync('claude', ['-p', prompt, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
    '--permission-mode', 'acceptEdits', '--plugin-dir', plugin(), '--output-format', 'json'], { cwd, env: env(), encoding: 'utf8', timeout: 1_800_000 });
  let res = {};
  try { res = JSON.parse(s.stdout); } catch {}
  return { ok: s.status === 0 && res.is_error === false, reply: String(res.result ?? ''), costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100 };
};
const skillDrafts = (repo) => { try { return fs.readdirSync(path.join(repo, '.claude', 'skills')).filter((d) => fs.existsSync(path.join(repo, '.claude', 'skills', d, 'SKILL.md.draft'))); } catch { return []; } };
const allDrafts = (repo) => git(repo, 'status', '--porcelain', '--untracked-files=all', '-z').split('\0').filter(Boolean).map((l) => l.slice(3)).filter((f) => f.endsWith('.draft')).sort().join('\n');

async function runOne(k) {
  const s7 = path.resolve(s7Arg);
  const sources = Array.from({ length: 5 }, (_, j) => path.join(s7, `run-${j + 1}`, 'repo')).filter((r) => skillDrafts(r).length);
  const src = sources[k - 1];
  if (!src) throw new Error(`no S7 fixture run with a skill draft for run ${k}`);
  const r = path.join(scratch, `run-${k}`);
  fs.rmSync(r, { recursive: true, force: true });
  fs.cpSync(src, r, { recursive: true });
  const name = skillDrafts(r)[0];
  const rel = `.claude/skills/${name}/SKILL.md.draft`;
  const draftsBefore = allDrafts(r);
  const c0 = git(r, 'rev-list', '--count', 'HEAD').trim();
  const cases = claude(r, `/second-brain:tailor cases ${rel}`);
  fs.writeFileSync(path.join(scratch, `run-${k}.cases.txt`), cases.reply);
  const c1 = git(r, 'rev-list', '--count', 'HEAD').trim();
  const caseFile = path.join(r, '.project-map', 'evals', `${name}.json`);
  let spec = null;
  try { spec = JSON.parse(fs.readFileSync(caseFile, 'utf8')); } catch {}
  // the person's commit of the case file and its checks, as step 6 asks
  if (spec) { git(r, 'add', '--', '.project-map/evals'); git(r, 'commit', '-qm', 'the cases'); }
  const c2 = git(r, 'rev-list', '--count', 'HEAD').trim();
  const show = spec ? claude(r, `/second-brain:tailor show ${name}`) : null;
  if (show) fs.writeFileSync(path.join(scratch, `run-${k}.show.txt`), show.reply);
  const line = show ? new RegExp(`^! node "(.+)" run ${name.replace(/[.-]/g, '\\$&')} ([0-9a-f]{12})\\s*$`, 'm').exec(show.reply) : null;
  const run = line ? spawnSync('node', [line[1], 'run', name, line[2]], { cwd: r, env: env(), encoding: 'utf8', timeout: 120_000 }) : null;
  const vf = path.join(r, '.project-map', '.trial', `${name}.json`);
  const t0 = Date.now();
  while (line && !fs.existsSync(vf) && Date.now() - t0 < 7_200_000) await new Promise((ok) => setTimeout(ok, 15_000));
  const v = fs.existsSync(vf) ? JSON.parse(fs.readFileSync(vf, 'utf8')) : null;
  const res = {
    run: k, name, casesOk: cases.ok, caseFile: Boolean(spec), cases: spec?.cases?.length ?? 0, shouldNot: spec?.cases?.filter((c) => c.use === false).length ?? 0,
    newDraft: allDrafts(r) !== draftsBefore, lineShown: Boolean(line), started: /started/.test(run?.stdout ?? ''), minutes: Math.round((Date.now() - t0) / 60_000),
    verdict: v?.verdict ?? null, failed: v?.failed ?? null, trialCases: v?.cases ?? null,
    promoted: fs.existsSync(path.join(r, '.claude', 'skills', name, 'SKILL.md')) || !fs.existsSync(path.join(r, rel)),
    committed: c1 !== c0 || git(r, 'rev-list', '--count', 'HEAD').trim() !== c2,
    costUsd: Math.round(((cases.costUsd ?? 0) + (show?.costUsd ?? 0)) * 100) / 100,
  };
  res.pass = ['helps', 'hurts', 'adds nothing'].includes(res.verdict) && !res.promoted && !res.committed;
  fs.writeFileSync(path.join(scratch, `run-${k}.json`), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
}

function summary() {
  const rows = fs.readdirSync(scratch).filter((f) => /^run-[1-9]\d*\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8'))).sort((a, b) => a.run - b.run);
  const out = { runs: rows.length, verdicts: rows.map((x) => x.verdict), costUsdSessions: Math.round(rows.reduce((a, x) => a + x.costUsd, 0) * 100) / 100, rows };
  out.pass = { all: rows.length === 3 && rows.every((x) => x.pass) };
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.C4_RESULT ?? 'c4.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

if (s7Arg === 'summary') summary();
else await runOne(Number(kArg));
