// 06, section 8, 8e (D34's option T, as amended after its reviews): the trial as a script. One case per registered
// item, with a stand-in for claude (trial-stub8e.mjs), run against the plugin folder given (default: this one). The
// exit code is the number of failures. The (8i-n) cases follow 8i's items, the register's fixes (06, section 8).
//   node trial8e.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const HERE = path.dirname(fileURLToPath(import.meta.url));
const TRIAL = path.join(PLUGIN, 'scripts', 'trial.mjs');
const STUB = path.join(HERE, 'trial-stub8e.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-trial8e-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
let T = null;
try { T = await import(pathToFileURL(TRIAL).href); } catch {}
const need = (id) => { if (!T) { check(id, false, 'no trial.mjs'); return false; } return true; };

// the check passes on out.txt's "pass", and only with a reduced environment: the stand-in's variable never reaches it
const CHECK = "import fs from 'node:fs';\nprocess.exit(!process.env.STUB_LOG && fs.existsSync('out.txt') &&fs.readFileSync('out.txt', 'utf8').trim() === 'pass' ? 0 : 1);\n";
// a skill whose grants are a YAML list, with a key that changes permissions, a command mid-line and a fenced one
const SKILL = '---\nname: pricing\ndescription: Prices the cart. Use when asked to price it.\nallowed-tools:\n  - Bash(node scripts/price.mjs:*)\npermissionMode: acceptEdits\n---\nPrice it: run !`node scripts/price.mjs` first.\n```!\nnode scripts/total.mjs\n```\n';
const TOOLS = ['Read', 'Edit', 'Skill'];
const spec = (artifact, extra = {}) => ({ artifact, runs: 3, cases: [
  { id: 'price-a', prompt: 'Price the cart.', tools: TOOLS, check: '.project-map/evals/checks/ok.mjs' },
  { id: 'price-b', prompt: 'Price the order.', tools: [...TOOLS, 'Bash(node scripts/price.mjs:*)'], check: '.project-map/evals/checks/ok.mjs' },
  { id: 'other', prompt: 'An unrelated task.', tools: TOOLS, use: false, check: '.project-map/evals/checks/ok.mjs' },
], ...extra });
let n = 0;
// a repo holding the artifact as given (uncommitted), a committed case file and check, and an untracked file no copy
// may carry
function repo(artifact, text, { live = null, s = spec(artifact), name = 'pricing' } = {}) {
  const r = path.join(tmp, `r${++n}`);
  const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' });
  const put = (f, t) => { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  g('config', 'core.autocrlf', 'false');
  put('README.md', '# r\n');
  if (live !== null) put(artifact.replace(/\.draft$/, ''), live);
  put('.project-map/evals/checks/ok.mjs', CHECK);
  put(`.project-map/evals/${name}.json`, JSON.stringify(s, null, 1));
  g('add', '-A');
  g('commit', '-qm', 'base');
  put(artifact, text);
  put('untracked.txt', 'not in HEAD\n');
  const head = () => g('rev-parse', 'HEAD').stdout.trim();
  return { r, g, put, head };
}
// the skill's ! block: the person's words on stdin
const cli = (r, words, env = {}) => spawnSync('node', [TRIAL, 'cli'], { cwd: r, encoding: 'utf8', input: words, env: { ...process.env, ...env } }).stdout;
const runLine = (r, name, hash, env = {}) => spawnSync('node', [TRIAL, 'run', name, hash], { cwd: r, encoding: 'utf8', env: { ...process.env, ...env } }).stdout;
const hashOf = (out) => /run pricing ([0-9a-f]{12})/.exec(out)?.[1];
const D = '.claude/skills/pricing/SKILL.md.draft';
// 8k (X-3): a session's environment is an allowlist, so the stand-in gets its variables from a file that sets them and
// loads it; they stay in the run's own environment too, where the check script must not see them
const stand = (vars) => {
  const f = path.join(tmp, `stand${++n}.mjs`);
  fs.writeFileSync(f, `Object.assign(process.env, ${JSON.stringify(vars)});\nawait import(${JSON.stringify(pathToFileURL(STUB).href)});\n`);
  return { ...vars, SECOND_BRAIN_TRIAL_CLAUDE: f };
};

// (1) the case file: every refusal, each on its own
await tryCheck('(1) case file refusals', () => {
  if (!need('(1) case file refusals')) return;
  const { r, put } = repo(D, SKILL);
  put('secret.md', 'a file outside .claude/\n');
  put('scripts/check.mjs', CHECK);
  put('.claude/SKILL.md', SKILL);
  const edit = (f) => { const s = spec(D); f(s); return s; };
  const bad = {
    unknownField: spec(D, { grader: 'x' }),
    flagTool: edit((s) => { s.cases[0].tools = ['--dangerously-skip-permissions', 'Skill']; }),
    flagPrompt: edit((s) => { s.cases[0].prompt = '--dangerously-skip-permissions'; }),
    noSkillTool: edit((s) => { s.cases[2].tools = ['Read']; }),
    defaultTools: edit((s) => { delete s.cases[0].tools; }),
    twoRuns: spec(D, { runs: 2 }),
    sixRuns: edit((s) => { s.cases[0].runs = 6; }),
    climbing: edit((s) => { s.cases[0].check = '.project-map/evals/checks/../checks/ok.mjs'; }),
    outsideChecks: edit((s) => { s.cases[0].check = 'scripts/check.mjs'; }),
    twoCases: edit((s) => { s.cases = s.cases.slice(1); }),
    noShouldNot: edit((s) => { s.cases[2].use = true; }),
    privateData: edit((s) => { s.cases[0].prompt = 'Mail bob@example.com the price.'; }),
    badArtifact: spec('.claude/../secret.md'),
    climbingArtifact: spec('.claude/skills/../SKILL.md'),
  };
  const missed = Object.entries(bad).filter(([, s]) => T.validate(r, s).length === 0).map(([k]) => k);
  const agentOk = T.validate(r, { ...spec(D), artifact: D }).length === 0;
  check('(1) case file refusals', !missed.length && agentOk, `accepted: ${missed.join(', ')}; ${JSON.stringify(T.validate(r, spec(D)))}`);
});

// (1) only what a commit has seen runs: an edited case file or check is refused; a link is refused; core.autocrlf's
// line ends are no change
await tryCheck('(1) committed, unchanged, no link', () => {
  if (!need('(1) committed, unchanged, no link')) return;
  const a = repo(D, SKILL);
  const ok = cli(a.r, 'show pricing');
  a.put('.project-map/evals/pricing.json', JSON.stringify(spec(D, { runs: 4 })));
  const edited = cli(a.r, 'show pricing');
  const b = repo(D, SKILL);
  b.put('.project-map/evals/checks/ok.mjs', 'process.exit(0);\n');
  const checkEdited = cli(b.r, 'show pricing');
  const c = repo(D, SKILL);
  c.g('config', 'core.autocrlf', 'true');
  for (const f of ['.project-map/evals/pricing.json', '.project-map/evals/checks/ok.mjs']) c.put(f, fs.readFileSync(path.join(c.r, f), 'utf8').replace(/\n/g, '\r\n'));
  const crlf = cli(c.r, 'show pricing');
  // the case file's folder made a link to the same files outside the repo
  const d = repo(D, SKILL);
  const outside = path.join(tmp, 'outside-evals');
  fs.cpSync(path.join(d.r, '.project-map', 'evals'), outside, { recursive: true });
  fs.rmSync(path.join(d.r, '.project-map', 'evals'), { recursive: true, force: true });
  fs.symlinkSync(outside, path.join(d.r, '.project-map', 'evals'), 'junction');
  const linked = cli(d.r, 'show pricing');
  // a live artifact runs as the commit holds it, so an uncommitted one is refused
  const liveRepo = repo('.claude/skills/pricing/SKILL.md', SKILL);
  const liveUncommitted = cli(liveRepo.r, 'show pricing');
  check('(1) committed, unchanged, no link', hashOf(ok) && /pricing\.json must be committed and unchanged/.test(edited) && /ok\.mjs must be committed and unchanged/.test(checkEdited) && hashOf(crlf) && /not a link/.test(linked)
    && /a live artifact runs as the commit holds it/.test(liveUncommitted), [ok, edited, checkEdited, crlf, linked, liveUncommitted].map((x) => x.slice(0, 140)).join(' | '));
});

// (2) show runs nothing, and prints the front matter (a list, a permission key), every command line, the files
// beside a skill draft and each check script; the run line is the person's own; the hash covers the draft, a file
// beside it and the commit; the skill's words never start a trial, and reach the script verbatim
await tryCheck('(2) show and the hash', () => {
  if (!need('(2) show and the hash')) return;
  const { r, put, g } = repo(D, SKILL);
  put('.claude/skills/pricing/price.mjs', 'console.log(1);\n');
  const log = path.join(tmp, 'show.log');
  const env = stand({ STUB_LOG: log });
  const out = cli(r, 'show pricing', env);
  const hash = hashOf(out);
  const wrong = runLine(r, 'pricing', '000000000000');
  const viaSkill = cli(r, `run pricing ${hash}`, env);
  const making = cli(r, "Make the team's report: reports/pricing-<YYYY-MM-DD>.txt > 100 $(echo x)");
  put('.claude/skills/pricing/price.mjs', 'console.log(2);\n');
  const helperEdited = hashOf(cli(r, 'show pricing'));
  put('.claude/skills/pricing/price.mjs', 'console.log(1);\n');
  put(D, `${SKILL}More.\n`);
  const draftEdited = hashOf(cli(r, 'show pricing'));
  const stale = runLine(r, 'pricing', hash);
  put(D, SKILL);
  g('commit', '--allow-empty', '-qm', 'another commit');
  const newCommit = hashOf(cli(r, 'show pricing'));
  check('(2) show and the hash', Boolean(hash) && out.includes('  allowed-tools:') && out.includes('    - Bash(node scripts/price.mjs:*)') && out.includes('permissionMode: acceptEdits')
    && out.includes('!`node scripts/price.mjs`') && out.includes('```!') && out.includes('.claude/skills/pricing/price.mjs') && out.includes('| process.exit(!process.env.STUB_LOG')
    && new RegExp(`^! node ".+/trial\\.mjs" run pricing ${hash}$`, 'm').test(out) && out.includes('case other (should not be used)')
    && !fs.existsSync(log) && !fs.existsSync(path.join(r, '.project-map', '.trial')) && /is not this case file and artifact/.test(wrong) && /starts only from the line/.test(viaSkill)
    && !/started/.test(viaSkill) && /^Tailor: make one/.test(making) && !fs.existsSync(path.join(r, '100'))
    && helperEdited && helperEdited !== hash && draftEdited && draftEdited !== hash && /is not this case file and artifact/.test(stale) && newCommit && newCommit !== hash,
    `${out}\n---\n${wrong}\n---\n${viaSkill}\n---\n${making}\n--- ${[hash, helperEdited, draftEdited, newCommit].join(' ')}`);
});

// (3) a copy of one commit: no history, no evals, no untracked file, no committed draft, no path a system cannot hold
// safely; each arm, for a new skill draft with a file beside it, a change, a live artifact and an agent draft; the
// same commit message in every arm; the session's flags
await tryCheck('(3) copies and arms', () => {
  if (!need('(3) copies and arms')) return;
  // a new skill draft, with a file beside it that the commit holds too
  const a = repo(D, SKILL);
  a.put('.claude/skills/pricing/price.mjs', 'console.log(1);\n');
  a.g('add', '.claude/skills/pricing/price.mjs');
  a.g('commit', '-qm', 'the helper');
  const ia = T.describe(a.r, a.head(), D);
  const at = (c, p) => fs.existsSync(path.join(c, p));
  const arm = (x, info, which) => { const c = path.join(tmp, `copy${++n}`); T.copyHead(x.r, x.head(), c); T.place(c, info, which); return c; };
  // the user's global git config signs every commit with a program that does not exist, and runs a hook that fails:
  // a copy's commits use neither
  const gdir = path.join(tmp, 'hostile');
  fs.mkdirSync(path.join(gdir, 'hooks'), { recursive: true });
  for (const h of ['pre-commit', 'post-commit']) fs.writeFileSync(path.join(gdir, 'hooks', h), `#!/bin/sh\necho ran > "${path.join(gdir, 'ran').split(path.sep).join('/')}"\nexit 1\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(gdir, 'gitconfig'), `[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = no-such-gpg-program\n[core]\n\thooksPath = ${path.join(gdir, 'hooks').split(path.sep).join('/')}\n`);
  const savedGlobal = process.env.GIT_CONFIG_GLOBAL;
  process.env.GIT_CONFIG_GLOBAL = path.join(gdir, 'gitconfig');
  let aw, ao;
  try { aw = arm(a, ia, 'with'); ao = arm(a, ia, 'without'); } finally { if (savedGlobal === undefined) delete process.env.GIT_CONFIG_GLOBAL; else process.env.GIT_CONFIG_GLOBAL = savedGlobal; }
  const msg = (c) => spawnSync('git', ['log', '-1', '--format=%s'], { cwd: c, encoding: 'utf8' }).stdout.trim();
  // a change, its draft committed too: a draft file never stays in a copy
  const b = repo(D, SKILL, { live: '---\nname: pricing\ndescription: Old.\n---\nOld.\n' });
  b.g('add', D);
  b.g('commit', '-qm', 'the draft');
  const ib = T.describe(b.r, b.head(), D);
  const bw = arm(b, ib, 'with'), bo = arm(b, ib, 'without');
  // a live artifact, and an agent draft
  const c = repo('.claude/skills/pricing/SKILL.md', SKILL);
  c.g('add', '-A');
  c.g('commit', '-qm', 'live');
  const ic = T.describe(c.r, c.head(), '.claude/skills/pricing/SKILL.md');
  const cw = arm(c, ic, 'with'), co = arm(c, ic, 'without');
  const AG = '---\nname: helper\ndescription: Helps.\ntools: Read\n---\nHelp.\n';
  const d = repo('.claude/agents/helper.md.draft', AG, { s: { ...spec('.claude/agents/helper.md.draft'), cases: spec('x').cases.map((k) => ({ ...k, tools: ['Read', 'Agent'] })) } });
  const id = T.describe(d.r, d.head(), '.claude/agents/helper.md.draft');
  const dw = arm(d, id, 'with'), dout = arm(d, id, 'without');
  // a commit holding a backslash, a colon and a .git path
  const e = repo(D, SKILL);
  const oid = spawnSync('git', ['hash-object', '-w', '--stdin'], { cwd: e.r, input: 'x\n', encoding: 'utf8' }).stdout.trim();
  const sub = spawnSync('git', ['mktree'], { cwd: e.r, input: `100644 blob ${oid}\tf.txt\n`, encoding: 'utf8' }).stdout.trim();
  const tree = spawnSync('git', ['mktree'], { cwd: e.r, input: `100644 blob ${oid}\ta\\b.txt\n100644 blob ${oid}\tc:d.txt\n040000 tree ${sub}\t.git\n100644 blob ${oid}\tok.txt\n`, encoding: 'utf8' }).stdout.trim();
  const odd = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit-tree', tree, '-m', 'odd'], { cwd: e.r, encoding: 'utf8' }).stdout.trim();
  const ce = path.join(tmp, `copy${++n}`);
  let oddErr = '';
  try { T.copyHead(e.r, odd, ce); } catch (x) { oddErr = x.message; }
  const oddFiles = fs.existsSync(ce) ? fs.readdirSync(ce).filter((f) => f !== '.git') : [];
  const args = T.childArgs('Price it.', ['Read', 'Bash(node x.mjs:*)']);
  const after = (flag) => args[args.indexOf(flag) + 1];
  // the variables that link a session to the one that started it are removed; login and configuration stay (06, 8e,
  // attempt 2), whether or not this test itself runs inside a session
  const linking = ['CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_BRIDGE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_CHILD_NOTES_DIR', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN'];
  const keep = ['CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'ANTHROPIC_API_KEY'];
  const savedEnv = Object.fromEntries([...linking, ...keep].map((k) => [k, process.env[k]]));
  for (const k of [...linking, ...keep]) process.env[k] = 'x';
  const ce2 = T.childEnv();
  const nested = linking.some((k) => k in ce2) || !keep.every((k) => ce2[k] === 'x');
  for (const [k, v] of Object.entries(savedEnv)) if (v === undefined) delete process.env[k]; else process.env[k] = v;
  const commits = spawnSync('git', ['rev-list', '--count', 'HEAD'], { cwd: aw, encoding: 'utf8' }).stdout.trim();
  const facts = {
    newWith: at(aw, '.claude/skills/pricing/SKILL.md') && at(aw, '.claude/skills/pricing/price.mjs') && !at(aw, D),
    newWithout: !at(ao, '.claude/skills/pricing'),
    history: commits === '2' && !at(aw, '.project-map/evals') && !at(aw, 'untracked.txt'),
    hostile: !fs.existsSync(path.join(gdir, 'ran')),
    sameMessage: msg(aw) === msg(ao) && msg(aw) === 'trial copy',
    changeWith: fs.readFileSync(path.join(bw, '.claude/skills/pricing/SKILL.md'), 'utf8') === SKILL && !at(bw, D),
    changeWithout: fs.readFileSync(path.join(bo, '.claude/skills/pricing/SKILL.md'), 'utf8').includes('Old.') && !at(bo, D),
    liveWith: at(cw, '.claude/skills/pricing/SKILL.md'), liveWithout: !at(co, '.claude/skills/pricing/SKILL.md'),
    agentWith: at(dw, '.claude/agents/helper.md'), agentWithout: !at(dout, '.claude/agents/helper.md') && !at(dout, '.claude/agents/helper.md.draft'),
    odd: !oddErr && JSON.stringify(oddFiles) === '["ok.txt"]' && !fs.existsSync(path.join(tmp, 'b.txt')) && !fs.existsSync(path.join(ce, '.git', 'f.txt')),
    flags: args[0] === '-p' && args[1] === 'Price it.' && after('--output-format') === 'json' && after('--permission-mode') === 'acceptEdits' && after('--setting-sources') === 'project,local'
      && args.includes('--no-session-persistence') && args.includes('--strict-mcp-config') && JSON.parse(after('--settings')).disableAllHooks === true
      && JSON.stringify(args.slice(args.indexOf('--tools') + 1, args.indexOf('--allowedTools'))) === '["Read","Bash"]' && JSON.stringify(args.slice(args.indexOf('--allowedTools') + 1)) === '["Bash(node x.mjs:*)"]',
    nested: !nested,
  };
  check('(3) copies and arms', Object.values(facts).every(Boolean), JSON.stringify({ facts, oddErr, oddFiles }));
});

// (4) the verdict rule (06, 8e, attempt 2): not judged first, then a should-not case failing with it, then each case
// better or worse by a margin of half its runs, rounded up
await tryCheck('(4) the verdict rule', () => {
  if (!need('(4) the verdict rule')) return;
  const row = (w, o, use = true, runs = 3) => ({ use, runs, with: w, without: o });
  const sup = row(3, 3, false);
  const table = [
    [[row(3, 0), row(3, 1), sup], 'helps'],
    [[row(0, 3), row(1, 1), sup], 'hurts'],
    [[row(0, 2), row(1, 1), sup], 'hurts'],
    [[row(2, 2), row(1, 1), sup], 'adds nothing'],
    [[row(3, 1), row(1, 3), sup], 'mixed'],
    [[row(3, 0), row(1, 2), sup], 'helps'],
    // attempt 1's bad trial: one pass in three is within the noise
    [[row(1, 0), row(0, 0), sup], 'adds nothing'],
    [[row(2, 0), row(0, 0), sup], 'helps'],
    [[row(2, 0, true, 5), row(0, 0, true, 5), row(5, 5, false, 5)], 'adds nothing'],
    [[row(3, 0, true, 5), row(0, 0, true, 5), row(5, 5, false, 5)], 'helps'],
    [[row(3, 0), row(3, 0), row(2, 3, false)], 'hurts'],
    [[row(3, 0), row(3, 0), row(3, 2, false)], 'not judged'],
  ];
  const got = table.map(([rows]) => T.verdict(rows));
  got.push(T.verdict([row(3, 0), row(3, 0), sup], 1));
  const want = [...table.map(([, v]) => v), 'not judged'];
  check('(4) the verdict rule', JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
});

// (5) a run end to end, through the detached start: the verdict file, git-ignored, with counts and git's blob ids; the
// sessions saw no history, no evals and no untracked file, the file beside the draft in "with", and ran with the
// flags; a session that tries to change the check scripts finds none; the temp folders are gone
await tryCheck('(5) a run end to end', async () => {
  if (!need('(5) a run end to end')) return;
  const { r, put } = repo(D, SKILL);
  put('.claude/skills/pricing/price.mjs', 'console.log(1);\n');
  const log = path.join(tmp, 'run.log');
  const env = stand({ STUB_LOG: log, STUB_LIVE: '.claude/skills/pricing/SKILL.md', STUB_HELPER: '.claude/skills/pricing/price.mjs', STUB_TOUCH_CHECKS: '1' });
  const hash = hashOf(cli(r, 'show pricing', env));
  const started = runLine(r, 'pricing', hash, env);
  const vf = path.join(r, '.project-map', '.trial', 'pricing.json');
  for (let k = 0; k < 1800 && !fs.existsSync(vf); k++) await new Promise((ok) => setTimeout(ok, 100));
  const v = fs.existsSync(vf) ? JSON.parse(fs.readFileSync(vf, 'utf8')) : {};
  const seen = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
  const blob = spawnSync('git', ['hash-object', '--', D], { cwd: r, encoding: 'utf8' }).stdout.trim();
  const a = v.cases?.find((c) => c.id === 'price-a');
  check('(5) a run end to end', /started/.test(started) && v.verdict === 'helps' && v.hash === hash && v.failed === 0 && a?.with === 3 && a?.without === 0 && v.artifactBlob === blob && /^[0-9a-f]{40}$/.test(v.casesBlob ?? '')
    && fs.readFileSync(path.join(r, '.project-map', '.trial', '.gitignore'), 'utf8') === '*\n' && seen.length === 18
    && seen.every((s) => !s.evals && !s.untracked && s.commits === '2' && s.message === 'trial copy' && s.env.CLAUDECODE === null && s.args.includes('--tools') && s.args.includes('--no-session-persistence') && s.helper === s.has)
    // 8k (B-1): the copies this run made are gone, each by the folder its session ran in; the shared temp folder's count
    // also moved with any other test running at once
    && seen.every((s) => !fs.existsSync(s.cwd)), JSON.stringify({ verdict: v.verdict, failed: v.failed, a, blobOk: v.artifactBlob === blob, seen: seen.length, bad: seen.filter((s) => s.evals || s.untracked || s.commits !== '2' || s.message !== 'trial copy').slice(0, 2), left: seen.filter((s) => fs.existsSync(s.cwd)).length }));
});

// (5) a failed session, or a stopped trial, is never a verdict; the verdict file is never written through a link
await tryCheck('(5) not judged, and no write through a link', async () => {
  if (!need('(5) not judged, and no write through a link')) return;
  const { r } = repo(D, SKILL);
  const env = stand({ STUB_LOG: path.join(tmp, 'fail.log'), STUB_LIVE: '.claude/skills/pricing/SKILL.md', STUB_FAIL: '1' });
  const hash = hashOf(cli(r, 'show pricing', env));
  // a hard link at the verdict's path, to a file outside the repo
  const outside = path.join(tmp, 'outside-verdict.json');
  fs.writeFileSync(outside, 'outside\n');
  fs.mkdirSync(path.join(r, '.project-map', '.trial'), { recursive: true });
  fs.linkSync(outside, path.join(r, '.project-map', '.trial', 'pricing.json'));
  const saved = { ...process.env };
  Object.assign(process.env, env);
  let v;
  try { v = await T.exec(r, 'pricing', hash); } finally { for (const k of Object.keys(env)) if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  const onDisk = JSON.parse(fs.readFileSync(path.join(r, '.project-map', '.trial', 'pricing.json'), 'utf8'));
  // a trial stopped before its end (here, a hash that is not the files') leaves "not judged", stopped
  const stopped = spawnSync('node', [TRIAL, 'exec', 'pricing', '000000000000'], { cwd: r, encoding: 'utf8' });
  const after = JSON.parse(fs.readFileSync(path.join(r, '.project-map', '.trial', 'pricing.json'), 'utf8'));
  // a temp folder inside the repo: no session runs there
  const inner = repo(D, SKILL);
  const innerHash = hashOf(cli(inner.r, 'show pricing'));
  const innerTmp = path.join(inner.r, 'tmp');
  fs.mkdirSync(innerTmp);
  const tmpVars = ['TEMP', 'TMP', 'TMPDIR'];
  const savedTmp = Object.fromEntries(tmpVars.map((k) => [k, process.env[k]]));
  Object.assign(process.env, env, { STUB_FAIL: '' }, Object.fromEntries(tmpVars.map((k) => [k, innerTmp])));
  let innerV;
  // no session starts at all: every one would fail here anyway, so the stand-in's log is what tells (8m's review)
  const logLines = () => (fs.existsSync(env.STUB_LOG) ? fs.readFileSync(env.STUB_LOG, 'utf8').split('\n').filter(Boolean).length : 0);
  const sessionsBefore = logLines();
  try { innerV = await T.exec(inner.r, 'pricing', innerHash); } finally {
    for (const k of Object.keys(env)) if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
    for (const k of tmpVars) if (savedTmp[k] === undefined) delete process.env[k]; else process.env[k] = savedTmp[k];
  }
  // the verdict's folder a link out of the repo, and a verdict that would hold private data: nothing is written
  const away = repo(D, SKILL);
  const awayDir = path.join(tmp, 'outside-trial');
  fs.mkdirSync(awayDir);
  fs.symlinkSync(awayDir, path.join(away.r, '.project-map', '.trial'), 'junction');
  const refused = (f) => { try { f(); return false; } catch { return true; } };
  const linkRefused = refused(() => T.record(away.r, 'pricing', { verdict: 'helps' })) && !fs.existsSync(path.join(awayDir, 'pricing.json'));
  const privateRefused = refused(() => T.record(inner.r, 'leak', { note: 'bob@example.com' })) && !fs.existsSync(path.join(inner.r, '.project-map', '.trial', 'leak.json'));
  check('(5) not judged, and no write through a link', v?.verdict === 'not judged' && v.failed === 18 && onDisk.verdict === 'not judged' && fs.readFileSync(outside, 'utf8') === 'outside\n'
    && stopped.status === 1 && after.verdict === 'not judged' && after.stopped === true && innerV?.verdict === 'not judged' && innerV.failed === 18 && logLines() === sessionsBefore && fs.readdirSync(innerTmp).length === 0
    && linkRefused && privateRefused, JSON.stringify({ v: v?.verdict, failed: v?.failed, outside: fs.readFileSync(outside, 'utf8'), after, inner: innerV?.verdict, innerFailed: innerV?.failed, linkRefused, privateRefused }));
});

// (6) the making steps' only write: refused through a link, without its front matter or with an empty field, under
// another name, over a draft or a live file, with private data
await tryCheck('(6) draft refusals', () => {
  if (!need('(6) draft refusals')) return;
  const { r, put } = repo(D, SKILL);
  put('.claude/skills/live/SKILL.md', '---\nname: live\ndescription: Live.\n---\nLive.\n');
  const stage = (name, file, text) => put(`.project-map/drafts/${name}/${file}`, text);
  const tryDraft = (name, kind) => { try { return T.draft(r, name, kind).join(','); } catch (e) { return `refused: ${e.message}`; } };
  stage('helper', 'agent.md', '---\nname: helper\ndescription: Helps.\n---\nHelp.\n');
  stage('emptytools', 'agent.md', '---\nname: emptytools\ntools:\ndescription: Empty.\n---\nE.\n');
  stage('other', 'agent.md', '---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nR.\n');
  stage('leaky', 'SKILL.md', '---\nname: leaky\ndescription: Leaks.\n---\nMail bob@example.com.\n');
  stage('pricing', 'SKILL.md', SKILL);
  stage('live', 'SKILL.md', '---\nname: live\ndescription: Live again.\n---\nAgain.\n');
  stage('good', 'SKILL.md', '---\nname: good\ndescription: Good.\n---\nGood.\n');
  stage('good', 'run.mjs', 'console.log(1);\n');
  const outside = path.join(tmp, 'outside-stage');
  fs.mkdirSync(outside, { recursive: true });
  fs.writeFileSync(path.join(outside, 'SKILL.md'), '---\nname: linked\ndescription: Linked.\n---\nLinked.\n');
  fs.symlinkSync(outside, path.join(r, '.project-map', 'drafts', 'linked'), 'junction');
  const got = Object.fromEntries([['helper', 'agent'], ['emptytools', 'agent'], ['other', 'agent'], ['leaky', 'skill'], ['pricing', 'skill'], ['live', 'skill'], ['linked', 'skill'], ['good', 'skill']].map(([k, kind]) => [k, tryDraft(k, kind)]));
  check('(6) draft refusals', /front matter needs tools/.test(got.helper) && /front matter needs tools/.test(got.emptytools) && /name must be other/.test(got.other) && /private data/.test(got.leaky) && /exists; nothing is overwritten/.test(got.pricing)
    && /exists; nothing is overwritten/.test(got.live) && /not a link/.test(got.linked) && got.good === '.claude/skills/good/SKILL.md.draft,.claude/skills/good/run.mjs', JSON.stringify(got));
});

// (7) the texts: tailor is started only by a person, passes the words by a quoted heredoc, and never runs a trial
// itself; map-review shows verdicts by blob ids, stale, not judged and untested, and offers removal on a yes; the
// dream's handoff to review is unchanged (D33)
await tryCheck('(7) texts', () => {
  const tl = fs.readFileSync(path.join(PLUGIN, 'skills', 'tailor', 'SKILL.md'), 'utf8');
  const mr = fs.readFileSync(path.join(PLUGIN, 'templates', 'claude', 'skills', 'map-review', 'SKILL.md'), 'utf8');
  const dm = fs.readFileSync(path.join(PLUGIN, 'skills', 'dream', 'SKILL.md'), 'utf8');
  check('(7) texts', /^disable-model-invocation: true$/m.test(tl) && tl.includes("```!\nnode \"${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs\" cli <<'SECOND_BRAIN_WORDS'\n$ARGUMENTS\nSECOND_BRAIN_WORDS\n```")
    && !/!`[^`]*\$ARGUMENTS/.test(tl) && tl.includes('Never run `trial.mjs` yourself except `draft`')
    // attempt 4 (the user's word): a request that names no task surveys the repo, lists gaps with evidence, and asks
    && tl.includes('**A request that names no task**') && tl.includes('**Survey, read only.**') && tl.includes('**List the gaps you found.**')
    && tl.includes('**Ask which to make, and stop.** Make nothing until the person picks one')
    && mr.includes('.project-map/.trial/<name>.json') && mr.includes('artifactBlob') && mr.includes('call it stale') && mr.includes('"Not judged"') && mr.includes('call the draft untested') && mr.includes('not stale') && mr.includes('Remove it only on')
    && dm.includes('Then ask whether to review the proposals now'), 'a text is missing');
});

// 8i: the stand-in's variables set for a run in this process, then put back
const withEnv = async (env, f) => {
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  Object.assign(process.env, env);
  try { return await f(); } finally { for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k]; else process.env[k] = v; }
};
const stubEnv = (log, more = {}) => stand({ STUB_LOG: path.join(tmp, log), STUB_LIVE: '.claude/skills/pricing/SKILL.md', ...more });
const tryDraft = (r, name, kind) => { try { return T.draft(r, name, kind).join(','); } catch (e) { return `refused: ${e.message}`; } };

