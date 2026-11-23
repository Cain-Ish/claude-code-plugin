// 06, section 5, 5a, check 2: P1 in a session. Each run: A1's fixture, setup from the arm's plugin, committed; then one
// session states a rule a tool can enforce and a procedure. Scored on the map, the reply and the files the session made.
//   D17_CLAUDE=<pinned CLI> node p1place.mjs <scratch> <candidate plugin> <control plugin> [runs]
// Writes results/p1place.json beside this file: flags per arm and run, no transcript text.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, '..', 'V2-D17-eval', 'fixture');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const PROMPT = 'Two things for this project. First: we never import lodash; use the native array and object methods. Second: our release procedure is to bump the patch version in package.json, add a CHANGELOG.md section for it, then tag vX.Y.Z. Nothing to build now.';
const [scratch, candidate, control, runsArg = '5'] = process.argv.slice(2);
const ARMS = { candidate: path.resolve(candidate), control: path.resolve(control) };
// an offer of a check for the lodash rule: a lint rule, a restricted import, a pre-commit hook or "a check"
const CHECK = /eslint|\blint\w*|no-restricted-imports|pre-commit|\bbiome\b|\ba (?:lint |ci |automated |static )?check\b/i;

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const blocks = (dir) => (fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.md')).map((f) => fs.readFileSync(path.join(dir, f), 'utf8')).join('\n') : '')
  .replace(/\r/g, '').split(/^(?=### )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b));
const quote = (b) => b.split('\n').filter((l) => l.startsWith('>')).join(' ');
const list = (dir, re) => { try { return fs.readdirSync(dir, { recursive: true }).map((f) => String(f).replace(/\\/g, '/')).filter((f) => re.test(f)); } catch { return []; } };

function run(arm, plugin, i) {
  const dir = path.join(path.resolve(scratch), `${arm}-${i}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(FIXTURE, dir, { recursive: true });
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), '{ "autoMemoryEnabled": false }\n'); // keeps the user's own memory folders out
  git(dir, 'init', '-q');
  const s = spawnSync('node', [path.join(plugin, 'scripts', 'hook.mjs'), 'setup'], { cwd: dir, encoding: 'utf8', env: { ...env(), CLAUDE_PROJECT_DIR: dir } });
  if (s.status) throw new Error(s.stderr);
  git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', 'base and setup');
  const before = { rules: list(path.join(dir, '.claude', 'rules'), /\.md$/), skills: list(path.join(dir, '.claude', 'skills'), /SKILL\.md$/) };
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'Bash,WebFetch,WebSearch,Skill', '--permission-mode', 'acceptEdits', '--output-format', 'json', '--plugin-dir', plugin];
  const r = spawnSync(CLAUDE, args, { cwd: dir, input: PROMPT, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 64 << 20 });
  let res = {};
  try { res = JSON.parse(r.stdout); } catch {}
  const valid = res.subtype === 'success' && !res.is_error && typeof res.result === 'string';
  const map = blocks(path.join(dir, '.project-map'));
  const newRules = list(path.join(dir, '.claude', 'rules'), /\.md$/).filter((f) => !before.rules.includes(f)).length;
  const newSkills = list(path.join(dir, '.claude', 'skills'), /SKILL\.md$/).filter((f) => !before.skills.includes(f)).length;
  const changed = git(dir, 'status', '--porcelain', '-uall').split('\n').filter(Boolean).map((l) => l.slice(3));
  return {
    arm, run: i, valid,
    lodashEntry: map.some((b) => /lodash/i.test(quote(b))),
    releaseEntry: map.some((b) => /changelog/i.test(quote(b)) && /\btag/i.test(quote(b))),
    checkOffered: valid && CHECK.test(res.result),
    skillOffered: valid && /\bskill\b/i.test(res.result),
    newLive: newRules + newSkills,
    changedOutsideMap: changed.filter((p) => !p.startsWith('.project-map/')).length,
    costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100,
  };
}

fs.mkdirSync(path.resolve(scratch), { recursive: true });
const out = { model: MODEL, cli: spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout.trim(), runs: [] };
for (let i = 1; i <= Number(runsArg); i++) {
  for (const [arm, plugin] of Object.entries(ARMS)) {
    const rec = run(arm, plugin, i);
    out.runs.push(rec);
    console.log(JSON.stringify(rec));
  }
}
for (const arm of Object.keys(ARMS)) {
  const rs = out.runs.filter((x) => x.arm === arm && x.valid);
  const n = (k) => rs.filter((x) => x[k]).length;
  out[arm] = { valid: rs.length, bothEntries: rs.filter((x) => x.lodashEntry && x.releaseEntry).length, checkOffered: n('checkOffered'), skillOffered: n('skillOffered'), newLive: rs.reduce((a, x) => a + x.newLive, 0) };
}
out.pass = out.candidate.bothEntries >= 4 && out.candidate.checkOffered >= 3 && out.candidate.checkOffered >= out.control.checkOffered + 2 && out.candidate.newLive === 0 && out.control.newLive === 0;
fs.writeFileSync(path.join(HERE, 'results', 'p1place.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify({ candidate: out.candidate, control: out.control, pass: out.pass }));
