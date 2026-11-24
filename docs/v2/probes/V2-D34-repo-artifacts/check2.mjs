// 06, section 7, 7a, check 2: the trial runner, live. A scratch repo holds a skill draft and an agent draft, each with
// three cases; trial.mjs runs them with real claude sessions behind a wrapper that keeps each session's stream. The
// trial's "used" must match the stream's own tool calls in every record, with a true positive per kind, and the repo
// must be unchanged.
//   node check2.mjs <candidate plugin folder> <work folder>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const [plugin, work] = process.argv.slice(2).map((p) => path.resolve(p));
const { run } = await import(pathToFileURL(path.join(plugin, 'scripts', 'trial.mjs')).href);
const repo = path.join(work, 'repo'), data = path.join(work, 'data'), logs = path.join(work, 'streams');
fs.rmSync(work, { recursive: true, force: true });
const put = (f, t) => { fs.mkdirSync(path.dirname(path.join(repo, f)), { recursive: true }); fs.writeFileSync(path.join(repo, f), t); };
const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo, encoding: 'utf8' });
fs.mkdirSync(repo, { recursive: true });
g('init', '-q');
put('src/math.js', 'export const add = (a, b) => a + b;\nexport const sub = (a, b) => a - b;\n');
put('README.md', '# math\nTwo helpers.\n');
g('add', '-A');
g('commit', '-qm', 'init');
put('.claude/skills/change-entry/SKILL.md.draft', '---\nname: change-entry\ndescription: Records a change in this repo\'s change log. Use when the user asks to note, log or record a change.\n---\nWrite the entry to `changes/<YYYY-MM-DD>-<slug>.md` (today\'s date, a kebab-case slug), with front matter `kind: added|changed|fixed` and one sentence. Done when the file exists.\n');
put('.claude/agents/api-auditor.md.draft', '---\nname: api-auditor\ndescription: Lists the exported functions of this repo with file and line. Use when asked what this library exports.\ntools: Read, Grep, Glob\n---\nList every exported function in src/ as `name - file:line`. Use Grep. Return only the list.\n');
put('.project-map/evals/change-entry.json', JSON.stringify({ artifact: '.claude/skills/change-entry/SKILL.md.draft', cases: [
  { id: 'log-add', prompt: 'Please log that we added the add() helper.', expect: 'a new file changes/<date>-<slug>.md with kind: added' },
  { id: 'log-fix', prompt: 'Record in the change log that sub() was fixed.', expect: 'a new file changes/<date>-<slug>.md with kind: fixed' },
  { id: 'question', prompt: 'What does add() return for 2 and 3? Answer only.', expect: 'the reply says 5, and no file changes', use: false },
] }, null, 1));
put('.project-map/evals/api-auditor.json', JSON.stringify({ artifact: '.claude/agents/api-auditor.md.draft', cases: [
  { id: 'list', prompt: 'Use the api-auditor agent to list what this library exports.', expect: 'add and sub, with src/math.js and their lines' },
  { id: 'which', prompt: 'Ask the api-auditor agent which functions src/math.js exports.', expect: 'add and sub' },
  { id: 'rename', prompt: 'Rename sub to subtract in src/math.js.', expect: 'src/math.js exports subtract, not sub', use: false },
] }, null, 1));
const snap = () => JSON.stringify([g('status', '--porcelain').stdout, ...['src/math.js', '.claude/skills/change-entry/SKILL.md.draft', '.claude/agents/api-auditor.md.draft'].map((f) => fs.readFileSync(path.join(repo, f), 'utf8'))]);
const before = snap();
// the wrapper: runs the real claude and keeps a copy of its stream, keyed by the copy's folder name
fs.mkdirSync(logs, { recursive: true });
const tee = path.join(work, 'tee.mjs');
fs.writeFileSync(tee, `import { spawn } from 'node:child_process';\nimport fs from 'node:fs';\nimport path from 'node:path';\nconst c = spawn('claude', process.argv.slice(2), { stdio: ['ignore', 'pipe', 'inherit'] });\nconst out = fs.createWriteStream(path.join(${JSON.stringify(logs)}, path.basename(process.cwd()) + '-' + Date.now() + '.jsonl'));\nc.stdout.on('data', (d) => { process.stdout.write(d); out.write(d); });\nc.on('close', (code) => { out.end(); process.exitCode = code ?? 0; });\n`);
process.env.SECOND_BRAIN_TRIAL_CLAUDE = tee;
const results = {};
for (const [name, kind] of [['change-entry', 'skill'], ['api-auditor', 'agent']]) {
  const r = await run(repo, name, data, 3);
  const key = JSON.parse(fs.readFileSync(r.key, 'utf8')).runs;
  const rows = Object.entries(key).map(([id, k]) => {
    const file = fs.readdirSync(logs).find((f) => f.startsWith(`${id}-`) && !Object.values(results).flat().some((x) => x.file === f));
    const tools = fs.readFileSync(path.join(logs, file), 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
      .filter((x) => x?.type === 'assistant').flatMap((x) => (x.message?.content ?? []).filter((c) => c.type === 'tool_use'));
    const raw = tools.some((t) => (kind === 'skill' ? t.name === 'Skill' && String(t.input?.skill ?? '').endsWith(name) : ['Agent', 'Task'].includes(t.name) && t.input?.subagent_type === name));
    return { id, file, arm: k.arm, case: k.case, used: k.used, raw, match: k.used === raw };
  });
  results[name] = rows;
  fs.rmSync(logs, { recursive: true, force: true });
  fs.mkdirSync(logs, { recursive: true });
}
const all = Object.values(results).flat();
const summary = {
  records: all.length,
  matches: all.filter((x) => x.match).length,
  truePositives: Object.fromEntries(Object.entries(results).map(([n, rows]) => [n, rows.filter((x) => x.used && x.raw).length])),
  usedByArm: Object.fromEntries(Object.entries(results).map(([n, rows]) => [n, rows.map((x) => `${x.arm}/${x.case}:${x.used}`)])),
  repoUnchanged: snap() === before,
};
console.log(JSON.stringify(summary, null, 1));
