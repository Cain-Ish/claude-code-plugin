// 06, section 8, 8l (the text step): one case per item, run against the plugin folder given (default: this one). Every
// case prints pass or fail; the exit code is the number of failures. Run on 8m's copy it shows which cases that build
// fails. Hooks and scripts run on the Node that runs this file.
//   node fix8l.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const imp = (f) => import(pathToFileURL(path.join(PLUGIN, 'scripts', f)).href);
const M = await imp('map.mjs');
const D = await imp('dream.mjs');
const T = await imp('trial.mjs');
const { FILES } = await imp('setup.mjs');
const NODE = process.execPath;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-fix8l-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const text = (f) => { try { return fs.readFileSync(path.join(PLUGIN, f), 'utf8'); } catch { return ''; } };
const flat = (s) => s.replace(/\s+/g, ' ');
const front = (f) => /^---\n([\s\S]*?)\n---\n/.exec(text(f))?.[1] ?? '';
const desc = (f) => /^description: (.*)$/m.exec(front(f))?.[1] ?? '';
const SK = { dream: 'skills/dream/SKILL.md', setup: 'skills/setup/SKILL.md', status: 'skills/status/SKILL.md', tailor: 'skills/tailor/SKILL.md', review: 'templates/claude/skills/map-review/SKILL.md' };
const README = 'templates/project-map/README.md', AN = 'agents/dream-analyzer.md', GUIDE = 'skills/tailor/guidelines.md';
// children run without the session's own plugin variables or entry point; each case sets the entry point it needs
const ostemp = path.join(tmp, 'ostemp');
fs.mkdirSync(ostemp);
// and with their own temp folder, which session start's marker goes to
const clean = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(NoDefaultCurrentDirectoryInExePath|CLAUDE_PLUGIN_DATA|CLAUDE_PLUGIN_ROOT|CLAUDE_CODE_ENTRYPOINT|CLAUDE_PROJECT_DIR)$/i.test(k))), TEMP: ostemp, TMP: ostemp, TMPDIR: ostemp };
let n = 0;
const repoWith = (files) => {
  const r = path.join(tmp, `r${++n}`);
  fs.mkdirSync(r, { recursive: true });
  const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' });
  g('init', '-q');
  for (const [f, t] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true }); fs.writeFileSync(path.join(r, f), t); }
  g('add', '-A');
  g('commit', '-qm', 'base');
  return r;
};
console.log(`node ${process.version}; children run on ${spawnSync(NODE, ['-p', 'process.version'], { encoding: 'utf8' }).stdout.trim()}`);

// 1. the flag goes from the four skills and the map-review template; the template's 2.6.0 text (live.1) is listed for
// setup's update (D29)
for (const [k, f] of Object.entries(SK)) await tryCheck(`1 no flag: ${k}`, () => check(`1 no flag: ${k}`, text(f).startsWith('---\n') && !text(f).includes('disable-model-invocation'), front(f)));
await tryCheck("1 the template's old hash for setup", () => {
  const row = FILES.find(([from]) => from === 'claude/skills/map-review/SKILL.md');
  check("1 the template's old hash for setup", (row?.[2] ?? []).includes('6d3e35da1c6033c9'), JSON.stringify(row));
});

// 2. each description says when Claude starts it, with no ": " inside, which a YAML parser refuses in a plain value
const WHEN = {
  dream: "Use when asked for a dream, or when told one is due, then after the person's current task, saying so first.",
  setup: "Use, after asking the person, when the layout is missing or a kept file is an earlier release's template.",
  status: 'Use when asked how current the team memory is.',
  tailor: 'Use when asked to make or test an agent, skill or path rule here.',
  review: 'Use when proposals, drafts or due entries wait and the user agrees to review them.',
};
for (const [k, w] of Object.entries(WHEN)) await tryCheck(`2 when Claude starts ${k}`, () => check(`2 when Claude starts ${k}`, desc(SK[k]).endsWith(w) && !desc(SK[k]).includes(': '), desc(SK[k])));

