// The self-test's stand-in for claude in a trial (7a): it records its arguments, environment and what it sees, edits
// one file, and prints a fixed stream that calls the demo skill only when that skill is at its live path
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const live = '.claude/skills/demo/SKILL.md';
const sees = fs.existsSync(live) ? fs.readFileSync(live, 'utf8') : null;
fs.appendFileSync(process.env.STUB_LOG, `${JSON.stringify({
  cwd: process.cwd(),
  args: process.argv.slice(2),
  env: { CLAUDECODE: process.env.CLAUDECODE ?? null, CLAUDE_CODE_ENTRYPOINT: process.env.CLAUDE_CODE_ENTRYPOINT ?? null },
  sees,
  draftThere: fs.existsSync(`${live}.draft`),
  ignoredThere: fs.existsSync('secret.txt'),
  commits: spawnSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).stdout.trim(),
})}\n`);
fs.writeFileSync('made-by-stub.txt', 'x\n');
const content = sees ? [{ type: 'tool_use', id: 't1', name: 'Skill', input: { skill: 'demo' } }] : [];
console.log(JSON.stringify({ type: 'assistant', message: { content } }));
console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: 'done' }));
