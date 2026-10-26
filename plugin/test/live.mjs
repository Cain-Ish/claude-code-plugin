// 06, step 2f: the plugin as a user installs it (from a marketplace, no --plugin-dir), checked live in a repo where it is
// installed at project scope. Delivery and onboarding on Haiku, capture on Opus.
//   node plugin/test/live.mjs <repo with the plugin installed> [claude binary]
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [repo, claude = 'claude'] = process.argv.slice(2);
const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
// project and local settings only: the install lives there, and the user's other plugins and servers stay out
const session = (input, model, deny = 'Bash,Grep,Glob,WebFetch,WebSearch') => {
  const r = spawnSync(claude, ['-p', '--model', model, '--setting-sources', 'project,local', '--strict-mcp-config',
    ...(deny ? ['--disallowedTools', deny] : []), '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose',
    '--include-hook-events'], { cwd: repo, input, encoding: 'utf8', env, timeout: 900_000, maxBuffer: 64 << 20 });
  return r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
};
const resultOf = (ev) => ev.findLast((e) => e.type === 'result')?.result ?? '';
const out = {};

// 1. delivery: 2a's smoke prompt
const ev = session('Do three things, then reply with only the three results, numbered. (1) Quote word for word the sentence in your '
  + 'context that begins "IMPORTANT: Prefer retrieval-led". (2) Quote word for word the instruction in your context that begins "Before '
  + 'you start". (3) Use the Read tool on .project-map/captured.md, then quote word for word the labels a hook added after that read.', 'claude-haiku-5-5');
const init = ev.find((e) => e.subtype === 'init');
const start = ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === 'SessionStart').map((e) => String(e.output ?? '')).join('\n');
out.delivery = { cli: init?.claude_code_version, plugin: init?.plugins?.find((p) => p.name === 'second-brain')?.source, nameLine: start.includes('When you finish, name each'), reply: resultOf(ev) };

// 2. onboarding, as a user types it (its !-line runs node, so this session keeps Bash)
out.onboard = resultOf(session('/second-brain:onboard', 'claude-haiku-5-5', null));

// 3. capture: a decision stated in passing, on the user's model
const before = fs.readFileSync(path.join(repo, '.project-map', 'captured.md'), 'utf8');
out.captureReply = resultOf(session('Small task: add a line "Maintained by the design team." under the heading of docs/style.md. Also, the tech '
  + 'lead decided today that from now on every API handler in this project logs its request id.', 'claude-opus-5-5'));
const added = fs.readFileSync(path.join(repo, '.project-map', 'captured.md'), 'utf8').slice(before.length);
out.captured = added;
console.log(JSON.stringify(out, null, 1));

assert.ok(out.delivery.plugin === 'second-brain@second-brain-v2', 'installed plugin listed');
assert.ok(out.delivery.reply.includes('IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project.'), 'index');
assert.ok(out.delivery.reply.includes("for each directory in this project's document index"), 'forced decision');
assert.ok(out.delivery.reply.includes('unreviewed, not yet committed'), 'read labels');
assert.ok(out.delivery.nameLine, "D23's line at session start");
assert.ok(/documents? in \d+ director/i.test(out.onboard), 'onboarding');
assert.ok(/request id/i.test(added) && /^- source:\s*\S/m.test(added), 'capture');
console.log('live ok');