// 3. the due line: in Claude's context when the entry point is not sdk-cli, with the person's line as before; inside
// the cap, so a cut index keeps both its cut and the line
await tryCheck('3 the due line', () => {
  const r = repoWith({ '.project-map/decisions.md': '### a\n> Dates show as DD.MM.YYYY.\n', 'README.md': '# r\n' });
  const data = path.join(tmp, `data${n}`);
  const tdir = path.join(tmp, `t${n}`);
  fs.mkdirSync(tdir);
  for (let k = 0; k < 10; k++) fs.writeFileSync(path.join(tdir, `s${k}.jsonl`), '{}\n');
  const start = (entry) => {
    const x = spawnSync(NODE, [path.join(PLUGIN, 'scripts', 'hook.mjs'), 'session-start'], { encoding: 'utf8', input: JSON.stringify({ session_id: 'fix8l', cwd: r, source: 'startup', transcript_path: path.join(tdir, 'now.jsonl') }), env: { ...clean, CLAUDE_PROJECT_DIR: r, CLAUDE_PLUGIN_DATA: data, BRAIN_DIR: path.join(tmp, 'no-v1'), CLAUDE_CODE_ENTRYPOINT: entry } });
    const j = JSON.parse(x.stdout || '{}');
    return { ctx: j.hookSpecificOutput?.additionalContext ?? '', msg: j.systemMessage ?? '' };
  };
  const cli = start('cli'), sdk = start('sdk-cli');
  const line = "A dream is due for this project's team memory. After the person's current task, say so, then start the second-brain:dream skill unless they decline.";
  check('3 the due line', cli.ctx.endsWith(`\n${line}`) && !sdk.ctx.includes('dream is due') && sdk.ctx === cli.ctx.slice(0, -line.length - 1)
    && [cli, sdk].every((o) => o.msg.includes('second-brain: a dream is due: 10 new sessions')), JSON.stringify({ cli: cli.ctx.slice(-200), sdk: sdk.ctx.slice(-120), msg: cli.msg }));
});
await tryCheck('3 the cap holds with the line', () => {
  const big = `${M.HEADER}\n${Array.from({ length: 400 }, (_, i) => `packages/package-${i}/: README.md`).join('\n')}\n`;
  const without = M.startText(big), withIt = M.startText(big, true);
  check('3 the cap holds with the line', withIt.text.length <= M.CAP && withIt.text.endsWith(`\n${M.DUE}`) && withIt.listed < without.listed && withIt.listed > 0
    && withIt.text.includes(`(${400 - withIt.listed} more directories not listed`), `${withIt.text.length} ${withIt.listed} ${without.listed}`);
});

// 4. the README says each skill's first start by Claude asks once, and how to allow them in advance
await tryCheck('4 permissions in the README', () => check('4 permissions in the README', flat(text(README)).includes('Each asks your permission the first time. To allow them in advance, add rules such as `Skill(second-brain:dream)` to `permissions.allow` in `.claude/settings.json`.'), text(README).slice(-400)));

// 5. audit 6: setup's and onboard's grants cover only their own command
await tryCheck("5 setup's and onboard's grants", () => {
  const grant = (f) => /^allowed-tools: (.*)$/m.exec(text(f))?.[1];
  check("5 setup's and onboard's grants", grant(SK.setup) === 'Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs" setup:*)' && grant('commands/onboard.md') === 'Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs" onboard:*)', `${grant(SK.setup)} | ${grant('commands/onboard.md')}`);
});

// 6. audit 2, the text half: reject replaces a committed proposal's proposed line
await tryCheck('6 reject replaces the proposed line', () => check('6 reject replaces the proposed line', flat(text(SK.review)).includes('If it is committed, replace its `proposed` line with `- status: expired <today> by review: rejected`.'), ''));

