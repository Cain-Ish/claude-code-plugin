// 06, section 8, 8o (the final audit's fixes): one case per item, each in its own temp repo, run against the plugin
// folder given (default: this one). Every case prints pass or fail; the exit code is the number of failures. Run on
// 8l's product it shows which cases that build fails. Hooks run on the Node that runs this file.
//   node fix8o.mjs [plugin folder]
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const imp = (f) => import(pathToFileURL(path.join(PLUGIN, 'scripts', f)).href);
const D = await imp('dream.mjs');
const T = await imp('trial.mjs');
const { FILES } = await imp('setup.mjs');
const NODE = process.execPath;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8o-'));
const ostemp = path.join(tmp, 'ostemp');
fs.mkdirSync(ostemp);
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const text = (f) => { try { return fs.readFileSync(path.join(PLUGIN, f), 'utf8'); } catch { return ''; } };
const flat = (s) => s.replace(/\s+/g, ' ');
const savedCfg = process.env.CLAUDE_CONFIG_DIR;
// children run as from a plain shell, never with the session's own plugin variables, project or config
const clean = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(NoDefaultCurrentDirectoryInExePath|CLAUDE_PLUGIN_DATA|CLAUDE_PLUGIN_ROOT|CLAUDE_PROJECT_DIR|CLAUDE_CONFIG_DIR)$/i.test(k))), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp };
let n = 0;
// a repo with files committed, then the uncommitted ones appended
const repoWith = (files, uncommitted = {}) => {
  const r = path.join(tmp, `r${++n}`);
  const g = (...a) => { const x = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' }); if (x.status) throw new Error(x.stderr); return x.stdout; };
  const put = (f, t, how = 'writeFileSync') => { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs[how](path.join(r, f), t); };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  g('config', 'core.autocrlf', 'false');
  for (const [f, t] of Object.entries(files)) put(f, t);
  g('add', '-A');
  g('commit', '-qm', 'base');
  for (const [f, t] of Object.entries(uncommitted)) put(f, t, 'appendFileSync');
  return { r, g };
};
console.log(`node ${process.version}; children run on ${spawnSync(NODE, ['-p', 'process.version'], { encoding: 'utf8' }).stdout.trim()}`);

// 1. D14 on Windows and for Grep: a PowerShell command that names the map, and a Grep whose path or glob names it, take
// the Bash route (hooks.json's entry, run as written there) and get its labels; a Grep's pattern alone names nothing
const MAPF = '.project-map/decisions.md';
const entry = (h, q) => `### ${h}\n> ${q}\n\n- source: the lead developer, 2026-11-08\n- when: ["work"]\n`;
const hookRepo = () => repoWith({ [MAPF]: entry('dates', 'Dates show as DD.MM.YYYY across the app.'), 'src/a.js': 'x\n' }, { [MAPF]: `\n${entry('pricing', 'Prices round half up to whole cents.')}` }).r;
const { hooks } = JSON.parse(text('hooks/hooks.json') || '{"hooks":{}}');
const route = (event, tool) => (hooks[event] ?? []).filter((m) => m.matcher === tool).flatMap((m) => m.hooks);
const run = (h, repo, input) => {
  const x = spawnSync(NODE, h.args.map((a) => a.replace('${CLAUDE_PLUGIN_ROOT}', PLUGIN)), { input: JSON.stringify({ cwd: repo, session_id: 'fix8o', ...input }), encoding: 'utf8', env: { ...clean, CLAUDE_PROJECT_DIR: repo, BRAIN_DIR: path.join(tmp, 'no-v1') }, timeout: 60_000 });
  return x.stdout ? JSON.parse(x.stdout).hookSpecificOutput?.additionalContext ?? '' : '';
};
// the uncommitted entry's label, and the committed one's that the output shows
const labelled = (o) => o.includes('pricing: unreviewed, not yet committed') && o.includes('unverified quote, committed: entries 1 ');
const want = (arg, rule) => ({ type: 'command', ...(rule && { if: rule }), command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs', arg], timeout: 10 });
await tryCheck('1 PowerShell takes the Bash route', () => {
  const r = hookRepo();
  const shown = '### dates\n> Dates show as DD.MM.YYYY across the app.\r\n';
  const [ok, fail] = [route('PostToolUse', 'PowerShell'), route('PostToolUseFailure', 'PowerShell')];
  const pin = JSON.stringify([ok, fail]) === JSON.stringify([[want('bash', 'PowerShell(*.project-map*)')], [want('bash-failure', 'PowerShell(*.project-map*)')]]);
  const a = ok[0] ? run(ok[0], r, { tool_name: 'PowerShell', tool_input: { command: "Get-Content '.Project-Map\\decisions.md'" }, tool_response: { stdout: shown, stderr: '', interrupted: false } }) : '';
  const b = fail[0] ? run(fail[0], r, { tool_name: 'PowerShell', tool_input: { command: 'Get-Content .project-map/decisions.md; exit 1' }, error: `Exit code 1\n${shown}` }) : '';
  const c = ok[0] ? run(ok[0], r, { tool_name: 'PowerShell', tool_input: { command: 'Get-Content src/a.js' }, tool_response: { stdout: shown, stderr: '' } }) : 'no route';
  check('1 PowerShell takes the Bash route', pin && [a, b].every(labelled) && c === '', JSON.stringify({ ok, fail, a: a.slice(0, 120), b: b.slice(0, 120), c: c.slice(0, 80) }));
});
await tryCheck('1 Grep by its path or glob', () => {
  const r = hookRepo();
  const [h] = route('PostToolUse', 'Grep');
  // no if field: Claude Code matches a Grep(...) rule against the pattern only (2.1.332's bundle), so a filter there
  // would skip a Grep that names the map by its path or glob
  const pin = JSON.stringify(route('PostToolUse', 'Grep')) === JSON.stringify([want('bash')]);
  const res = { mode: 'content', numFiles: 1, filenames: [], content: '.project-map/decisions.md:2:> Dates show as DD.MM.YYYY across the app.', numLines: 1 };
  const grep = (input) => (h ? run(h, r, { tool_name: 'Grep', tool_input: { pattern: 'Dates', output_mode: 'content', ...input }, tool_response: res }) : '');
  const named = [{ path: '.project-map' }, { glob: '.project-map/*.md' }, { path: path.join(r, '.project-map', 'decisions.md') }, { path: '.', glob: '**/.PROJECT-MAP/**' }].map(grep);
  // its pattern alone names nothing, and a Grep elsewhere gets nothing
  const not = [{ pattern: '.project-map', path: 'src' }, { path: 'src' }, {}].map(grep);
  check('1 Grep by its path or glob', pin && named.every(labelled) && not.every((o) => o === ''), JSON.stringify({ h, named: named.map((o) => o.slice(0, 80)), not }));
});

// 2. an agent or change draft whose front matter sets memory: user (its notes are written outside the repo) is refused
// as a power, with its reason in the report; memory: project and local stay allowed, and so does no memory key
await tryCheck('2 user memory refused', async () => {
  const ag = (name, more = '') => `---\nname: ${name}\ndescription: ${name}.\ntools: Read\n${more}---\n${name}.\n`;
  const { r } = repoWith({ [MAPF]: '### dates\n> Dates show as DD.MM.YYYY.\n\n- id: dates\n- source: the lead developer, 2026-11-01\n- when: ["ui"]\n', '.project-map/dreams.md': '# Dream log\n\n',
    '.claude/agents/helper.md': ag('helper'), '.claude/agents/scout.md': ag('scout') });
  const cfg = path.join(tmp, `cfg${n}`);
  const data = path.join(tmp, `data${n}`);
  const tdir = path.join(cfg, 'projects', fs.realpathSync.native(r).replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(tdir, { recursive: true });
  const J = (o) => JSON.stringify({ cwd: r, timestamp: '2026-11-20T10:00:00Z', ...o });
  const U = (t) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: t } });
  const call = (id, a) => [J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name: 'Agent', input: { subagent_type: a, prompt: 'x' } }] } }), J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: 'ok' }] } })];
  for (const k of [1, 2]) fs.writeFileSync(path.join(tdir, `s${k}.jsonl`), `${[U(`Start, marker S${k}.`), ...call(`h${k}`, 'helper'), ...call(`s${k}`, 'scout'), U(`Tighten them, marker T${k}.`)].join('\n')}\n`);
  process.env.CLAUDE_CONFIG_DIR = cfg;
  await D.prepare(r, data);
  const run8 = path.join(r, '.project-map', '.dream-run');
  const ref = (m) => { for (const f of fs.readdirSync(path.join(run8, 'digests'))) { const i = fs.readFileSync(path.join(run8, 'digests', f), 'utf8').split('\n').findIndex((l) => l.startsWith('U: ') && l.includes(m)); if (i >= 0) return `${f}:${i + 1}`; } throw new Error(`no digest holds ${m}`); };
  const e = `<!-- evidence: ${ref('T1')}, ${ref('T2')} -->\n`;
  const stage = (p, t) => { fs.mkdirSync(path.dirname(path.join(run8, 'proposals', p)), { recursive: true }); fs.writeFileSync(path.join(run8, 'proposals', p), `${t}${e}`); };
  const refused = ['memory: user\n', 'memory: "user"\n', 'memory: project\nmemory: user\n', 'memory:\n  user\n'];
  refused.forEach((m, i) => stage(`agents/u${i}.md`, ag(`u${i}`, m)));
  ['memory: project\n', "memory: 'local'\n", ''].forEach((m, i) => stage(`agents/k${i}.md`, ag(`k${i}`, m)));
  stage('change/agents/helper.md', ag('helper', 'memory: user\n'));
  stage('change/agents/scout.md', ag('scout', 'memory: project\n'));
  const fin = D.finish(r, data);
  const has = (p) => fs.existsSync(path.join(r, '.claude', 'agents', `${p}.md.draft`));
  check('2 user memory refused', !refused.some((_, i) => has(`u${i}`)) && ['k0', 'k1', 'k2'].every(has) && !has('helper') && has('scout')
    && /(^|\D)4 agent with memory: user, or a memory other than project or local/.test(fin) && /(^|\D)1 change with memory: user, or a memory other than project or local/.test(fin), fin);
});