// (8i-1) X-1: the main file only by its exact name (skill.md would go live beside the draft on a system that ignores
// case), and no file beside it named as the main file in any case or as a draft
await tryCheck('(8i-1) X-1: skill.md or a draft beside it', () => {
  if (!need('(8i-1) X-1: skill.md or a draft beside it')) return;
  const { r, put } = repo(D, SKILL);
  const stage = (name, file, text) => put(`.project-map/drafts/${name}/${file}`, text);
  stage('lower', 'skill.md', '---\nname: lower\ndescription: Lower.\n---\nL.\n');
  stage('beside', 'SKILL.md', '---\nname: beside\ndescription: Beside.\n---\nB.\n');
  stage('beside', 'notes.md.DRAFT', 'x\n');
  stage('twice', 'SKILL.md', '---\nname: twice\ndescription: Twice.\n---\nT.\n');
  stage('twice', 'skill.md', 'x\n');
  // on a system that keeps case, both files exist, and the second is refused by name
  const sensitive = fs.readdirSync(path.join(r, '.project-map', 'drafts', 'twice')).length === 2;
  const got = Object.fromEntries(['lower', 'beside', 'twice'].map((k) => [k, tryDraft(r, k, 'skill')]));
  check('(8i-1) X-1: skill.md or a draft beside it', /by that exact name/.test(got.lower) && /may not be named notes\.md\.DRAFT/.test(got.beside) && (!sensitive || /may not be named skill\.md/.test(got.twice))
    && !['lower', 'beside'].some((k) => fs.existsSync(path.join(r, '.claude', 'skills', k))), JSON.stringify({ got, sensitive }));
});

