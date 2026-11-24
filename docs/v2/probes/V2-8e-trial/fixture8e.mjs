// 06, section 8, 8e, check 3: a real trial through the shipped skill, on the pricing fixture. Each run builds its own
// repo from fixture/ (committed with its case file and checks), places one fixed draft (good or bad) uncommitted, then
// types "/second-brain:tailor show" and the "run" line it printed, in headless sessions with the candidate plugin,
// and waits for the verdict file. Counts only.
//   S8E_PLUGIN=<plugin> node fixture8e.mjs <scratch> pilot              the "without" arm only, 2 runs per case
//   S8E_PLUGIN=<plugin> node fixture8e.mjs <scratch> trial <good|bad> <k>
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
const copyDir = (from, to) => fs.cpSync(from, to, { recursive: true });

function repoFor(name, draft) {
  const r = path.join(scratch, name);
  fs.rmSync(r, { recursive: true, force: true });
  copyDir(path.join(HERE, 'fixture'), r);
  git(r, 'init', '-q');
  git(r, 'add', '-A');
  git(r, 'commit', '-qm', 'the fixture');
  const d = path.join(r, '.claude', 'skills', 'pricing-report');
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'SKILL.md.draft'), fs.readFileSync(path.join(HERE, `${draft}.SKILL.md`)));
  return r;
}
const claude = (cwd, prompt) => spawnSync('claude', ['-p', prompt, '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', 'acceptEdits', '--plugin-dir', plugin, '--output-format', 'json'], { cwd, env: env(), encoding: 'utf8', timeout: 600_000 });

async function pilot() {
  const T = await import(pathToFileURL(path.join(plugin, 'scripts', 'trial.mjs')).href);
  const r = repoFor('pilot-repo', 'good');
  const spec = JSON.parse(fs.readFileSync(path.join(r, '.project-map', 'evals', 'pricing-report.json'), 'utf8'));
  const info = T.describe(r, spec.artifact);
  const out = {};
  for (const c of spec.cases) {
    out[c.id] = 0;
    for (let i = 0; i < 2; i++) {
      const copy = path.join(scratch, `pilot-${c.id}-${i}`);
      fs.rmSync(copy, { recursive: true, force: true });
      T.copyHead(r, copy);
      T.place(copy, info, 'without');
      spawnSync('claude', T.childArgs(c.prompt, c.tools ?? []), { cwd: copy, env: T.childEnv(), encoding: 'utf8', timeout: 900_000 });
      const ok = spawnSync(process.execPath, [path.join(r, c.check)], { cwd: copy, timeout: 120_000 }).status === 0;
      out[c.id] += ok ? 1 : 0;
      fs.rmSync(copy, { recursive: true, force: true });
    }
  }
  // 06, 8e, check 3: the fixture is void when "without" passes more than 1 of 2 on any case where it should be used
  const res = { without: out, void: spec.cases.some((c) => c.use !== false && out[c.id] > 1) };
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'check3-pilot.json'), `${JSON.stringify(res, null, 1)}\n`);
  console.log(JSON.stringify(res));
}

async function trial(draft, n) {
  const r = repoFor(`${draft}-${n}`, draft);
  const show = claude(r, '/second-brain:tailor show pricing-report');
  const hash = /tailor run pricing-report ([0-9a-f]{12})/.exec(show.stdout)?.[1];
  const run = hash ? claude(r, `/second-brain:tailor run pricing-report ${hash}`) : null;
  const vf = path.join(r, '.project-map', '.trial', 'pricing-report.json');
  const t0 = Date.now();
  while (hash && !fs.existsSync(vf) && Date.now() - t0 < 5_400_000) await new Promise((ok) => setTimeout(ok, 15_000));
  const v = fs.existsSync(vf) ? JSON.parse(fs.readFileSync(vf, 'utf8')) : null;
  const res = { draft, n, hashShown: Boolean(hash), started: /started/.test(run?.stdout ?? ''), minutes: Math.round((Date.now() - t0) / 60_000), verdict: v?.verdict ?? null, cases: v?.cases ?? null };
  fs.writeFileSync(path.join(scratch, `trial-${draft}-${n}.json`), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
}

function summary() {
  const rows = fs.readdirSync(scratch).filter((f) => /^trial-(good|bad)-\d+\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8')));
  const of = (d) => rows.filter((x) => x.draft === d);
  // 06, 8e, check 3's bars, fixed before any run: the good draft helps, and the bad one hurts or adds nothing, each in 2 of 2
  const out = { good: of('good').map((x) => x.verdict), bad: of('bad').map((x) => x.verdict), rows };
  out.pass = { good: of('good').length === 2 && of('good').every((x) => x.verdict === 'helps'), bad: of('bad').length === 2 && of('bad').every((x) => ['hurts', 'adds nothing'].includes(x.verdict)) };
  out.pass.all = out.pass.good && out.pass.bad;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.S8E_RESULT ?? 'check3.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

if (mode === 'pilot') await pilot();
else if (mode === 'trial') await trial(kind, k);
else if (mode === 'summary') summary();
else throw new Error('usage: node fixture8e.mjs <scratch> pilot | trial <good|bad> <k> | summary');