// 3. map-review: each proposal and draft waits for the person's answer before any edit; before the commit, a change in
// the files to commit that the review did not make is shown, and committed only on a yes. The template's 2.6.0 text is
// kept for setup's update (D29)
const MR = 'templates/claude/skills/map-review/SKILL.md';
await tryCheck('3 map-review waits for each answer', () => check('3 map-review waits for each answer', flat(text(MR)).includes("with the dream's reason if this session has the dream's report. Wait for the user's answer before any edit.")
  && flat(text(MR)).includes("`.claude/agents/*.md.draft`. Show each one, and wait for the user's answer before any edit."), ''));
await tryCheck("3 map-review shows others' changes before the commit", () => check("3 map-review shows others' changes before the commit", flat(text(MR)).includes("-- <those files>`. Before it, show any change in those files that this review did not make (`git diff HEAD -- <those files>`), and commit a file that holds one only on the user's yes."), ''));
await tryCheck("3 the template's 2.6.0 text for setup", () => {
  const row = FILES.find(([from]) => from === 'claude/skills/map-review/SKILL.md');
  const kept = text('test/earlier/2.6.0/claude/skills/map-review/SKILL.md');
  const sum = crypto.createHash('sha256').update(kept.replace(/\r\n/g, '\n')).digest('hex').slice(0, 16);
  check("3 the template's 2.6.0 text for setup", sum === '2c564cbd2d263dac' && (row?.[2] ?? []).includes(sum), `${sum} ${JSON.stringify(row)}`);
});