// 7. L-2 and audit 5: validate() refuses a skill's should-use prompt that names the skill, and wants /<name> first for a
// skill only a person starts; the live release cases (which say "release" as a task) still pass, as do agent cases
const caseRepo = (skill) => repoWith({ '.claude/skills/release/SKILL.md.draft': skill, '.project-map/evals/checks/c.mjs': 'process.exit(0);\n', '.claude/agents/helper.md.draft': '---\nname: helper\ndescription: Helps.\ntools: Read\n---\nHelp.\n' });
const spec = (prompts, artifact = '.claude/skills/release/SKILL.md.draft') => ({ artifact, runs: 3, cases: [...prompts.map((p, i) => ({ id: `c${i}`, prompt: p, tools: ['Read', 'Skill', 'Agent'], check: '.project-map/evals/checks/c.mjs' })), { id: 'no', prompt: 'Use the release skill to list files.', tools: ['Read', 'Skill'], use: false, check: '.project-map/evals/checks/c.mjs' }] });
const named = (errs) => errs.filter((e) => /names the skill|starts with \//.test(e));
await tryCheck("7 L-2 a skill's prompt names it", () => {
  const r = caseRepo('---\nname: release\ndescription: Releases.\n---\nBump.\n');
  const live = ['We are releasing the version in progress. Make every file that states the plugin\'s version say so.', 'Draft the release notes for the version in progress.', 'Record what the plan has not finished before we release.'];
  const bad = ['Use the release skill to bump the version.', 'Run /release now.', 'Follow `release` for this.', 'Use skill release here.'];
  const got = bad.map((p) => named(T.validate(r, spec([p, ...live.slice(1)]))).length);
  const agent = T.validate(r, { ...spec(['Use the `helper` agent, if this repo has one; otherwise do it yourself: help.', 'b', 'c']), artifact: '.claude/agents/helper.md.draft' });
  check("7 L-2 a skill's prompt names it", got.every((k) => k === 1) && named(T.validate(r, spec(live))).length === 0 && named(agent).length === 0, `${got} ${T.validate(r, spec(live))} ${agent}`);
});
await tryCheck('7 audit 5 a flagged skill starts with /<name>', () => {
  const r = caseRepo('---\nname: release\ndescription: Releases.\ndisable-model-invocation: true\n---\nBump.\n');
  const plain = named(T.validate(r, spec(['Bump the version.', '/release now', '/release the notes'])));
  const slash = named(T.validate(r, spec(['/release bump the version', '/release now', '/release'])));
  check('7 audit 5 a flagged skill starts with /<name>', plain.length === 1 && /starts with \/release/.test(plain[0]) && slash.length === 0, `${plain} | ${slash}`);
});

// 8. C-4: tailor's cli hands "cases <path>" to the cases step alone, for an artifact that is there, and makes nothing;
// map-review's untested line names it
const cli = (r, words) => spawnSync(NODE, [path.join(PLUGIN, 'scripts', 'trial.mjs'), 'cli'], { cwd: r, input: words, encoding: 'utf8', env: clean }).stdout;
await tryCheck('8 C-4 tailor cases <path>', () => {
  const r = caseRepo('---\nname: release\ndescription: Releases.\n---\nBump.\n');
  const before = spawnSync('git', ['status', '--porcelain'], { cwd: r, encoding: 'utf8' }).stdout;
  const ok = cli(r, 'cases .claude/skills/release/SKILL.md.draft\n');
  const missing = cli(r, 'cases .claude/skills/nope/SKILL.md');
  const outside = cli(r, 'cases ../x/SKILL.md');
  const after = spawnSync('git', ['status', '--porcelain'], { cwd: r, encoding: 'utf8' }).stdout;
  check('8 C-4 tailor cases <path>', ok.startsWith('Tailor: write only the cases for .claude/skills/release/SKILL.md.draft, a skill: step 5 below, in .project-map/evals/release.json') && ok.includes('## Cases, before anyone keeps it')
    && missing.startsWith('The trial stopped: not a plain file in the repo') && outside.startsWith('The trial stopped: cases takes the path') && before === after, `${ok.slice(0, 160)} | ${missing} | ${outside}`);
});
await tryCheck('8 C-4 the texts name it', () => check('8 C-4 the texts name it', flat(text(SK.review)).includes('`/second-brain:tailor cases <the draft\'s path>`, which writes its cases first')
  && text(SK.tailor).includes('If it says to write only the cases, do steps 5 and 6 for that artifact.') && text(SK.tailor).includes('cases <path>'), ''));

// 9. C-6: the survey ends with a question that names the make line (attempt 2: 8e check 4's "asks" reads a question)
await tryCheck('9 C-6 the survey asks for the make line', () => check('9 C-6 the survey asks for the make line', flat(text(SK.tailor)).includes('**Ask which to make, and stop.** Make nothing until the person picks one: end with the question "Which one should I make?" and, for each gap listed, the exact line to type with its name filled in, such as `/second-brain:tailor make add-migration`.'), ''));

// 10. P-3: the analyzers read only their digest and the steering file; the main session keeps usage.json
await tryCheck('10 P-3 the analyzers get no usage.json', () => check('10 P-3 the analyzers get no usage.json', !text(AN).includes('usage.json') && flat(text(SK.dream)).includes("the digest's path, and the steering file's path when the report above names one; nothing else (`usage.json` is for step 3)."), ''));

// 11. P-7: the guidelines live beside the skill and come with the making steps, not with show
await tryCheck('11 P-7 the guidelines file', () => {
  const r = repoWith({ 'README.md': '# r\n' });
  const made = cli(r, 'make a release skill');
  check('11 P-7 the guidelines file', text(GUIDE).startsWith('# Guidelines\n') && !text(SK.tailor).includes('SkillsBench') && !text(SK.tailor).includes('## Guidelines') && text(SK.tailor).length < 6500
    && made.startsWith('Tailor: make one agent, skill or path rule') && made.includes('SkillsBench') && made.includes('## Choose the smallest home'), `${text(SK.tailor).length} ${made.slice(0, 200)}`);
});

// 12. P-13, P-14: prepare's steering line no longer repeats the skill's step 1; map-review's empty agent sentence goes
await tryCheck('12 P-13 the steering line', () => check('12 P-13 the steering line', !text('scripts/dream.mjs').includes('Give its path to each analyzer with its digest.') && text('scripts/dream.mjs').includes("`Steering: ${RUN}/steering.md, the team's word on what matters here, as HEAD holds it.`"), ''));
await tryCheck('12 P-14 the empty agent sentence', () => check('12 P-14 the empty agent sentence', !flat(text(SK.review)).includes('Agents are trialled only through cases that name them.'), ''));

// 13. R-c: the placement table's agent row and tailor's pointer; the dream line names everything a dream proposes;
// the README's 2.5.1 text is listed for setup's update
await tryCheck('13 R-c the placement table', () => {
  const t = flat(text(README));
  const row = FILES.find(([from]) => from === 'project-map/README.md');
  check('13 R-c the placement table', t.includes('| A task that needs its own context, tools or notes | an entry here; offer the user an agent in `.claude/agents/` |')
    && t.includes('`/second-brain:tailor` makes a skill, agent or path rule as a draft, with the cases that test it.')
    && t.includes("A dream proposes entries and status lines, and drafts of path rules, skills, agents and changes to the repo's own")
    && (row?.[2] ?? []).includes('15a4bb133893f00e'), JSON.stringify(row));
});

// 14. R-d: a retried finish before review; a D line where the date changes (kept by the trim); no "user-only"
await tryCheck('14 R-d a retried finish before review', () => check('14 R-d a retried finish before review', flat(text(SK.dream)).includes('A finish that stopped is retried before any review: a retry puts back every change made to the map since prepare, a review\'s too.') && !/user-only/.test(text(SK.dream)), ''));
await tryCheck('14 R-d the date lines', async () => {
  const J = (o) => JSON.stringify({ cwd: tmp, ...o });
  const U = (t, ts) => J({ type: 'user', promptSource: 'sdk', timestamp: ts, message: { role: 'user', content: t } });
  const call = (ts, file = 'a') => J({ type: 'assistant', timestamp: ts, message: { role: 'assistant', content: [{ type: 'tool_use', id: `x${ts}${file}`, name: 'Read', input: { file_path: file } }] } });
  const f = path.join(tmp, 'dates.jsonl');
  // the map read on a new date: its D line comes first, so the read's recorded line is still its own T line
  fs.writeFileSync(f, `${[U('First day words here.', '2026-11-20T10:00:00Z'), J({ type: 'system', timestamp: '2026-11-21T09:00:00Z' }), U('Still the first day.', '2026-11-20T23:00:00Z'), ...Array.from({ length: 6 }, () => call('2026-11-21T08:00:00Z')), U('Second day words here.', '2026-11-21T09:00:00Z'), call('2026-11-22T08:00:00Z', '.project-map/decisions.md')].join('\n')}\n`);
  const d = await D.digestFrom(f, 0, () => true);
  const { out } = D.trim(d.lines, new Set(d.mapAt.map((m) => m.idx)));
  check('14 R-d the date lines', d.lines[0].startsWith('U: First day') && d.lines.filter((l) => l.startsWith('D: ')).join('|') === 'D: 2026-11-21|D: 2026-11-22' && d.lines.indexOf('D: 2026-11-21') === 2
    && out.includes('D: 2026-11-21') && out.indexOf('D: 2026-11-21') < out.findIndex((l) => l.startsWith('U: Second')) && /^T: Read .*decisions\.md/.test(d.lines[d.mapAt[0]?.idx] ?? ''), JSON.stringify(out));
});

// 15. X-6: the heredoc's delimiter is improbable, and closes the block
await tryCheck('15 X-6 the delimiter', () => {
  const m = /cli <<'([^']+)'\n\$ARGUMENTS\n([^\n]+)\n```/.exec(text(SK.tailor));
  check('15 X-6 the delimiter', Boolean(m) && m[1] === m[2] && /^SECOND_BRAIN_WORDS_[A-Za-z0-9]{8,}$/.test(m[1]), m?.[1]);
});

