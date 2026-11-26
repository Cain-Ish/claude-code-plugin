// 06, section 8, 8l, check 3, C-6: the typed `/second-brain:tailor make <name>` drafts and moves the draft with no
// denial of a command the plugin grants, with --setting-sources project,local. Each run builds 8e check 4's pricing fixture
// (probes/V2-D34-repo-artifacts/outcome/fixture2), asks for a survey ("Make agents for this repo.", as guard8e.mjs),
// takes the first `/second-brain:tailor make <name>` line the survey's reply asks the person to type, and types it in
// the same session resumed (a new invocation, as the person's next prompt). Counts and flags only; each reply is kept
// in the scratch folder, never in results/.
//   C6_PLUGIN=<plugin> node c6.mjs <scratch> <first> <last>      then      C6_RESULT=<name>.json node c6.mjs <scratch> summary
// The bar, fixed before any run (the brief of 2026-11-26): 3 of 3 runs where
//   - the survey's reply names a `make <name>` line;
//   - after the typed make, a new draft is under .claude/ (`*.draft`), moved there by `trial.mjs draft`, and nothing is
//     left in .project-map/drafts/;
//   - in the make session no command the plugin grants (`trial.mjs cli`, `trial.mjs draft`) is denied, and nothing is
//     committed.
// 06, 8l attempt 2, amended before its runs: attempt 1's bar failed a run on any denial; other denials (the model's own
// extra commands) are now counted and reported, not barred.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FX = path.join(HERE, '..', 'V2-D34-repo-artifacts', 'outcome', 'fixture2');
const SURVEY = 'Make agents for this repo.';
const [scratchArg, firstArg, lastArg] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const v of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[v]; return e; };
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }).stdout ?? '';
const claude = (cwd, prompt, resume) => {
  const s = spawnSync('claude', ['-p', prompt, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
    '--permission-mode', 'acceptEdits', '--plugin-dir', path.resolve(process.env.C6_PLUGIN), '--output-format', 'json', ...(resume ? ['--resume', resume] : [])], { cwd, env: env(), encoding: 'utf8', timeout: 1_800_000 });
  let res = {};
  try { res = JSON.parse(s.stdout); } catch {}
  return { exit: s.status, ok: s.status === 0 && res.is_error === false, sid: res.session_id, reply: String(res.result ?? ''), costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100,
    denials: (res.permission_denials ?? []).map((d) => d.tool_name),
    // a denied command the plugin grants: trial.mjs cli or draft (06, 8l attempt 2)
    grantedDenied: (res.permission_denials ?? []).filter((d) => /trial\.mjs"?\s+(cli|draft)\b/.test(String(d.tool_input?.command ?? ''))).length };
};

function runOne(i) {
  const r = path.join(scratch, `run-${i}`);
  fs.rmSync(r, { recursive: true, force: true });
  fs.cpSync(FX, r, { recursive: true });
  git(r, 'init', '-q');
  git(r, 'add', '-A');
  git(r, 'commit', '-qm', 'the fixture');
  const commits = git(r, 'rev-list', '--count', 'HEAD').trim();
  const survey = claude(r, `/second-brain:tailor ${SURVEY}`);
  fs.writeFileSync(path.join(scratch, `run-${i}.survey.txt`), survey.reply);
  const name = /\/second-brain:tailor make ([\w.-]+)/.exec(survey.reply)?.[1] ?? null;
  const surveyMade = git(r, 'status', '--porcelain', '--untracked-files=all').trim() !== '';
  const make = name && survey.sid ? claude(r, `/second-brain:tailor make ${name}`, survey.sid) : null;
  if (make) fs.writeFileSync(path.join(scratch, `run-${i}.make.txt`), make.reply);
  const made = git(r, 'status', '--porcelain', '--untracked-files=all', '-z').split('\0').filter(Boolean).map((l) => l.slice(3));
  const res = {
    run: i, surveyOk: survey.ok, surveyMade, name, makeOk: make?.ok ?? false,
    drafts: made.filter((f) => /^\.claude\/.*\.draft$/.test(f)),
    leftInDrafts: made.filter((f) => f.startsWith('.project-map/drafts/')).length,
    denials: make?.denials ?? null, grantedDenied: make?.grantedDenied ?? null, surveyDenials: survey.denials,
    committed: git(r, 'rev-list', '--count', 'HEAD').trim() !== commits,
    costUsd: Math.round(((survey.costUsd ?? 0) + (make?.costUsd ?? 0)) * 100) / 100,
  };
  res.pass = Boolean(name) && res.makeOk && res.drafts.length > 0 && res.leftInDrafts === 0 && res.grantedDenied === 0 && !res.committed;
  fs.writeFileSync(path.join(scratch, `run-${i}.json`), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
}

function summary() {
  const rows = fs.readdirSync(scratch).filter((f) => /^run-[1-9]\d*\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8'))).sort((a, b) => a.run - b.run);
  const out = { survey: SURVEY, runs: rows.length, passed: rows.filter((x) => x.pass).length, costUsd: Math.round(rows.reduce((a, x) => a + x.costUsd, 0) * 100) / 100, rows };
  out.pass = { all: rows.length === 3 && rows.every((x) => x.pass) };
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.C6_RESULT ?? 'c6.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

if (firstArg === 'summary') summary();
else for (let i = Number(firstArg); i <= Number(lastArg); i++) runOne(i);
