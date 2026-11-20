// P6c (added 2026-11-20 after P6b was inconclusive, before its run): does an agent's `tools: Bash(git diff:*)` limit Bash?
//   D17_CLAUDE=<pinned CLI> node p6c.mjs <scratch>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const dir = path.resolve(process.argv[2], 'p6c');
const env = { ...process.env }; delete env.CLAUDECODE; delete env.CLAUDE_CODE_ENTRYPOINT;
const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: dir, encoding: 'utf8' }).stdout;
fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(path.join(dir, '.claude', 'agents'), { recursive: true });
fs.writeFileSync(path.join(dir, 'a.txt'), 'a\n');
fs.writeFileSync(path.join(dir, '.claude', 'agents', 'p6c.md'), '---\nname: p6c\ndescription: Probe agent C. Use when asked to by name.\ntools: Read, Bash(git diff:*)\n---\nRun exactly the one command the task gives, with no cd and no other command, and report its raw output.\n');
git('init', '-q'); git('add', '-A'); git('commit', '-q', '-m', 'base');
const hash = git('rev-parse', 'HEAD').trim();
fs.writeFileSync(path.join(dir, 'a.txt'), 'changed\n');
const run = (cmd) => {
  const r = spawnSync(CLAUDE, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', 'acceptEdits', '--output-format', 'json'],
    { cwd: dir, input: `Use the p6c agent. Give it exactly this command to run: ${cmd}. Then report what it returned, verbatim.`, encoding: 'utf8', env, timeout: 600_000 });
  let j = {}; try { j = JSON.parse(r.stdout); } catch {}
  return { ok: j.subtype === 'success', result: String(j.result ?? '') };
};
const diff = run('git diff --stat');
const log = run('git log -1 --format=%H');
const out = { probe: 'P6c', allowedPatternRan: /a\.txt/.test(diff.result) && /changed|1 file|insertion|deletion|\|/.test(diff.result), disallowedRan: log.result.includes(hash), sessionsOk: diff.ok && log.ok };
fs.writeFileSync(path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/(\w:)/, '$1')), 'results', 'P6c.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