// 4. show: a case that lists bare Bash says its sessions may run any command as the person, outside the copy too; one
// that lists Bash(...) with a pattern, or no Bash, does not
await tryCheck('4 show warns of bare Bash', () => {
  const spec = { artifact: '.claude/skills/pricing/SKILL.md.draft', runs: 3, cases: [
    { id: 'bare', prompt: 'Price the cart.', tools: ['Read', 'Skill', 'Bash'], check: '.project-map/evals/checks/ok.mjs' },
    { id: 'pattern', prompt: 'Price the order.', tools: ['Read', 'Skill', 'Bash(git status)'], check: '.project-map/evals/checks/ok.mjs' },
    { id: 'other', prompt: 'An unrelated task.', tools: ['Read', 'Skill'], use: false, check: '.project-map/evals/checks/ok.mjs' },
  ] };
  const { r } = repoWith({ 'README.md': '# r\n', '.project-map/evals/checks/ok.mjs': 'process.exit(0);\n', '.project-map/evals/pricing.json': JSON.stringify(spec, null, 1) },
    { '.claude/skills/pricing/SKILL.md.draft': '---\nname: pricing\ndescription: Prices the cart. Use when asked to price it.\n---\nPrice it.\n' });
  const out = T.show(r, 'pricing');
  const line = '  Bash with no pattern: its sessions may run any command as you, outside the copy too.';
  check('4 show warns of bare Bash', out.split(line).length === 2 && out.includes(`tools: Read, Skill, Bash\n${line}\n  check:`), out.split('\n').filter((l) => /case|tools|Bash/.test(l)).join(' | '));
});

if (savedCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = savedCfg;
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8o ok');
process.exitCode = failed;
