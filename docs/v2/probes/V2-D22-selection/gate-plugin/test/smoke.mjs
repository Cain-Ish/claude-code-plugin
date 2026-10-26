// The skeleton's smoke (06, step 2a): one Haiku session loads the plugin with --plugin-dir, as a user would, and quotes
// what each hook put in its context. Not counted in any eval.   node plugin/test/smoke.mjs <claude binary>
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const claude = process.argv[2] ?? 'claude';
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-smoke-'));
const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo });
const entry = (area, q, d) => `### ${area}\n> ${q}\n\n- source: the lead developer, ${d}\n- when: ["components"]\n`;
fs.mkdirSync(path.join(repo, 'docs'));
fs.mkdirSync(path.join(repo, '.project-map'));
fs.writeFileSync(path.join(repo, 'docs', 'style.md'), '# Style\n\nComponents use named exports.\n');
fs.writeFileSync(path.join(repo, '.project-map', 'captured.md'), entry('components', 'Each component keeps its files in its own folder.', '2026-10-20'));
git('init', '-q');
git('add', '-A');
git('commit', '-q', '-m', 'init');
fs.appendFileSync(path.join(repo, '.project-map', 'captured.md'), `\n${entry('avatars', 'Avatars load locally, never from the CDN.', '2026-10-24')}`);

// (1) in D22's smoke wording: attempt 1 asked for "the first sentence of the document index", and Haiku quoted the
// index line's second sentence
const prompt = 'Do three things, then reply with only the three results, numbered. (1) Quote word for word the sentence in '
  + 'your context that begins "IMPORTANT: Prefer retrieval-led". (2) Quote word for word the instruction in your context that '
  + 'begins "Before you start". (3) Use the Read tool on .project-map/captured.md, then quote word for word the labels a '
  + 'hook added after that read.';
const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
// one session; the onboarding command runs node through its !-line, so that session keeps Bash, as a user's would
const session = (input, deny = 'Bash,Grep,Glob,WebFetch,WebSearch') => {
  const r = spawnSync(claude, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config',
    '--plugin-dir', PLUGIN, ...(deny ? ['--disallowedTools', deny] : []), '--permission-mode', 'acceptEdits',
    '--output-format', 'stream-json', '--verbose', '--include-hook-events'], { cwd: repo, input, encoding: 'utf8', env, timeout: 600_000, maxBuffer: 64 << 20 });
  return r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
};
const ev = session(prompt);
const init = ev.find((e) => e.subtype === 'init');
const reply = ev.findLast((e) => e.type === 'result')?.result ?? '';
const hookEvents = ev.filter((e) => e.subtype === 'hook_response').map((e) => ({ event: e.hook_event, exit: e.exit_code, output: String(e.output ?? e.stdout ?? '').slice(0, 160) }));
console.log(JSON.stringify({ cli: init?.claude_code_version, model: init?.model, plugin: init?.plugins?.find((p) => p.name === 'second-brain'), hookEvents, reply }, null, 1));
// 2b: the onboarding command, as a user types it
const onboard = session('/second-brain:onboard', null).findLast((e) => e.type === 'result')?.result ?? '';
console.log(JSON.stringify({ onboard }));
fs.rmSync(repo, { recursive: true, force: true });

assert.ok(reply.includes('IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project.'), 'index');
assert.ok(reply.includes("for each directory in this project's document index"), 'forced decision');
assert.ok(reply.includes('unreviewed, not yet committed') && reply.includes('unverified quote, captured 2026-10-24'), 'read labels');
assert.ok(/documents? in \d+ director/i.test(onboard), 'onboarding');
console.log('smoke ok');