// (8i-2) P-1, C-3, K-2: the verdict's blob ids are of the text that ran and of the case file at the trial's commit,
// though both are edited during the run
await tryCheck('(8i-2) P-1: blob ids of what ran', async () => {
  if (!need('(8i-2) P-1: blob ids of what ran')) return;
  const { r, g } = repo(D, SKILL);
  const hash = hashOf(cli(r, 'show pricing'));
  const cases = path.join(r, '.project-map', 'evals', 'pricing.json');
  const v = await withEnv(stubEnv('edit.log', { STUB_EDIT: [path.join(r, D), cases].join(path.delimiter) }), () => T.exec(r, 'pricing', hash));
  const ran = spawnSync('git', ['hash-object', '--stdin'], { cwd: r, input: SKILL, encoding: 'utf8' }).stdout.trim();
  const atCommit = g('rev-parse', 'HEAD:.project-map/evals/pricing.json').stdout.trim();
  const edited = g('hash-object', '--', D).stdout.trim();
  check('(8i-2) P-1: blob ids of what ran', v?.verdict === 'helps' && v.artifactBlob === ran && v.casesBlob === atCommit && edited !== ran, JSON.stringify({ v: v && { verdict: v.verdict, artifactBlob: v.artifactBlob, casesBlob: v.casesBlob }, ran, atCommit, edited }));
});

