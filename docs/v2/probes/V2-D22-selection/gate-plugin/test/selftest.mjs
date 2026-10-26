// The skeleton's self-test (06, step 2a): the frozen texts, the surfaces, and each hook run as a process in a
// temporary git repo.   node plugin/test/selftest.mjs
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { INSTRUCTION, HEADER, FORCE, NAME, UNREVIEWED, GATE, index, labels } from '../scripts/map.mjs';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const GATE_HASH = '393f811a837a'; // GATE('<dir>'), 244 bytes plus the directory
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');

// the texts, as the ledger fixed them
assert.equal(crypto.createHash('sha256').update(INSTRUCTION).digest('hex').slice(0, 12), '8aa72396af72');
assert.equal(Buffer.byteLength(INSTRUCTION), 904);
assert.equal(Buffer.byteLength(FORCE), 227);
assert.equal(HEADER, "IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project. This project's documents, by directory:");
assert.equal(UNREVIEWED, 'unreviewed, not yet committed');
// V2-D23's line, as the ledger froze it
assert.equal(NAME, "When you finish, name each of this project's recorded decisions you followed and its source, as the map entry or document gives it. Do not name a decision you did not follow, or a source the record does not give.");

// D22 option (A)'s gate text, frozen with its check
assert.equal(crypto.createHash('sha256').update(GATE('<dir>')).digest('hex').slice(0, 12), GATE_HASH);