// 16. L-5 and L-7: tailor reads without Bash; the dream's commands never run from inside the run folder
await tryCheck('16 L-5 tailor reads without Bash', () => check('16 L-5 tailor reads without Bash', text(SK.tailor).includes('Read the repo with Read, Grep and Glob, not Bash.'), ''));
await tryCheck('16 L-7 the shell stays out of the run folder', () => check('16 L-7 the shell stays out of the run folder', flat(text(SK.dream)).includes("Run every command with the Bash tool, never PowerShell (the grant covers Bash), from the repo's top, never from inside `.project-map/.dream-run/`, which finish removes."), ''));

// 17. the guidelines: L-2 for agents, L-17 (audit 5), L-12, L-22, Q-5
const G = flat(text(GUIDE));
for (const [id, s] of [
  ['17 L-2 a skill case never names it', "A skill's says the task, never the skill's name (the trial refuses one that names it)"],
  ["17 L-2 an agent's case names it", "An agent's prompt names it, as \"the `<name>` agent, if this repo has one; otherwise do it yourself\""],
  ['17 L-17 a user-only skill starts with /<name>', 'A skill only the user starts is the exception: its prompt starts with `/<name>` (the trial checks).'],
  ['17 L-12 a check reads facts from the copy', '**A check accepts any wording of the fact,** and reads what changes (a version, a step\'s state) from the copy\'s own files'],
  ['17 L-22 a test of the checks', '**A test of the checks** matches each fact exactly as its check does.'],
  ['17 Q-5 memory is not a guard', 'It also turns on Read, Write and Edit with no path scope, whatever `tools` says: a body\'s "your writes go only to …" is an instruction, not a guard.'],
]) await tryCheck(id, () => check(id, G.includes(s), ''));