// (8i-3) C-1, C-2: show prints a fenced ! block whole among the command lines, the artifact's whole text, and the text
// of each file beside it
await tryCheck('(8i-3) C-1, C-2: show prints what runs', () => {
  if (!need('(8i-3) C-1, C-2: show prints what runs')) return;
  const { r, put } = repo(D, `${SKILL}A body line.\n`);
  put('.claude/skills/pricing/price.mjs', 'console.log("the helper\'s body");\n');
  const out = cli(r, 'show pricing');
  const commands = out.split('Its command lines:\n')[1]?.split(/\n(?! )/)[0] ?? '';
  check('(8i-3) C-1, C-2: show prints what runs', commands.includes('!`node scripts/price.mjs`') && commands.includes('  ```!\n  node scripts/total.mjs\n  ```')
    && out.includes('  | A body line.') && out.includes('  | permissionMode: acceptEdits') && out.includes('  | console.log("the helper\'s body");'), out);
});

// (8i-4) C-7: a committed draft's staging folder never reaches a copy; the map's other files do
await tryCheck('(8i-4) C-7: no staging folder in a copy', () => {
  if (!need('(8i-4) C-7: no staging folder in a copy')) return;
  const a = repo(D, SKILL);
  a.put('.project-map/drafts/pricing/SKILL.md', SKILL);
  a.put('.project-map/notes.md', 'kept\n');
  a.g('add', '.project-map/drafts', '.project-map/notes.md');
  a.g('commit', '-qm', 'staged');
  const c = path.join(tmp, `copy${++n}`);
  T.copyHead(a.r, a.head(), c);
  check('(8i-4) C-7: no staging folder in a copy', !fs.existsSync(path.join(c, '.project-map', 'drafts')) && fs.existsSync(path.join(c, '.project-map', 'notes.md')), JSON.stringify(fs.readdirSync(path.join(c, '.project-map'))));
});