// the surfaces: 4 hook events (D22 option (A) adds PreToolUse), 1 command, no agents, skills or MCP servers
const { hooks } = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
assert.deepEqual(Object.keys(hooks), ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse']);
assert.equal(hooks.PreToolUse[0].matcher, 'Write|Edit|MultiEdit');
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

// D16, option (b): a source that names a repo file is re-found in it now; a miss claims nothing about change
put('docs/style.md', '# Style\n\nColours come only from the theme tokens. No hex values anywhere.\n');
const cited = (area, q, src) => `### ${area}\n> ${q}\n\n- source: ${src}\n- when: ["ui"]\n`;
put('.project-map/cited.md', [
  cited('verbatim', 'Colours come only from the theme tokens.', 'docs/style.md (the client), 2026-10-22'),
  cited('condensed', 'Colours: theme tokens only, never hex.', 'the client style guide, docs/style.md, 2026-10-22'),
  cited('gone', 'Avatars load locally.', 'docs/avatars.md, 2026-10-22'),
  cited('outside', 'Colours come only from the theme tokens.', '../repo/docs/style.md, 2026-10-22'),
].join('\n'));
assert.equal(labels(repo, '.project-map/cited.md'), '[project map] Labels on the entries of .project-map/cited.md, in file order:\n'
  + `1. verbatim: ${UNREVIEWED}\n`
  + `2. condensed: ${UNREVIEWED}; not found word for word in docs/style.md; check it, captured 2026-10-22\n`
  + `3. gone: ${UNREVIEWED}; not found word for word in docs/avatars.md; check it, captured 2026-10-22\n`
  + `4. outside: ${UNREVIEWED}; unverified quote, captured 2026-10-22\n`);
git('add', '-A');
git('commit', '-q', '-m', 'cited');
assert.equal(labels(repo, '.project-map/cited.md'), '[project map] Labels on the entries of .project-map/cited.md, in file order:\n'
  + '2. condensed: not found word for word in docs/style.md; check it, captured 2026-10-22\n'
  + '3. gone: not found word for word in docs/avatars.md; check it, captured 2026-10-22\n'
  + '4. outside: unverified quote, captured 2026-10-22\n');
put('docs/style.md', '# Style\n\nColours come from the theme tokens. No hex values anywhere.\n');
assert.ok(labels(repo, '.project-map/cited.md').includes('1. verbatim: not found word for word in docs/style.md; check it, captured 2026-10-22'));

// each hook as a process, as Claude Code runs it
const hook = (which, input, dir = repo) => {
  const r = spawnSync('node', [HOOK, which], { input: JSON.stringify({ cwd: dir, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: dir } });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.additionalContext : '';
};
const sid = `selftest-${process.pid}`;
assert.equal(hook('session-start', { session_id: sid, source: 'startup' }), `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
assert.equal(hook('prompt', { session_id: sid }), FORCE);
assert.equal(hook('prompt', { session_id: sid }), '');
hook('session-start', { session_id: sid, source: 'compact' });
assert.equal(hook('prompt', { session_id: sid }), FORCE);
assert.equal(hook('read', { tool_input: { file_path: path.join(repo, 'docs', 'style.md') } }), '');
assert.equal(hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }), labels(repo, '.project-map/captured.md'));

// D22 option (A): the gate at the write
const deny = (input, dir = repo) => {
  const r = spawnSync('node', [HOOK, 'gate'], { input: JSON.stringify({ cwd: dir, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: dir } });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecisionReason : '';
};
const g = `${sid}-gate`;
const w = (f, extra = {}) => deny({ session_id: g, tool_name: 'Edit', tool_input: { file_path: path.join(repo, f) }, ...extra });
const rd = (f, extra = {}) => hook('read', { session_id: g, tool_input: { file_path: path.join(repo, f) }, ...extra });
assert.equal(w('src/a.ts'), ''); // no epoch opened by an index: nothing is gated
hook('session-start', { session_id: g, source: 'startup' });
assert.equal(w('src/a.ts'), GATE('src')); // the first code write in src/
assert.equal(w('src/a.ts'), GATE('src')); // no Read since the deny
assert.equal(w('src/a.ts'), ''); // at most 2 denies per directory
assert.equal(w('src/b.ts'), ''); // src/ is open for the rest of the epoch
assert.equal(w('README.md'), '');
assert.equal(w('.project-map/captured.md'), '');
assert.equal(deny({ session_id: g, tool_name: 'Write', tool_input: { file_path: path.join(tmp, 'outside.ts') } }), '');
assert.equal(w('lib/c.ts'), GATE('lib'));
rd('docs/style.md');
assert.equal(w('lib/c.ts'), ''); // a document Read since the deny
assert.equal(w('tools/d.ts'), GATE('tools'));
rd('src/a.ts');
assert.equal(w('tools/d.ts'), GATE('tools')); // a code file is not a document
assert.equal(w('pkg/e.ts'), GATE('pkg'));
rd('docs/style.md', { agent_id: 'sub' });
assert.equal(w('pkg/e.ts'), GATE('pkg')); // a subagent's Read does not count
assert.equal(w('sub/f.ts', { agent_id: 'sub' }), ''); // subagent writes pass
assert.equal(w('x.ts'), GATE('.'));
hook('session-start', { session_id: g, source: 'compact' });
assert.equal(w('src/a.ts'), GATE('src')); // a new epoch gates again

// outside git: no index, no forced decision, no gate, every entry unreviewed
const loose = path.join(tmp, 'loose');
fs.mkdirSync(path.join(loose, '.project-map'), { recursive: true });
fs.writeFileSync(path.join(loose, '.project-map', 'captured.md'), entry('a', 'b', '2026-10-25'));
assert.equal(index(loose), null);
assert.equal(hook('session-start', { session_id: `${sid}-loose` }, loose), `${INSTRUCTION}\n\n${NAME}`);
assert.equal(hook('prompt', { session_id: `${sid}-loose` }, loose), '');
assert.equal(deny({ session_id: `${sid}-loose`, tool_name: 'Edit', tool_input: { file_path: path.join(loose, 'a.ts') } }, loose), '');
assert.ok(labels(loose, '.project-map/captured.md').includes(`1. a: ${UNREVIEWED}; unverified quote, captured 2026-10-25`));

// a repo with no documents: an empty index, the instruction alone
const bare = path.join(tmp, 'bare');
fs.mkdirSync(bare);
spawnSync('git', ['init', '-q'], { cwd: bare });
assert.equal(index(bare), '');
assert.equal(hook('session-start', { session_id: `${sid}-bare` }, bare), `${INSTRUCTION}\n\n${NAME}`);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('selftest ok');