// 18. L-16: discard says what becomes of the case file and checks
await tryCheck('18 L-16 discard and the case file', () => check('18 L-16 discard and the case file', flat(text(SK.review)).includes('still name it: ask whether to delete them too, or keep them for a new draft at the same path.'), ''));

// 19. tailor says what it does: create, or test through cases, never "change"
await tryCheck('19 tailor does not claim to change', () => check('19 tailor does not claim to change', !/create, change or test/.test(text(SK.tailor)) && desc(SK.tailor).includes('writes the cases that test a draft or an artifact against a run without it'), desc(SK.tailor)));

// 20. Q-15 (8m's hook half): session start tells the person what a dream put back, once, then deletes the note; a
// headless session leaves it
await tryCheck('20 Q-15 undone.txt once', () => {
  const r = repoWith({ 'README.md': '# r\n' });
  const data = path.join(tmp, `data${n}`);
  const note = path.join(M.stateDir(r, data), 'undone.txt');
  fs.mkdirSync(path.dirname(note), { recursive: true });
  fs.writeFileSync(note, 'Undone, because they changed during the dream: CLAUDE.md.\n');
  const start = (entry) => JSON.parse(spawnSync(NODE, [path.join(PLUGIN, 'scripts', 'hook.mjs'), 'session-start'], { encoding: 'utf8', input: JSON.stringify({ session_id: 'fix8l', cwd: r, source: 'startup' }), env: { ...clean, CLAUDE_PROJECT_DIR: r, CLAUDE_PLUGIN_DATA: data, BRAIN_DIR: path.join(tmp, 'no-v1'), CLAUDE_CODE_ENTRYPOINT: entry } }).stdout || '{}');
  const sdk = start('sdk-cli');
  const kept = fs.existsSync(note);
  const first = start('cli'), second = start('cli');
  check('20 Q-15 undone.txt once', !String(sdk.systemMessage).includes('Undone') && kept && String(first.systemMessage).includes('Undone, because they changed during the dream: CLAUDE.md.')
    && !fs.existsSync(note) && !String(second.systemMessage).includes('Undone') && !String(first.hookSpecificOutput?.additionalContext).includes('Undone'), JSON.stringify([sdk.systemMessage, kept, first.systemMessage, second.systemMessage]));
});

