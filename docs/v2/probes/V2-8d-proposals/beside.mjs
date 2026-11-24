// 06, section 8, 8d, check 1b (the decision-checker's D31 point): a change draft, SKILL.md.draft beside a live SKILL.md,
// stays inert. A repo whose skill "greet" says HELLO-LIVE, with a draft beside it that says HELLO-DRAFT; 3 runs where a
// person types /greet and 3 where Claude starts it. Pass: every run answers HELLO-LIVE, none says HELLO-DRAFT, and no
// tool call names the draft. Counts only.
//   D17_CLAUDE=<pinned CLI> node beside.mjs <scratch>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const scratch = path.resolve(process.argv[2]);
const CLAUDE = process.env.D17_CLAUDE || 'claude';
const env = { ...process.env };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
const repo = path.join(scratch, 'beside-repo');
fs.rmSync(repo, { recursive: true, force: true });
const d = path.join(repo, '.claude', 'skills', 'greet');
fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(path.join(d, 'SKILL.md'), '---\nname: greet\ndescription: Greets the user. Use when asked to greet.\n---\nReply with exactly this word and nothing else: HELLO-LIVE\n');
fs.writeFileSync(path.join(d, 'SKILL.md.draft'), '---\nname: greet\ndescription: Greets the user. Use when asked to greet.\n---\nReply with exactly this word and nothing else: HELLO-DRAFT\n');
spawnSync('git', ['init', '-q'], { cwd: repo });
const rows = [];
for (const [how, prompt] of [['typed', '/greet'], ['typed', '/greet'], ['typed', '/greet'], ['model', 'Greet me, using the skill for it.'], ['model', 'Greet me, using the skill for it.'], ['model', 'Greet me, using the skill for it.']]) {
  const r = spawnSync(CLAUDE, ['-p', prompt, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--output-format', 'stream-json', '--verbose'], { cwd: repo, env, encoding: 'utf8', timeout: 600_000 });
  const out = r.stdout ?? '';
  const calls = out.split('\n').filter((l) => l.includes('"tool_use"')).join('\n');
  rows.push({ how, live: out.includes('HELLO-LIVE'), draft: out.includes('HELLO-DRAFT'), draftNamed: /SKILL\.md\.draft/.test(calls) });
  console.log(JSON.stringify(rows.at(-1)));
}
const res = { rows, pass: rows.length === 6 && rows.every((x) => x.live && !x.draft && !x.draftNamed) };
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'beside.json'), `${JSON.stringify(res, null, 1)}\n`);
console.log(JSON.stringify({ pass: res.pass }));
