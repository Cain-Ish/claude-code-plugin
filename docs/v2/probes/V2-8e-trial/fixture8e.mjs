// 06, section 8, 8e, check 3 (as amended after the reviews): real trials through the shipped skill, on the pricing
// fixture. Each run builds its own repo from fixture/ (committed with both case files and the checks), places one
// fixed draft uncommitted (good or bad skill, or the good agent), types "/second-brain:tailor show <name>" in a
// headless session with the candidate plugin, then runs the "! node … run" line it printed, as the person's own !
// would, and waits for the verdict file. Counts only.
//   S8E_PLUGIN=<plugin> node fixture8e.mjs <scratch> pilot              the "without" arm only, 2 runs per case
//   S8E_PLUGIN=<plugin> node fixture8e.mjs <scratch> trial <good|bad|agent> <k>
//   S8E_RESULT=<name>.json node fixture8e.mjs <scratch> summary
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [scratchArg, mode, kind, k] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const plugin = process.env.S8E_PLUGIN ? path.resolve(process.env.S8E_PLUGIN) : null;
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const v of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[v]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
// each draft: its file here, where it goes, and the case file that tests it
const DRAFTS = {
  good: ['good.SKILL.md', '.claude/skills/pricing-report/SKILL.md.draft', 'pricing-report'],
  bad: ['bad.SKILL.md', '.claude/skills/pricing-report/SKILL.md.draft', 'pricing-report'],
  agent: ['good-agent.md', '.claude/agents/pricing-reporter.md.draft', 'pricing-reporter'],
};

function repoFor(name, draft) {
  const r = path.join(scratch, name);
  fs.rmSync(r, { recursive: true, force: true });
  fs.cpSync(path.join(HERE, 'fixture'), r, { recursive: true });
  git(r, 'init', '-q');
  git(r, 'add', '-A');
  git(r, 'commit', '-qm', 'the fixture');
  const [from, to] = DRAFTS[draft];
  fs.mkdirSync(path.dirname(path.join(r, to)), { recursive: true });
  fs.writeFileSync(path.join(r, to), fs.readFileSync(path.join(HERE, from)));
  return r;
}
const claude = (cwd, prompt) => spawnSync('claude', ['-p', prompt, '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', 'acceptEdits', '--plugin-dir', plugin, '--output-format', 'json'], { cwd, env: env(), encoding: 'utf8', timeout: 600_000 });

// the "without" arm of both case files, 2 runs per case, as the trial runs it
async function pilot() {
  const T = await import(pathToFileURL(path.join(plugin, 'scripts', 'trial.mjs')).href);
  const out = {};
  let failed = 0;
  for (const draft of ['good', 'agent']) {
    const r = repoFor(`pilot-${draft}`, draft);
    const name = DRAFTS[draft][2];
    const spec = JSON.parse(fs.readFileSync(path.join(r, '.project-map', 'evals', `${name}.json`), 'utf8'));
    const commit = git(r, 'rev-parse', 'HEAD').trim();
    const info = T.describe(r, commit, spec.artifact);
    for (const c of spec.cases) {
      const key = `${name}/${c.id}`;
      out[key] = 0;
      for (let i = 0; i < 2; i++) {
        const copy = path.join(scratch, `pilot-copy-${draft}-${c.id}-${i}`);
        fs.rmSync(copy, { recursive: true, force: true });
        T.copyHead(r, commit, copy);
        T.place(copy, info, 'without');
        const s = spawnSync('claude', T.childArgs(c.prompt, c.tools ?? T.DEFAULT_TOOLS), { cwd: copy, env: T.childEnv(), encoding: 'utf8', timeout: 900_000 });
        let res = null;
        try { res = JSON.parse(s.stdout); } catch {}
        if (!(s.status === 0 && res?.is_error === false)) failed++;
        out[key] += spawnSync(process.execPath, [path.join(r, c.check)], { cwd: copy, timeout: 120_000 }).status === 0 ? 1 : 0;
        fs.rmSync(copy, { recursive: true, force: true });
      }
    }
  }
  // 06, 8e, check 3: the fixture is void when "without" passes more than 1 of 2 on any case where it should be used
  const cases = (name) => JSON.parse(fs.readFileSync(path.join(HERE, 'fixture', '.project-map', 'evals', `${name}.json`), 'utf8')).cases;
  const res = { without: out, failedSessions: failed, void: ['pricing-report', 'pricing-reporter'].some((n) => cases(n).some((c) => c.use !== false && out[`${n}/${c.id}`] > 1)) };
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.S8E_PILOT ?? 'check3-pilot2.json'), `${JSON.stringify(res, null, 1)}\n`);
  console.log(JSON.stringify(res));
}

async function trial(draft, n) {
  const name = DRAFTS[draft][2];
  const r = repoFor(`${draft}-${n}`, draft);
  const show = claude(r, `/second-brain:tailor show ${name}`);
  let text = '';
  try { text = JSON.parse(show.stdout).result ?? ''; } catch {}
  // the line show printed, which the person types with Claude Code's !; run here as that ! would run it
  const line = new RegExp(`^! node "(.+)" run ${name.replace(/[.-]/g, '\\$&')} ([0-9a-f]{12})\\s*$`, 'm').exec(text);
  const run = line ? spawnSync('node', [line[1], 'run', name, line[2]], { cwd: r, env: env(), encoding: 'utf8', timeout: 120_000 }) : null;
  const vf = path.join(r, '.project-map', '.trial', `${name}.json`);
  const t0 = Date.now();
  while (line && !fs.existsSync(vf) && Date.now() - t0 < 7_200_000) await new Promise((ok) => setTimeout(ok, 15_000));
  const v = fs.existsSync(vf) ? JSON.parse(fs.readFileSync(vf, 'utf8')) : null;
  const res = { draft, n, lineShown: Boolean(line), started: /started/.test(run?.stdout ?? ''), minutes: Math.round((Date.now() - t0) / 60_000), verdict: v?.verdict ?? null, failed: v?.failed ?? null, cases: v?.cases ?? null };
  fs.writeFileSync(path.join(scratch, `trial-${draft}-${n}.json`), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
}

function summary() {
  const rows = fs.readdirSync(scratch).filter((f) => /^trial-(good|bad|agent)-[1-9]\d*\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8')));
  const of = (d) => rows.filter((x) => x.draft === d);
  // 06, 8e, check 3's bars, fixed before any run: the good skill and the good agent help, and the bad skill hurts or
  // adds nothing, each in 2 of 2
  const out = { good: of('good').map((x) => x.verdict), bad: of('bad').map((x) => x.verdict), agent: of('agent').map((x) => x.verdict), rows };
  out.pass = {
    good: of('good').length === 2 && of('good').every((x) => x.verdict === 'helps'),
    bad: of('bad').length === 2 && of('bad').every((x) => ['hurts', 'adds nothing'].includes(x.verdict)),
    agent: of('agent').length === 2 && of('agent').every((x) => x.verdict === 'helps'),
  };
  out.pass.all = out.pass.good && out.pass.bad && out.pass.agent;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.S8E_RESULT ?? 'check3.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

if (mode === 'pilot') await pilot();
else if (mode === 'trial') await trial(kind, k);
else if (mode === 'summary') summary();
else throw new Error('usage: node fixture8e.mjs <scratch> pilot | trial <good|bad|agent> <k> | summary');