// 21. 8m's analyzer text: the cut mark, the sdk-cli mark, the correction's topic field (L-9); and the D line
for (const [id, s] of [
  ['21 the cut mark', 'A U or Q line that ends `…[cut at N of M characters]` was cut: quote only what it shows.'],
  ['21 the sdk-cli mark', "A line marked `[sdk-cli: not shown to be the person's]` came through `claude -p`, perhaps from another program. You may cite it: add ` (marked sdk-cli)` after the statement, and the person weighs it at review."],
  ["21 L-9 the correction's topic", 'end the line with ` | <topic>.md`, that file\'s name.'],
  ['21 the D line', '- **D:** the date from that line on, where it changes.'],
]) await tryCheck(id, () => check(id, flat(text(AN)).includes(s), ''));

// 22. the 8k and audit README items: index.ignore, and what [private] means
await tryCheck('22 index.ignore in the README', () => check('22 index.ignore in the README', flat(text(README)).includes("**`index.ignore`** in this folder leaves folders out of the document index: one folder or glob pattern per line, from the repo's root, such as `docs/archive` or `**/fixtures`; `#` starts a comment. This folder is always listed. When git rejects a line, the file is not used that session"), ''));
await tryCheck('22 [private] in the README', () => check('22 [private] in the README', flat(text(README)).includes('`[private]` stands for text removed as private, which no proposal quotes.'), ''));

// 23. D34 without the flag: tailor still never runs a trial, and grants cli and draft only
await tryCheck('23 tailor never starts a trial', () => check('23 tailor never starts a trial', text(SK.tailor).includes('Never run `trial.mjs` yourself except `draft` in step 4: a trial starts only when the person types the line')
  && /^allowed-tools: Bash\(node "\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/trial\.mjs" cli:\*\), Bash\(node "\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/trial\.mjs" draft:\*\)$/m.test(text(SK.tailor)), ''));

// R. the two reviews of 8l (2026-11-26), one case per fix
// a repo with a dream due, its data folder, and session start's output for an entry point
const dueWorld = () => {
  const r = repoWith({ '.project-map/decisions.md': '### a\n> Dates show as DD.MM.YYYY.\n', 'README.md': '# r\n' });
  const data = path.join(tmp, `data${n}`);
  const tdir = path.join(tmp, `t${n}`);
  fs.mkdirSync(tdir);
  for (let k = 0; k < 10; k++) fs.writeFileSync(path.join(tdir, `s${k}.jsonl`), '{}\n');
  const start = (entry) => {
    const x = spawnSync(NODE, [path.join(PLUGIN, 'scripts', 'hook.mjs'), 'session-start'], { encoding: 'utf8', input: JSON.stringify({ session_id: 'fix8l', cwd: r, source: 'startup', transcript_path: path.join(tdir, 'now.jsonl') }), env: { ...clean, CLAUDE_PROJECT_DIR: r, CLAUDE_PLUGIN_DATA: data, BRAIN_DIR: path.join(tmp, 'no-v1'), CLAUDE_CODE_ENTRYPOINT: entry } });
    const j = JSON.parse(x.stdout || '{}');
    return { ctx: j.hookSpecificOutput?.additionalContext ?? '', msg: j.systemMessage ?? '' };
  };
  return { r, data, start };
};
// R1 (decision-checker 1): a made artifact stays a draft until /map-review promotes it after its verdict
await tryCheck('R1 a made artifact stays a draft', () => check('R1 a made artifact stays a draft', flat(text(SK.tailor)).includes('A made artifact stays a draft, which Claude Code never loads, until the person promotes it in `/map-review`, which shows its trial verdict first.'), ''));
// R2 (decision-checker 2): every SDK entry point is headless
await tryCheck('R2 no due line for any sdk- entry point', () => {
  const w = dueWorld();
  const got = ['sdk-ts', 'sdk-py', 'sdk-cli'].map((e) => w.start(e).ctx.includes('dream is due'));
  check('R2 no due line for any sdk- entry point', got.every((x) => !x) && w.start('cli').ctx.includes('dream is due'), JSON.stringify(got));
});
// R3 (decision-checker 3) is case 17's Q-5 pin, reworded to name the limit
// R4 (Gemini 4): a skill the person starts by typing /<name> gets a Skill line, so a correction after it can name it;
// a built-in command gets none, and a typed dream still starts the dream's gate
await tryCheck('R4 a typed skill command has a line', async () => {
  const J = (o) => JSON.stringify({ cwd: tmp, timestamp: '2026-11-20T10:00:00Z', ...o });
  const cmdRec = (c) => J({ type: 'user', message: { role: 'user', content: `<command-message>${c}</command-message>\n<command-name>/${c}</command-name>\n<command-args></command-args>` } });
  const typed = (t) => J({ type: 'user', promptSource: 'typed', message: { role: 'user', content: t } });
  const f = path.join(tmp, 'typed.jsonl');
  fs.writeFileSync(f, `${[cmdRec('release'), J({ type: 'user', isMeta: true, message: { role: 'user', content: [{ type: 'text', text: 'Base directory for this skill: x' }] } }), typed('No, the changelog goes first marker T1.'), cmdRec('compact'), cmdRec('plug:fmt'), cmdRec('second-brain:dream'), typed('inside the dream marker T2')].join('\n')}\n`);
  const d = await D.digestFrom(f, 0, () => true, new Set(['release']));
  check('R4 a typed skill command has a line', d.lines.join('|') === 'T: Skill release|U: No, the changelog goes first marker T1.|T: Skill plug:fmt'
    && flat(text(AN)).includes('(a skill the user started by typing `/<name>` shows as a Skill call)'), JSON.stringify(d.lines));
});
// R5 (Gemini 5): the naming rules hold for should-use cases, in one place; a should-not case never invokes it
await tryCheck('R5 the naming rules agree', () => check('R5 the naming rules agree', flat(text(GUIDE)).includes("**A should-use case's prompt** reaches the artifact as a person would.")
  && flat(text(GUIDE)).includes("**The case where it should not be used** (`use: false`) never invokes it: no `/<name>`, and no agent's name.")
  && !text(SK.tailor).includes("a skill's never names it, an agent's always does") && text(SK.tailor).includes("Its prompts follow the guidelines' cases section."), ''));