// (8i-5) C-8, K-7, P-15: one trial at a time per repo. While a live process holds the lock, a typed run line stops
// with a message and exec refuses; a lock left by a process that has ended is taken over, git never sees it, and it
// is gone when the verdict lands
await tryCheck('(8i-5) C-8: one trial at a time', async () => {
  if (!need('(8i-5) C-8: one trial at a time')) return;
  const { r } = repo(D, SKILL);
  const hash = hashOf(cli(r, 'show pricing'));
  const lock = path.join(r, '.project-map', '.trial', '.lock');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.writeFileSync(lock, String(process.pid));
  const env = stubEnv('lock.log', { STUB_REPO: r });
  const second = runLine(r, 'pricing', hash, env);
  let refused = '';
  try { await withEnv(env, () => T.exec(r, 'pricing', hash)); } catch (e) { refused = e.message; }
  fs.writeFileSync(lock, String(spawnSync(process.execPath, ['-e', '']).pid));
  const v = await withEnv(env, () => T.exec(r, 'pricing', hash));
  const seen = fs.readFileSync(path.join(tmp, 'lock.log'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  check('(8i-5) C-8: one trial at a time', /another trial is running/.test(second) && !/started/.test(second) && /another trial is running/.test(refused) && v?.verdict === 'helps' && !fs.existsSync(lock)
    && seen.length === 18 && seen.every((s) => s.trialSeen === false), JSON.stringify({ second, refused, verdict: v?.verdict, lock: fs.existsSync(lock), seen: seen.length, trialSeen: seen.map((s) => s.trialSeen) }));
});

// (8i-6) K-3: a copy the system will not remove (Windows, while a program the session started runs in it) is named in
// the verdict, and the trial goes on. macOS and Linux delete such a folder
await tryCheck('(8i-6) K-3: a copy that cannot be removed', async () => {
  if (process.platform !== 'win32') { console.log(`pass  (8i-6) K-3: a copy that cannot be removed (skipped on ${process.platform}: the system deletes a folder that is a working folder)`); return; }
  if (!need('(8i-6) K-3: a copy that cannot be removed')) return;
  const { r } = repo(D, SKILL);
  const hash = hashOf(cli(r, 'show pricing'));
  const held = path.join(tmp, 'holder.pid');
  let v, err = '';
  try { v = await withEnv(stubEnv('hold.log', { STUB_HOLD: held }), () => T.exec(r, 'pricing', hash)); } catch (e) { err = e.message; }
  const pid = Number(fs.existsSync(held) ? fs.readFileSync(held, 'utf8') : 0);
  if (pid) try { process.kill(pid); } catch {}
  // the system lets the folder go a moment after the program has ended
  for (const f of v?.copiesLeft ?? []) for (let k = 0; k < 100; k++) { try { fs.rmSync(path.join(os.tmpdir(), f), { recursive: true, force: true }); break; } catch { await new Promise((ok) => setTimeout(ok, 100)); } }
  check('(8i-6) K-3: a copy that cannot be removed', v?.verdict === 'helps' && v.failed === 0 && v.copiesLeft?.length === 1 && /^second-brain-trial-/.test(v.copiesLeft[0]), JSON.stringify({ err, v }));
});

// (8i-7) K-4: draft reads a YAML block list, the form Claude Code's docs show, for paths and tools; an empty item is
// still no value
await tryCheck('(8i-7) K-4: YAML block lists', () => {
  if (!need('(8i-7) K-4: YAML block lists')) return;
  const { r, put } = repo(D, SKILL);
  put('.project-map/drafts/src-rule/rule.md', '---\npaths:\n  - "src/**"\n  - "lib/**"\n---\nRule.\n');
  put('.project-map/drafts/lister/agent.md', '---\nname: lister\ndescription: Lists.\ntools:\n  - Read\n  - Grep\n---\nList.\n');
  put('.project-map/drafts/emptyitem/agent.md', '---\nname: emptyitem\ndescription: Empty.\ntools:\n  -\n---\nE.\n');
  const got = { rule: tryDraft(r, 'src-rule', 'rule'), agent: tryDraft(r, 'lister', 'agent'), empty: tryDraft(r, 'emptyitem', 'agent') };
  check('(8i-7) K-4: YAML block lists', got.rule === '.claude/rules/src-rule.md.draft' && got.agent === '.claude/agents/lister.md.draft' && /front matter needs tools/.test(got.empty), JSON.stringify(got));
});

// (8i-8) K-8: when claude cannot be started (here, no claude on the PATH), the verdict says why and names npm's
// claude.cmd on Windows
await tryCheck('(8i-8) K-8: claude cannot be started', () => {
  if (!need('(8i-8) K-8: claude cannot be started')) return;
  const { r } = repo(D, SKILL);
  const hash = hashOf(cli(r, 'show pricing'));
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(path|SECOND_BRAIN_TRIAL_CLAUDE)$/i.test(k)));
  env.PATH = (process.env.PATH ?? '').split(path.delimiter).filter((d) => d && !['claude', 'claude.exe', 'claude.cmd', 'claude.com'].some((f) => fs.existsSync(path.join(d, f)))).join(path.delimiter);
  const res = spawnSync(process.execPath, [TRIAL, 'exec', 'pricing', hash], { cwd: r, env, encoding: 'utf8' });
  const vf = path.join(r, '.project-map', '.trial', 'pricing.json');
  const v = fs.existsSync(vf) ? JSON.parse(fs.readFileSync(vf, 'utf8')) : {};
  check('(8i-8) K-8: claude cannot be started', v.verdict === 'not judged' && v.failed === 18 && /^claude could not be started/.test(v.why ?? '') && /claude\.cmd/.test(v.why ?? ''), JSON.stringify({ v, status: res.status, out: res.stdout }));
});

