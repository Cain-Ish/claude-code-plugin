// 06, section 8, 8l (the text step): each mutation of a guard or a pinned sentence 8l adds must fail its test. A text
// item's mutation removes or reverts the sentence its case pins. Each runs in a copy of the candidate plugin under
// <work>/m, with the product-hash pin off. A mutation is tagged with the systems where its killing case runs; elsewhere
// it is listed as "not here". The unmutated copy runs first and must pass, or nothing is counted. The run exits non-zero
// when a mutation here survives or cannot be applied. Result: results/mutate8l-<platform>.txt beside this file, unless
// MUT_ONLY.
//   node mutate8l.mjs <plugin folder> <work folder>
// MUT_FAST=1 runs test/fix8l.mjs in place of the self-test; MUT_ONLY=<regex> runs only the mutations it matches, as a
// dry run.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const ANY = 'any';
const DS = 'skills/dream/SKILL.md', SE = 'skills/setup/SKILL.md', ST = 'skills/status/SKILL.md', TL = 'skills/tailor/SKILL.md', GD = 'skills/tailor/guidelines.md';
const MR = 'templates/claude/skills/map-review/SKILL.md', RM = 'templates/project-map/README.md', AN = 'agents/dream-analyzer.md', ON = 'commands/onboard.md';
const H = 'scripts/hook.mjs', MP = 'scripts/map.mjs', TR = 'scripts/trial.mjs', D = 'scripts/dream.mjs', SU = 'scripts/setup.mjs';
const FLAG = 'disable-model-invocation: true\n';
const M = [
  // 1. the flag goes; the template's old hash for setup
  ['1 dream unflagged', DS, "saying so first.\n", `saying so first.\n${FLAG}`, ANY],
  ['1 setup unflagged', SE, "earlier release's template.\n", `earlier release's template.\n${FLAG}`, ANY],
  ['1 status unflagged', ST, 'how current the team memory is.\n', `how current the team memory is.\n${FLAG}`, ANY],
  ['1 tailor unflagged', TL, 'argument-hint: ', `${FLAG}argument-hint: `, ANY],
  ['1 map-review unflagged', MR, 'agrees to review them.\n', `agrees to review them.\n${FLAG}`, ANY],
  ["1 map-review's 2.6.0 text listed for setup", SU, "'7ff1c09c889ebe9c', '6d3e35da1c6033c9', ", "'7ff1c09c889ebe9c', ", ANY],
  // 2. when Claude starts each
  ['2 dream says when', DS, " Use when asked for a dream, or when told one is due, then after the person's current task, saying so first.", ' Use after a stretch of work.', ANY],
  ['2 no ": " in a description', DS, 'or when told one is due, then after', 'or when told one is due: then after', ANY],
  ['2 setup says when', SE, " Use, after asking the person, when the layout is missing or a kept file is an earlier release's template.", '', ANY],
  ['2 status says when', ST, ' Use when asked how current the team memory is.', ' Use before a review or a dream.', ANY],
  ['2 tailor says when', TL, ' Use when asked to make or test an agent, skill or path rule here.', ' Use for agents.', ANY],
  ['2 map-review says when', MR, ' Use when proposals, drafts or due entries wait and the user agrees to review them.', ' Use after a dream.', ANY],
  // 3. the due line
  ['3 the due line is added', H, 'if (d) { notes.push(d); due = person && !held; }', 'if (d) notes.push(d);', ANY],
  ['3 the due line reaches the text', H, 'startText(idx, due).text', 'startText(idx).text', ANY],
  ['3 none in a headless session', H, "const person = !String(process.env.CLAUDE_CODE_ENTRYPOINT ?? '').startsWith('sdk-');", 'const person = true;', ANY],
  ['R2 every sdk- entry point is headless', H, "const person = !String(process.env.CLAUDE_CODE_ENTRYPOINT ?? '').startsWith('sdk-');", "const person = process.env.CLAUDE_CODE_ENTRYPOINT !== 'sdk-cli';", ANY],
  ['R11 no due line while a dream runs', H, 'due = person && !held;', 'due = person;', ANY],
  ['R11 the running dream still told', H, '      if (held) notes.push(held);\n', '', ANY],
  ['3 the line in the full text', MP, 'const full = idx ? `${INSTRUCTION}\\n\\n${idx}\\n${end}`', 'const full = idx ? `${INSTRUCTION}\\n\\n${idx}\\n${NAME}`', ANY],
  ['3 the line in a cut text', MP, '${notListed(dirs.length - k)}\\n\\n${end}`', '${notListed(dirs.length - k)}\\n\\n${NAME}`', ANY],
  ['3 the cap counts the line', MP, '+ 2 + head.length + 1 + 2 + end.length;', '+ 2 + head.length + 1 + 2 + NAME.length;', ANY],
  // 4. permissions in the README
  ['4 the README on permissions', RM, ' Each asks\n  your permission the first time. To allow them in advance, add rules such as `Skill(second-brain:dream)` to\n  `permissions.allow` in `.claude/settings.json`.', '', ANY],
  // 5. audit 6
  ["5 setup's grant", SE, 'hook.mjs" setup:*)', 'hook.mjs":*)', ANY],
  ["5 onboard's grant", ON, 'hook.mjs" onboard:*)', 'hook.mjs":*)', ANY],
  // 6. audit 2, the text half
  ['6 reject replaces the proposed line', MR, 'If it is committed, replace its `proposed` line with\n', 'If it is committed, add\n', ANY],
  // 7. L-2 and audit 5 in validate()
  ['7 a flagged skill starts with /<name>', TR, 'if (flagged && !new RegExp(', 'if (false && !new RegExp(', ANY],
  ['7 a skill prompt may not name it', TR, 'else if (!flagged && new RegExp(', 'else if (false && new RegExp(', ANY],
  ['7 the name as a command', TR, '`(?:^|\\\\s)/${e}(?![\\\\w-]|[./]\\\\w)|', '`', ANY],
  ['7 the name in backticks', TR, '|\\`${e}\\`|', '|', ANY],
  ['7 the name before "skill"', TR, '|(?<![\\\\w.-])["\']?${e}["\']?\\\\s+skill\\\\b', '', ANY],
  ['7 the name after "skill"', TR, '|\\\\bskill\\\\s+["\'\\`]?${e}(?![\\\\w.-])', '', ANY],
  ["7 only a skill's cases", TR, "  else if (kindOf(a) === 'skill') try { art", '  else try { art', ANY],
  ['R8 a command only after a space', TR, '`(?:^|\\\\s)/${e}', '`(?:^|[^\\\\w-])/${e}', ANY],
  ['R8 not a path under the name', TR, '(?![\\\\w-]|[./]\\\\w)|', '(?![\\\\w.-])|', ANY],
  ['R8 a quote after the name', TR, '["\']?${e}["\']?\\\\s+skill', '["\']?${e}\\\\s+skill', ANY],
  ["R8 the artifact's own folder", TR, '|skills/${e}/`', '`', ANY],
  ['R9 the read after the path checks', TR, "  else if (kindOf(a) === 'skill') try { art", "  if (kindOf(a) === 'skill') try { art", ANY],
  ['R9 a byte-order mark', TR, 'art.match(/^\\uFEFF?---', 'art.match(/^---', ANY],
  ['7 only a should-use case', TR, 'cases.filter((x) => x?.use !== false && typeof x?.prompt', 'cases.filter((x) => typeof x?.prompt', ANY],
  // 8. C-4
  ['8 cli hands cases over', TR, 'else if (c) console.log(', 'else if (false) console.log(', ANY],
  ['8 cases takes a home path', TR, "if (!HOMES.test(a) || a.split('/').includes('..')) throw new Error('cases takes", "if (false) throw new Error('cases takes", ANY],
  ['8 cases needs the file', TR, "if (!plainFile(path.join(root, a)) || !inRepo(root, path.join(root, a))) throw new Error(`not a plain file in the repo: ${a}`);", '', ANY],
  ["8 map-review's untested line names cases", MR, ', or, with no case file\n     `.project-map/evals/<name>.json`, `/second-brain:tailor cases <the draft\'s path>`, which writes its cases first', '', ANY],
  ['8 tailor does the cases step alone', TL, 'If it says to write only the cases, do steps 5 and 6 for that artifact. Otherwise, this', 'This', ANY],
  // 9. C-6
  ['9 the survey asks for the make line', TL, ': end with the question "Which one\n      should I make?" and, for each gap listed, the exact line to type with its name filled in, such as\n      `/second-brain:tailor make add-migration`.', ': ask them to type\n      `/second-brain:tailor make <name>` for the gap they pick.', ANY],
  // 10. P-3
  ['10 the analyzers get no usage.json', DS, '; nothing else (`usage.json` is\n   for step 3)', ', and the path of `.project-map/.dream-run/usage.json`', ANY],
  // 11. P-7
  ['11 the guidelines come with the making steps', TR, 'Follow the steps below.\\n\\n${guide()}`', 'Follow the steps below.`', ANY],
  ['11 the guidelines come with the cases step', TR, '`${casesFor(root, c[1])}\\n\\n${guide()}`', 'casesFor(root, c[1])', ANY],
  // 12. P-13, P-14
  ['12 the steering line no longer repeats', D, " as HEAD holds it.` : '',", " as HEAD holds it. Give its path to each analyzer with its digest.` : '',", ANY],
  ['12 the empty agent sentence goes', MR, 'which writes its cases first.\n', 'which writes its cases first. Agents are trialled only through cases that name them.\n', ANY],
  // 13. R-c
  ['13 the agent row', RM, '| A task that needs its own context, tools or notes | an entry here; offer the user an agent in `.claude/agents/` |\n', '', ANY],
  ["13 tailor's pointer", RM, '`/second-brain:tailor` makes a skill, agent or path rule as a draft, with the cases that test it. ', '', ANY],
  ['13 the dream line', RM, "A dream proposes\nentries and status lines, and drafts of path rules, skills, agents and changes to the repo's own,", 'A dream proposes skills and path rules as drafts,', ANY],
  ["13 the README's 2.5.1 text listed for setup", SU, "'293b97c319f11bf8', '15a4bb133893f00e']]", "'293b97c319f11bf8']]", ANY],
  // 14. R-d
  ['14 a retried finish before review', DS, ' A finish that stopped is\n   retried before any review: a retry puts back every change made to the map since prepare, a review\'s too.', '', ANY],
  ['14 a D line where the date changes', D, 'if (day !== (shown ?? String(first).slice(0, 10))) lines.push(`D: ${day}`);', '', ANY],
  ['14 the date moves on', D, 'lines.push(`D: ${day}`); shown = day; }', 'lines.push(`D: ${day}`); }', ANY],
  ["14 the D line comes before the read's line", D, "    if (day) { if (day !== (shown ?? String(first).slice(0, 10))) lines.push(`D: ${day}`); shown = day; }\n    // each reading call's own line: tag() gives an assistant record one line per text and per tool call, in order\n    const at = lines.length;\n",
    "    const at = lines.length;\n    if (day) { if (day !== (shown ?? String(first).slice(0, 10))) lines.push(`D: ${day}`); shown = day; }\n", ANY],
  ["R7 the first day while nothing is shown", D, 'if (day !== (shown ?? String(first).slice(0, 10)))', 'if (shown && day !== shown)', ANY],
  ['R4 a typed skill command has a line', D, "    if (cmd && (skills.has(cmd) || cmd.includes(':')) && !t.length) t = [`T: Skill ${one(cmd, 80)}`];\n", '', ANY],
  ['R4 only a skill command', D, "if (cmd && (skills.has(cmd) || cmd.includes(':')) && !t.length) t =", 'if (cmd && !t.length) t =', ANY],
  ['R4 the analyzer knows a typed skill', AN, ' (a\n  skill the user started by typing `/<name>` shows as a Skill call)', '', ANY],
  ['14 only a record with lines dates', D, 'const day = t.length && typeof r.timestamp', 'const day = typeof r.timestamp', ANY],
  // 15. X-6
  ['15 the delimiter is improbable', TL, "<<'SECOND_BRAIN_WORDS_q7Xk2Vw9'\n$ARGUMENTS\nSECOND_BRAIN_WORDS_q7Xk2Vw9\n", "<<'SECOND_BRAIN_WORDS'\n$ARGUMENTS\nSECOND_BRAIN_WORDS\n", ANY],
  // 16. L-5, L-7
  ['16 L-5 tailor reads without Bash', TL, ' Read the repo with Read, Grep and Glob, not Bash.', '', ANY],
  ['16 L-7 the shell stays out of the run folder', DS, ", from the repo's top, never from inside\n   `.project-map/.dream-run/`, which finish removes.", '.', ANY],
  // 17. the guidelines
  ['17 L-2 a skill case never names it', GD, " A skill's says the task, never the skill's\n  name (the trial refuses one that names it), since a prompt that names it tests the name.", '', ANY],
  ["17 L-2 an agent's case names it", GD, ' An agent\'s prompt names it, as "the\n  `<name>` agent, if this repo has one; otherwise do it yourself": Claude hands a new agent a task only by its name,\n  and the run without it then does the task itself.', ' An agent\'s prompt says "use the `<name>` agent to …".', ANY],
  ['17 L-17 a user-only skill starts with /<name>', GD, ' A skill only the user\n  starts is the exception: its prompt starts with `/<name>` (the trial checks).', '', ANY],
  ['17 L-12 a check reads facts from the copy', GD, "- **A check accepts any wording of the fact,** and reads what changes (a version, a step's state) from the copy's own\n  files, never from today's values: the trial copies the latest commit.\n", '', ANY],
  ['17 L-22 a test of the checks', GD, '- **A test of the checks** matches each fact exactly as its check does.', '-', ANY],
  ['17 Q-5 memory is not a guard', GD, ' It also turns on Read, Write and Edit with\n  no path scope, whatever `tools` says: a body\'s "your writes go only to …" is an instruction, not a guard.', '', ANY],
  // the review fixes' texts (R1, R5, R6, R10, R12)
  ['R1 a made artifact stays a draft', TL, 'A made artifact stays a draft, which Claude Code never loads, until the person promotes it in `/map-review`, which\nshows its trial verdict first. ', '', ANY],
  ["R5 a should-use case's prompt", GD, "- **A should-use case's prompt** reaches the artifact as a person would.", "- **A case's prompt** reaches the artifact as a person would.", ANY],
  ['R5 the should-not case never invokes it', GD, "- **The case where it should not be used** (`use: false`) never invokes it: no `/<name>`, and no agent's name.\n", '', ANY],
  ["R5 tailor's step 5 points to the guidelines", TL, "   - Its prompts follow the guidelines' cases section.", "   - The prompts follow the guidelines' cases section: a skill's never names it, an agent's always does.", ANY],
  ['R6 make <name> is a pick', TL, " So does `make <name>`: the person's pick of a gap a survey listed, with its evidence.", '', ANY],
  ['R10 cases without one path', TR, "      else if (/^cases\\b/.test(words)) console.log('Use: /second-brain:tailor cases", "      else if (false) console.log('Use: /second-brain:tailor cases", ANY],
  ['R12 the leave-out rules once', TL, "   3. **Say what you will not make, and why,** by the guidelines' first section.", '   3. **Say what you will not make, and why:** Claude does it anyway, the repo already shows it, or the evidence is\n      thin.', ANY],
  ['R12 the agent row once', TL, 'with why.\n', 'with why. An agent\n      only for a task that needs its own context, its own tools or its own notes.\n', ANY],
  ['R12 grounding once', TL, '3. **Grounding,** as the guidelines say.', '3. **Grounding,** as the guidelines say: keep only what Claude cannot infer from the repo.', ANY],
  // 18. L-16
  ['18 discard says what becomes of the case file', MR, ' Its case file and checks (`.project-map/evals/<name>.json`, `.project-map/evals/checks/`)\n     still name it: ask whether to delete them too, or keep them for a new draft at the same path.', '', ANY],
  // 19. tailor's description
  ['19 tailor does not claim to change', TL, 'and writes the cases that test a draft or an artifact against a run without it', 'and tests a draft or an artifact against a run without it', ANY],
  // 20. Q-15, the hook half
  ['20 undone.txt is told', H, 'fs.rmSync(f); if (u) notes.push(u); }', 'fs.rmSync(f); }', ANY],
  ['20 undone.txt is told once', H, "const u = fs.readFileSync(f, 'utf8').trim(); fs.rmSync(f);", "const u = fs.readFileSync(f, 'utf8').trim();", ANY],
  ['20 a headless session leaves undone.txt', H, "      if (person) try { const f = path.join(stateDir(root, data), 'undone.txt');", "      try { const f = path.join(stateDir(root, data), 'undone.txt');", ANY],
  // 21. the analyzer's text
  ['21 the cut mark', AN, 'A U or Q line that ends `…[cut at N of M characters]` was cut: quote only what it shows. ', '', ANY],
  ['21 the sdk-cli mark', AN, "A line marked\n`[sdk-cli: not shown to be the person's]` came through `claude -p`, perhaps from another program. You may cite it: add\n` (marked sdk-cli)` after the statement, and the person weighs it at review. ", '', ANY],
  // 8l attempt 2 (06): the texts that failed the counted runs
  ['A1 an sdk-cli line may be cited', AN, ". You may cite it: add\n` (marked sdk-cli)` after the statement, and the person weighs it at review.", ": weigh it, but never\nquote it as the person's own rule.", ANY],
  ['A3 a check tested by one plain command', GD, ' Run each check with one plain\n  `node <check file>` command: no `$()`, `&&`, pipes or PowerShell.', '', ANY],
  ['A5 the run line on its own line', TL, ', with the `! node` line on a line of its own, exactly as printed: not quoted, not in code marks.', '.', ANY],
  ['A6 no scratch file to test a check', GD, ' Write no other file to test it.', '', ANY],
  ['A4 the dream runs commands through Bash', DS, ' with the Bash tool, never PowerShell (the grant covers Bash)', '', ANY],
  ['A4 tailor runs commands through Bash', TL, '\nRun `draft`, and any test of a check, with the Bash tool, never PowerShell: the grant covers Bash.', '', ANY],
  ['A4 status runs commands through Bash', ST, ' Run any command with the Bash tool, never PowerShell.', '', ANY],
  ['A4 map-review runs commands through Bash', MR, ' Run its\ncommands with the Bash tool, never PowerShell.', '', ANY],
  ["A4 map-review's 8l text listed for setup", SU, ", '6d3e35da1c6033c9', '7e5d413c03dfa3ea']]", ", '6d3e35da1c6033c9']]", ANY],
  ["21 L-9 the correction's topic", AN, ' When the work it corrects falls under a map topic file,\n    end the line with ` | <topic>.md`, that file\'s name.', '', ANY],
  ['21 the D line', AN, '- **D:** the date from that line on, where it changes.\n', '', ANY],
  // 22. the README's 8k and audit items
  ['22 index.ignore in the README', RM, "- **`index.ignore`** in this folder leaves folders out of the document index: one folder or glob pattern per line,\n  from the repo's root, such as `docs/archive` or `**/fixtures`; `#` starts a comment. This folder is always listed.\n  When git rejects a line, the file is not used that session, and you are told.\n", '', ANY],
  ['22 [private] in the README', RM, ' In its digests, `[private]` stands for text removed as private, which no proposal quotes.', '', ANY],
  // 23. D34 without the flag
  ['23 tailor never runs a trial itself', TL, 'Never run `trial.mjs` yourself except `draft` in step 4', 'Run `trial.mjs` when it helps', ANY],
  ['23 tailor grants cli and draft only', TL, 'trial.mjs" cli:*), Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" draft:*)', 'trial.mjs":*)', ANY],
];
const here = (os) => os === ANY || process.platform === os;
const fast = Boolean(process.env.MUT_FAST);
const only = process.env.MUT_ONLY ? new RegExp(process.env.MUT_ONLY) : null;
const tests = fast ? ['fix8l.mjs'] : ['selftest.mjs'];
const lines = [`platform ${process.platform}, node ${process.version}, ${fast ? 'fix8l' : 'the self-test'}${only ? ' (a dry run)' : ''}`];
// each test in turn, stopping at the first that fails; the failing lines name the cases
const runIn = (dir) => {
  for (const t of tests) {
    const r = spawnSync(process.execPath, [path.join(dir, 'plugin', 'test', t)], { encoding: 'utf8', timeout: 1_200_000 });
    if (r.status !== 0) return { ...r, test: t };
  }
  return { status: 0, stdout: '', stderr: '' };
};
const copy = (dir) => {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(plugin, path.join(dir, 'plugin'), { recursive: true });
  const t = path.join(dir, 'plugin/test/selftest.mjs');
  const pin = "assert.equal(product.digest('hex').slice(0, 12), ";
  fs.writeFileSync(t, fs.readFileSync(t, 'utf8').replace(pin, `if (0) ${pin}`));
};
const dir = path.join(work, 'm');
copy(dir);
const baseRun = runIn(dir);
if (baseRun.status !== 0) {
  console.log(`the unmutated copy fails ${baseRun.test}, so no mutation is counted:\n${baseRun.stdout.split('\n').filter((l) => l.startsWith('FAIL')).join('\n')}${baseRun.stderr.slice(-600)}`);
  process.exit(2);
}
let bad = 0, ran = 0;
for (const [name, file, a, b, os] of M) {
  if (only && !only.test(name)) continue;
  if (!here(os)) { lines.push(`not here  ${name} (${os})`); console.log(lines.at(-1)); continue; }
  ran++;
  copy(dir);
  const target = path.join(dir, 'plugin', file);
  const src = fs.readFileSync(target, 'utf8');
  if (src.split(a).length !== 2) { lines.push(`MISSING   ${name}`); console.log(lines.at(-1)); bad++; continue; }
  fs.writeFileSync(target, src.replace(a, () => b));
  const r = runIn(dir);
  const killed = r.status !== 0;
  if (!killed) bad++;
  const by = (r.stdout ?? '').split('\n').filter((l) => l.startsWith('FAIL')).map((l) => l.slice(6).split(':')[0]);
  lines.push(`${killed ? 'killed   ' : 'SURVIVED '} ${name}${killed ? ` (by ${r.test}${by.length ? `: ${by.join('; ')}` : `, exit ${r.status}${r.error ? ` ${r.error.code}` : ''}`})` : ''}`);
  console.log(lines.at(-1));
}
lines.push(`${ran - bad} of ${ran} killed${bad ? `; ${bad} survived or could not be applied` : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
if (!only) {
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `mutate8l-${process.platform}.txt`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${lines.join('\n')}\n`);
}
console.log(lines.at(-1));
process.exitCode = bad ? 1 : 0;