// R6 (Gemini 6): a bare make <name> is the person's pick of a surveyed gap
await tryCheck('R6 make <name> is a pick', () => check('R6 make <name> is a pick', flat(text(SK.tailor)).includes("Then go on to step 2. So does `make <name>`: the person's pick of a gap a survey listed, with its evidence."), ''));
// R7 (Gemini 7): a first record with no line still sets the first day, so a later first line's day gets its D line
await tryCheck('R7 a D line against the first day', async () => {
  const f = path.join(tmp, 'firstday.jsonl');
  fs.writeFileSync(f, `${[JSON.stringify({ cwd: tmp, type: 'system', timestamp: '2026-11-20T10:00:00Z' }), JSON.stringify({ cwd: tmp, type: 'user', promptSource: 'typed', timestamp: '2026-11-21T10:00:00Z', message: { role: 'user', content: 'Words on the second day.' } })].join('\n')}\n`);
  const d = await D.digestFrom(f, 0, () => true);
  check('R7 a D line against the first day', d.lines.join('|') === 'D: 2026-11-21|U: Words on the second day.' && String(d.first).startsWith('2026-11-20'), JSON.stringify(d.lines));
});
// R8 (Gemini 8): a path is not the command; a quoted name and the artifact's own folder name it
await tryCheck('R8 what names a skill', () => {
  const r = caseRepo('---\nname: release\ndescription: Releases.\n---\nBump.\n');
  const k = (p) => named(T.validate(r, spec([p, 'b', 'c']))).length;
  const not = ['Update ./release/notes.md.', 'Call GET /release/latest.', 'Look in ../release for it.', 'Read docs/release.md first.'];
  const yes = ['Use the "release" skill.', "Use the 'release' skill.", 'Follow .claude/skills/release/SKILL.md.', 'Run /release now.', 'Run /release.'];
  check('R8 what names a skill', not.every((p) => k(p) === 0) && yes.every((p) => k(p) === 1), JSON.stringify([not.map(k), yes.map(k)]));
});
// R9 (Gemini 9): the artifact is read only after its path checks, the read caught, a byte-order mark allowed
await tryCheck('R9 the artifact read after its checks', () => {
  const r = caseRepo('﻿---\nname: release\ndescription: Releases.\ndisable-model-invocation: true\n---\nBump.\n');
  fs.writeFileSync(path.join(r, '.claude', 'SKILL.md'), '---\nname: release\ndescription: R.\n---\nB.\n');
  const bom = named(T.validate(r, spec(['Bump the version.', '/release now', '/release b'])));
  const climbs = T.validate(r, { ...spec(['Use the release skill.', 'b', 'c']), artifact: '.claude/skills/../SKILL.md' });
  check('R9 the artifact read after its checks', bom.length === 1 && named(climbs).length === 0 && climbs.some((e) => e.startsWith('the artifact must be')), JSON.stringify([bom, climbs]));
});
// R10 (Gemini 10): cases with no path, or with more words, prints its use
await tryCheck('R10 cases without one path', () => {
  const r = repoWith({ 'README.md': '# r\n' });
  const got = ['cases', 'cases a b'].map((w) => cli(r, w));
  check('R10 cases without one path', got.every((o) => o.startsWith('Use: /second-brain:tailor cases <the path of a skill, agent or rule file')), JSON.stringify(got.map((o) => o.slice(0, 60))));
});
// R11 (Gemini 11): no due line while a dream holds the lock; the person still hears both
await tryCheck('R11 no due line while a dream runs', () => {
  const w = dueWorld();
  fs.mkdirSync(M.stateDir(w.r, w.data), { recursive: true });
  fs.writeFileSync(path.join(M.stateDir(w.r, w.data), 'dream.lock'), 'x');
  const o = w.start('cli');
  check('R11 no due line while a dream runs', !o.ctx.includes('dream is due') && o.msg.includes('a dream is due: 10 new sessions') && o.msg.includes('a dream is running in another session'), JSON.stringify(o.msg));
});
// R12 (Gemini 12): tailor's steps hold no fact the guidelines already hold
await tryCheck('R12 tailor holds each fact once', () => {
  const t = flat(text(SK.tailor));
  check('R12 tailor holds each fact once', !t.includes('Claude does it anyway, the repo already shows it') && !t.includes('An agent only for a task that needs its own context')
    && !t.includes('keep only what Claude cannot infer') && t.includes("by the guidelines' first section"), '');
});