// (8i-9) X-7: a failed read of the commit's files stops the copy (here, a blob the repo does not have)
await tryCheck('(8i-9) X-7: a failed read stops the copy', () => {
  if (!need('(8i-9) X-7: a failed read stops the copy')) return;
  const e = repo(D, SKILL);
  const oid = spawnSync('git', ['hash-object', '-w', '--stdin'], { cwd: e.r, input: 'x\n', encoding: 'utf8' }).stdout.trim();
  const tree = spawnSync('git', ['mktree', '--missing'], { cwd: e.r, input: `100644 blob ${'dead'.repeat(10)}\tgone.txt\n100644 blob ${oid}\tok.txt\n`, encoding: 'utf8' }).stdout.trim();
  const cut = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit-tree', tree, '-m', 'cut'], { cwd: e.r, encoding: 'utf8' }).stdout.trim();
  let err = '';
  try { T.copyHead(e.r, cut, path.join(tmp, `copy${++n}`)); } catch (x) { err = x.message; }
  check('(8i-9) X-7: a failed read stops the copy', /could not read gone\.txt/.test(err), JSON.stringify({ err, tree, cut }));
});

// (8i-10) item 10: after each session, the copy's Claude Code project folder goes when it holds no transcript, and
// stays when it holds one (here, a subagent's, on the 6 sessions of the unrelated prompt)
await tryCheck('(8i-10) no project folder left', async () => {
  if (!need('(8i-10) no project folder left')) return;
  const { r } = repo(D, SKILL);
  const hash = hashOf(cli(r, 'show pricing'));
  const config = path.join(tmp, 'config');
  const projects = path.join(config, 'projects');
  fs.mkdirSync(projects, { recursive: true });
  const v = await withEnv(stubEnv('project.log', { CLAUDE_CONFIG_DIR: config, STUB_PROJECT: '1' }), () => T.exec(r, 'pricing', hash));
  const left = fs.readdirSync(projects);
  const kept = left.filter((d) => fs.readdirSync(path.join(projects, d), { recursive: true }).some((f) => String(f).endsWith('.jsonl')));
  check('(8i-10) no project folder left', v?.verdict === 'helps' && left.length === 6 && kept.length === 6, JSON.stringify({ verdict: v?.verdict, left: left.length, kept: kept.length }));
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'trial8e ok');
process.exitCode = failed;
