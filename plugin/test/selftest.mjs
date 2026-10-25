// The skeleton's self-test (06, step 2a): the frozen texts, the surfaces, and each hook run as a process in a
// temporary git repo.   node plugin/test/selftest.mjs
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { INSTRUCTION, HEADER, FORCE, UNREVIEWED, index, labels } from '../scripts/map.mjs';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');

// the texts, as the ledger fixed them
assert.equal(crypto.createHash('sha256').update(INSTRUCTION).digest('hex').slice(0, 12), '8aa72396af72');
assert.equal(Buffer.byteLength(INSTRUCTION), 904);
assert.equal(Buffer.byteLength(FORCE), 227);
assert.equal(HEADER, "IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project. This project's documents, by directory:");
assert.equal(UNREVIEWED, 'unreviewed, not yet committed');

// the surfaces: 3 hook events, 1 command, no agents, skills or MCP servers
const { hooks } = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
assert.deepEqual(Object.keys(hooks), ['SessionStart', 'UserPromptSubmit', 'PostToolUse']);
assert.equal(hooks.SessionStart[0].matcher, 'startup|clear|resume|compact');
assert.ok(hooks.SessionStart[0].hooks[0].command.includes('The project map needs Node 20 or later; install it, or disable the plugin.'));
assert.equal(hooks.PostToolUse[0].matcher, 'Read');
assert.deepEqual(fs.readdirSync(path.join(PLUGIN, 'commands')), ['onboard.md']);
for (const d of ['agents', 'skills', '.mcp.json']) assert.ok(!fs.existsSync(path.join(PLUGIN, d)), d);

// a repo: tracked documents in two directories, a non-document, an untracked document, a committed map entry
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-selftest-'));
const repo = path.join(tmp, 'repo');
const put = (f, s) => { fs.mkdirSync(path.dirname(path.join(repo, f)), { recursive: true }); fs.writeFileSync(path.join(repo, f), s); };
const git = (...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };
const entry = (area, q, d) => `### ${area}\n> ${q}\n\n- source: the lead developer, ${d}\n- when: ["components"]\n`;
fs.mkdirSync(repo);
git('init', '-q');
put('README.md', '# r\n');
put('docs/style.md', 'x\n');
put('docs/Guide.RST', 'x\n');
put('src/a.ts', 'x\n');
put(`.project-map/captured.md`, entry('components', 'Each component keeps its files in its own folder.', '2026-10-20'));
git('add', '-A');
git('commit', '-q', '-m', 'init');
put('notes.txt', 'untracked, not listed\n');
put('.project-map/captured.md', `${entry('components', 'Each component keeps its files in its own folder.', '2026-10-20')}\n${entry('avatars', 'Avatars load locally, never from the CDN.', '2026-10-24')}`);
put('.project-map/new.md', entry('x', 'y', '2026-10-25'));

// directories in git's path order, as D22's inventory.mjs gave them
assert.equal(index(repo), `${HEADER}\n.project-map/: captured.md, new.md\n./: README.md\ndocs/: Guide.RST, style.md\n`);
assert.equal(labels(repo, '.project-map/captured.md'), '[project map] Labels on the entries of .project-map/captured.md, in file order:\n'
  + '1. components: unverified quote, captured 2026-10-20\n'
  + `2. avatars: ${UNREVIEWED}; unverified quote, captured 2026-10-24\n`);
assert.equal(labels(repo, '.project-map/new.md'), '[project map] Labels on the entries of .project-map/new.md, in file order:\n'
  + `1. x: ${UNREVIEWED}; unverified quote, captured 2026-10-25\n`);

// each hook as a process, as Claude Code runs it
const hook = (which, input, dir = repo) => {
  const r = spawnSync('node', [HOOK, which], { input: JSON.stringify({ cwd: dir, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: dir } });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.additionalContext : '';
};
const sid = `selftest-${process.pid}`;
assert.equal(hook('session-start', { session_id: sid, source: 'startup' }), `${INSTRUCTION}\n\n${index(repo)}`);
assert.equal(hook('prompt', { session_id: sid }), FORCE);
assert.equal(hook('prompt', { session_id: sid }), '');
hook('session-start', { session_id: sid, source: 'compact' });
assert.equal(hook('prompt', { session_id: sid }), FORCE);
assert.equal(hook('read', { tool_input: { file_path: path.join(repo, 'docs', 'style.md') } }), '');
assert.equal(hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }), labels(repo, '.project-map/captured.md'));

// outside git: no index, no forced decision, every entry unreviewed
const loose = path.join(tmp, 'loose');
fs.mkdirSync(path.join(loose, '.project-map'), { recursive: true });
fs.writeFileSync(path.join(loose, '.project-map', 'captured.md'), entry('a', 'b', '2026-10-25'));
assert.equal(index(loose), null);
assert.equal(hook('session-start', { session_id: `${sid}-loose` }, loose), INSTRUCTION);
assert.equal(hook('prompt', { session_id: `${sid}-loose` }, loose), '');
assert.ok(labels(loose, '.project-map/captured.md').includes(`1. a: ${UNREVIEWED}; unverified quote, captured 2026-10-25`));

// a repo with no documents: an empty index, the instruction alone
const bare = path.join(tmp, 'bare');
fs.mkdirSync(bare);
spawnSync('git', ['init', '-q'], { cwd: bare });
assert.equal(index(bare), '');
assert.equal(hook('session-start', { session_id: `${sid}-bare` }, bare), INSTRUCTION);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('selftest ok');