// A. 8l attempt 2 (06, "8l: attempt 1 ... attempt 2 registered"): one case per text change
// A1: a line marked sdk-cli may be cited, marked, for the person to weigh; no refusal
await tryCheck('A1 an sdk-cli line may be cited', () => check('A1 an sdk-cli line may be cited', flat(text(AN)).includes('You may cite it: add ` (marked sdk-cli)` after the statement, and the person weighs it at review.') && !/never quote it as the person/.test(flat(text(AN))), ''));
// A2 is case 9: the survey ends with a question that names the make line
// A3: a check is tested with one plain node command
await tryCheck('A3 a check tested by one plain command', () => check('A3 a check tested by one plain command', flat(text(GUIDE)).includes('Run each check with one plain `node <check file>` command: no `$()`, `&&`, pipes or PowerShell.'), ''));
// A5, A6 (8l attempt 4): the run line given on its own line, unquoted; a check tested without a scratch file
await tryCheck('A5 the run line on its own line', () => check('A5 the run line on its own line', flat(text(SK.tailor)).includes('with the `! node` line on a line of its own, exactly as printed: not quoted, not in code marks.'), ''));
await tryCheck('A6 no scratch file to test a check', () => check('A6 no scratch file to test a check', flat(text(GUIDE)).includes('Write no other file to test it.'), ''));
// A4: the skills that run commands say to run them with the Bash tool, which their grants cover; map-review's changed
// template is listed for setup's update
await tryCheck('A4 commands through the Bash tool', () => {
  const row = FILES.find(([from]) => from === 'claude/skills/map-review/SKILL.md');
  check('A4 commands through the Bash tool', flat(text(SK.dream)).includes('Run every command with the Bash tool, never PowerShell (the grant covers Bash)')
    && flat(text(SK.tailor)).includes('Run `draft`, and any test of a check, with the Bash tool, never PowerShell: the grant covers Bash.')
    && flat(text(SK.status)).includes('Run any command with the Bash tool, never PowerShell.') && flat(text(SK.review)).includes('Run its commands with the Bash tool, never PowerShell.')
    && (row?.[2] ?? []).includes('7e5d413c03dfa3ea'), JSON.stringify(row));
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'fix8l ok');
process.exitCode = failed;
