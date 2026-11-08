// The skeleton's self-test (06, step 2a): the frozen texts, the surfaces, and each hook run as a process in a
// temporary git repo.   node plugin/test/selftest.mjs
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { INSTRUCTION, HEADER, FORCE, NAME, UNREVIEWED, UNVERIFIED_NOTE, CAP, V1_LEFT, index, labels, startText } from '../scripts/map.mjs';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const HOOK = path.join(PLUGIN, 'scripts', 'hook.mjs');

// the texts, as the ledger fixed them
assert.equal(crypto.createHash('sha256').update(INSTRUCTION).digest('hex').slice(0, 12), '8aa72396af72');
assert.equal(Buffer.byteLength(INSTRUCTION), 904);
assert.equal(Buffer.byteLength(FORCE), 227);
assert.equal(HEADER, "IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project. This project's documents, by directory:");
assert.equal(UNREVIEWED, 'unreviewed, not yet committed');
// V2-D23's line, as the ledger froze it
assert.equal(NAME, "When you finish, name each of this project's recorded decisions you followed and its source, as the map entry or document gives it. Do not name a decision you did not follow, or a source the record does not give.");

assert.equal(Buffer.byteLength(NAME), 212);

// PM8: product lines within 06's budget (the hooks, the library, the command, the manifest)
const lines = (d) => fs.readdirSync(path.join(PLUGIN, d)).reduce((n, f) => n + fs.readFileSync(path.join(PLUGIN, d, f), 'utf8').split('\n').length, 0);
assert.ok(['scripts', 'hooks', 'commands', '.claude-plugin'].reduce((n, d) => n + lines(d), 0) <= 600, 'product lines');

// the surfaces: 4 hook events, 1 command, no agents, skills or MCP servers; PM6: each names the outcome it serves (06)
const OUTCOME = { SessionStart: 'Capture; Consistency', UserPromptSubmit: 'Consistency', PostToolUse: 'Freshness; trust', PostToolUseFailure: 'Freshness; trust', 'onboard.md': 'Onboarding' };
const { hooks } = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
assert.deepEqual([...Object.keys(hooks), ...fs.readdirSync(path.join(PLUGIN, 'commands'))], Object.keys(OUTCOME));
assert.equal(hooks.SessionStart[0].matcher, 'startup|clear|resume|compact');
assert.ok(hooks.SessionStart[0].hooks[0].command.includes('The project map needs Node 20 or later; install it, or disable the plugin.'));
assert.equal(hooks.PostToolUse[0].matcher, 'Read');
// 2j: map files read through Bash; the if field spawns the handler only for a command that names the map folder
assert.deepEqual(hooks.PostToolUse[1], { matcher: 'Bash', hooks: [{ type: 'command', if: 'Bash(*.project-map*)', command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs', 'bash'] }] });
assert.deepEqual(fs.readdirSync(path.join(PLUGIN, 'commands')), ['onboard.md']);
for (const d of ['agents', 'skills', '.mcp.json']) assert.ok(!fs.existsSync(path.join(PLUGIN, d)), d);

// D18: no model and no network, and hooks spawn only git. A tripwire over the product scripts' source, not a proof:
// imports in either quote style (side-effect ones too) from these modules only; from child_process only spawnSync,
// always on git; and no code loaded or built at run time
for (const f of ['hook.mjs', 'map.mjs']) {
  const src = fs.readFileSync(path.join(PLUGIN, 'scripts', f), 'utf8');
  const imports = [...src.matchAll(/^\s*import\b[^'"]*['"]([^'"]+)['"]/gm)].map((m) => m[1]);
  assert.equal(imports.length, (src.match(/^\s*import\b/gm) ?? []).length, `${f}: every import has a module path`);
  for (const m of imports) assert.ok(['node:fs', 'node:os', 'node:path', 'node:child_process', './map.mjs'].includes(m), `${f} imports ${m}`);
  for (const [, names] of src.matchAll(/import\s*\{([^}]*)\}\s*from\s*['"]node:child_process['"]/g)) assert.deepEqual(names.split(',').map((n) => n.trim()), ['spawnSync'], `${f}: only spawnSync`);
  // a bare call, so a RegExp's .exec() is not one
  assert.ok(!/(?<![.\w$])(exec|execSync|execFile|execFileSync|fork|spawn)\s*\(/.test(src), `${f} starts processes only with spawnSync`);
  assert.equal((src.match(/\bspawnSync\(/g) ?? []).length, (src.match(/\bspawnSync\('git'/g) ?? []).length, `${f} spawns only git`);
  assert.ok(!/\b(fetch|eval|require|import|Function)\s*\(|process\.binding|globalThis\[/.test(src), `${f} loads or builds no code at run time`);
}

// the measured product (06, 2g): what installs hashes to what the release checks ran; A1 last ran on 3c46826f115b
// (06, 2h). A product change fails here until this value moves with a new epoch and its checks.
const files = [];
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) if (e.name !== 'test') (e.isDirectory() ? walk : (p) => files.push(p))(path.join(d, e.name)); };
walk(PLUGIN);
const product = crypto.createHash('sha256');
for (const f of files.map((p) => path.relative(PLUGIN, p).split(path.sep).join('/')).sort()) product.update(f).update(fs.readFileSync(path.join(PLUGIN, f), 'utf8').replace(/\r\n/g, '\n'));
// alpha.8: 2n, labels for what a Bash command printed (06); checked by this self-test, the smoke and CI
assert.equal(product.digest('hex').slice(0, 12), '20f89a320a6c', 'the product changed: record its hash with a new epoch (06)');

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
// the untracked map files come from the folder (D16's re-lock of 2026-10-26), so one that .gitignore excludes is listed
put('.gitignore', '.project-map/private.md\n');
put('.project-map/private.md', entry('y', 'z', '2026-10-26'));
assert.equal(index(repo), `${HEADER}\n.project-map/: captured.md, new.md, private.md\n./: README.md\ndocs/: Guide.RST, style.md\n`);
// and its entries are labelled like any uncommitted one (the release review, 2026-10-27)
assert.equal(labels(repo, '.project-map/private.md'), `[project map] Labels on the entries of .project-map/private.md, in file order:\n${UNVERIFIED_NOTE}\n1. y: ${UNREVIEWED}; unverified quote, captured 2026-10-26\n`);
fs.rmSync(path.join(repo, '.gitignore'));
fs.rmSync(path.join(repo, '.project-map', 'private.md'));
assert.equal(labels(repo, '.project-map/captured.md'), `[project map] Labels on the entries of .project-map/captured.md, in file order:\n${UNVERIFIED_NOTE}\n`
  + '1. components: unverified quote, captured 2026-10-20\n'
  + `2. avatars: ${UNREVIEWED}; unverified quote, captured 2026-10-24\n`);
assert.equal(labels(repo, '.project-map/new.md'), `[project map] Labels on the entries of .project-map/new.md, in file order:\n${UNVERIFIED_NOTE}\n`
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
assert.equal(labels(repo, '.project-map/cited.md'), `[project map] Labels on the entries of .project-map/cited.md, in file order:\n${UNVERIFIED_NOTE}\n`
  + `1. verbatim: ${UNREVIEWED}\n`
  + `2. condensed: ${UNREVIEWED}; not found word for word in docs/style.md; check it, captured 2026-10-22\n`
  + `3. gone: ${UNREVIEWED}; not found word for word in docs/avatars.md; check it, captured 2026-10-22\n`
  + `4. outside: ${UNREVIEWED}; unverified quote, captured 2026-10-22\n`);
put('.project-map/bare.md', '### pages\n> Each page has one h1.\n');
git('add', '-A');
git('commit', '-q', '-m', 'cited');
// PM5: a committed entry with no source line is still labelled
assert.equal(labels(repo, '.project-map/bare.md'), `[project map] Labels on the entries of .project-map/bare.md, in file order:\n${UNVERIFIED_NOTE}\n1. pages: unverified quote\n`);
assert.equal(labels(repo, '.project-map/cited.md'), `[project map] Labels on the entries of .project-map/cited.md, in file order:\n${UNVERIFIED_NOTE}\n`
  + '2. condensed: not found word for word in docs/style.md; check it, captured 2026-10-22\n'
  + '3. gone: not found word for word in docs/avatars.md; check it, captured 2026-10-22\n'
  + '4. outside: unverified quote, captured 2026-10-22\n');
put('docs/style.md', '# Style\n\nColours come from the theme tokens. No hex values anywhere.\n');
assert.ok(labels(repo, '.project-map/cited.md').includes('1. verbatim: not found word for word in docs/style.md; check it, captured 2026-10-22'));

// each hook as a process, as Claude Code runs it
const hook = (which, input, dir = repo) => {
  const r = spawnSync('node', [HOOK, which], { input: JSON.stringify({ cwd: dir, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: dir, BRAIN_DIR: path.join(tmp, 'no-v1') } });
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
// 2n: a Bash command gets the labels of the map entries its output shows, whatever its form. Each case runs its
// command in the repo for its output, or writes the output out where the tool or its dialect may be missing on a
// runner (Python, rg, grep's \|, a backslash path), or where running it would change the repo the later cases use
const run = (command) => { const r = spawnSync('bash', ['-c', command], { cwd: repo, encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } }); return { stdout: r.stdout, stderr: r.stderr, interrupted: false, isImage: false }; };
const bash = (command, out) => hook('bash', { tool_input: { command }, tool_response: out === undefined ? run(command) : { stdout: out, stderr: '', interrupted: false, isImage: false } });
// the expected text, written by hand: the labels a Read gives, cut to the entries (by number) the output shows
const only = (file, nums) => {
  const [head, ...rest] = labels(repo, file).trimEnd().split('\n');
  const ls = rest.filter((l) => nums.includes(parseInt(l, 10)));
  return ls.length ? `${head.replace(', in file order:', ' that this output shows, in file order:')}\n${ls.some((l) => l.includes('unverified quote')) ? `${UNVERIFIED_NOTE}\n` : ''}${ls.join('\n')}\n` : '';
};
const C = '.project-map/captured.md';
assert.equal(bash('tail -5 .project-map/captured.md'), only(C, [2]));
assert.equal(bash('cat .project-map/captured.md'), only(C, [1, 2]));
// a tail that shows only an entry's source and when lines shows no entry
assert.equal(bash('tail -3 .project-map/captured.md'), '');
// the repo's path as a shell command gives it
const R = repo.split(path.sep).join('/');
// the field's 20 commands that named the folder (probes/V2-D17-field, C5 as corrected), with the repo's path and
// text: each with the entries its output shows here. Appends, the Python edits and the commits are not run
const append = (tail = '') => `cat >> .project-map/captured.md <<'EOF'\n\n${entry('more', 'Load more items on scroll.', '2026-10-26')}EOF${tail}`;
const py = (tail) => `python -I - <<'EOF'\np='.project-map/captured.md'\ns=open(p,encoding='utf-8').read()\nopen(p,'w',encoding='utf-8').write(s.replace('CDN','cdn'))\nEOF\n${tail}`;
const FIELD = [
  [[1, 2], 'git status --short && grep -n "^### " .project-map/captured.md'],
  [[], append('\ntail -3 .project-map/captured.md'), run('tail -3 .project-map/captured.md').stdout],
  [[2], py('tail -6 .project-map/captured.md'), run('tail -6 .project-map/captured.md').stdout],
  [[1, 2], 'sed -n 385,470p docs/style.md; echo ======; cat .project-map/captured.md'],
  [[2], append('\ntail -7 .project-map/captured.md'), run('tail -7 .project-map/captured.md').stdout],
  [[1, 2], 'tail -30 .project-map/captured.md'],
  [[1, 2], 'tail -20 .project-map/captured.md'],
  [[1, 2], `cd ${R} && tail -15 .project-map/captured.md`],
  [[2], `cd ${R} && PYTHONIOENCODING=utf-8 ${py('tail -6 .project-map/captured.md; git switch -q master; git status --short')}`, run('tail -6 .project-map/captured.md').stdout],
  [[], `for d in docs . research; do n=$(git ls-files "$d" | grep -E '\\.(md|txt)$' | wc -l); b=$(git ls-files "$d" | xargs cat | wc -c); echo "$d $n $b"; done; git status --short; ls .project-map 2>&1`],
  [[], 'git status --short && git diff --stat && ls .project-map 2>&1 | head -2'],
  [[], `cd ${R} && ls -la .project-map 2>&1; git status --short`],
  [[], "grep -n '^#' docs/style.md | head -60; echo; wc -c .project-map/captured.md; ls .project-map"],
  [[], append(), ''],
  [[], append(), ''],
  [[], append(), ''],
  [[], `cd ${R} && ${append()}`, ''],
  [[], `cd ${R} && ${py("git add -A -- . ':!.project-map' && git status --short | head -40")}`, 'M  docs/style.md\n'],
  [[], `cd ${R} && git status --short && cat > "/tmp/msg.txt" <<'EOF'\nA commit message, more of it.\nEOF\ngit add -A -- . ':!.project-map' && git commit -q -F "/tmp/msg.txt" 2>&1 | tail -1`, ' M docs/style.md\n'],
  [[], `cd ${R} && git add -A -- . ':!.project-map' && git status --short | head -30 && git commit -q -F "/tmp/msg.txt"`, ''],
];
for (const [nums, command, out] of FIELD) assert.equal(bash(command, out), only(C, nums), command);
// two map files in one command, one of them named twice: each file's shown entries once, in git's order
assert.equal(bash('cat .project-map/new.md .project-map/captured.md; tail -2 .project-map/new.md'), only(C, [1, 2]) + only('.project-map/new.md', [1]));
// D14's accepted risks of 2026-11-07 (the command parse's gaps), each labelled now, with an uncommitted entry
fs.appendFileSync(path.join(repo, C), `\n${entry('migrations', 'Never drop tables in a migration.', '2026-11-08')}`);
const RISKS = [
  [[2, 3], 'grep -n -E "Avatars|tables" .project-map/captured.md'],
  [[2, 3], 'grep -n -i "avatars\\|drop tables" .project-map/captured.md', '8:> Avatars load locally, never from the CDN.\n14:> Never drop tables in a migration.\n'],
  [[1, 2, 3], 'cd .project-map && cat captured.md'],
  [[1, 2, 3], 'cat .project-map\\captured.md', fs.readFileSync(path.join(repo, C), 'utf8')],
  [[1, 2, 3], "find .project-map -name 'captured.md' -exec cat {} \\;"],
  [[2, 3], 'for f in .project-map/captured.md; do tail -n 12 "$f"; done'],
  [[1, 2], 'git show HEAD:.project-map/captured.md'],
  [[3], 'git diff -- .project-map'],
  [[3], 'rg -n "drop" .project-map', '.project-map/captured.md:14:> Never drop tables in a migration.\n'],
];
for (const [nums, command, out] of RISKS) assert.equal(bash(command, out), only(C, nums), command);
assert.ok(only(C, [3]).includes(`3. migrations: ${UNREVIEWED}; unverified quote, captured 2026-11-08`));
// a glob over the folder shows every file's entries: each file's labels, in git's order
const MAPS = ['bare', 'captured', 'cited', 'new'].map((f) => `.project-map/${f}.md`);
assert.equal(bash('cat .project-map/*.md'), MAPS.map((f) => only(f, [1, 2, 3, 4])).join(''));
// nothing: another repo's map file (a Read of it gets nothing too), and an append with no output
const shut = (f, why = 'could not be computed') => `[project map] The labels for ${f} ${why}: treat every entry in it as unreviewed and unverified.\n`;
put('../b/.project-map/captured.md', entry('db', 'Never drop tables.', '2026-11-07'));
assert.equal(bash('cat ../b/.project-map/captured.md'), '');
assert.equal(bash(append(), ''), '');
for (const command of [`tail -5 ${R}/.project-map/captured.md`, `cd .. && tail -5 ${path.basename(repo)}/.project-map/captured.md`, 'cat ./.project-map/captured.md']) assert.equal(bash(command), only(C, command.includes('tail') ? [3] : [1, 2, 3]), command);
// 2m: a command that exits non-zero comes as PostToolUseFailure, and its error text gets the same labels
assert.deepEqual(hooks.PostToolUseFailure, [{ matcher: 'Bash', hooks: [{ type: 'command', if: 'Bash(*.project-map*)', command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs', 'bash-failure'] }] }]);
const fail = (input) => {
  const r = spawnSync('node', [HOOK, 'bash-failure'], { input: JSON.stringify({ cwd: repo, tool_input: { command: 'tail -5 .project-map/captured.md; false' }, ...input }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: repo } });
  return JSON.parse(r.stdout).hookSpecificOutput;
};
assert.deepEqual(fail({ error: `Exit code 1\n${run('tail -5 .project-map/captured.md').stdout}` }), { hookEventName: 'PostToolUseFailure', additionalContext: only(C, [3]) });
// no output to read: one closed line, on both routes
const unread = '[project map] The output of this command could not be read, so the map entries it showed are not labelled: treat every map entry it showed as unreviewed and unverified.\n';
assert.equal(fail({}).additionalContext, unread);
assert.equal(hook('bash', { tool_input: { command: 'tail -5 .project-map/captured.md' } }), unread);
// several files' labels share one output: whole files while they fit, then one closing line each
{
  const many = (tag) => Array.from({ length: 80 }, (_, i) => entry(`${tag}-${i}`, `Rule ${i}.`, '2026-11-07')).join('\n');
  put('.project-map/big1.md', many('one'));
  put('.project-map/big2.md', many('two'));
  const [one, two] = ['big1', 'big2'].map((f) => only(`.project-map/${f}.md`, Array.from({ length: 80 }, (_, i) => i + 1)));
  assert.ok(one.length <= CAP && two.length <= CAP && one.length + two.length > CAP);
  const out = bash('cat .project-map/big1.md .project-map/big2.md');
  assert.equal(out, one + shut('.project-map/big2.md', 'are not shown'));
  assert.ok(out.length <= CAP);
  fs.rmSync(path.join(repo, '.project-map', 'big1.md'));
  fs.rmSync(path.join(repo, '.project-map', 'big2.md'));
  // many files: when the closing lines alone would pass the cap, one line covers them all
  for (const n of [85, 200]) {
    const names = Array.from({ length: n }, (_, i) => `.project-map/m${i}.md`);
    names.forEach((f, i) => put(f, entry(`e${i}`, 'q', '2026-11-07')));
    const out = bash(`cat ${names.join(' ')}`);
    assert.ok(out.length <= CAP, `${n} files`);
    assert.equal(out, `[project map] The labels for the ${n} map files this command read are not shown: treat every entry in them as unreviewed and unverified.\n`);
    names.forEach((f) => fs.rmSync(path.join(repo, f)));
  }
}
// a UTF-16 map file printed raw comes back with NULs between its letters, and is labelled
{
  const text = `${entry('first', 'A rule.', '2026-11-08')}\n${entry('second', 'Another rule.', '2026-11-08')}`;
  fs.writeFileSync(path.join(repo, '.project-map', 'wide.md'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]));
  assert.equal(bash('cat .project-map/wide.md', Buffer.from(text, 'utf16le').toString('latin1')), only('.project-map/wide.md', [1, 2]));
  fs.rmSync(path.join(repo, '.project-map', 'wide.md'));
}
// the note: present when an "unverified quote" label is listed, absent when none is
assert.ok(bash('cat .project-map/captured.md').includes(`in file order:\n${UNVERIFIED_NOTE}\n1. components`));
const noNote = bash('grep -n "never hex" .project-map/cited.md');
assert.ok(noNote.startsWith('[project map] Labels on the entries of .project-map/cited.md that this output shows, in file order:\n2. condensed: not found word for word'), noNote);
// 2i, L1: the force waits for a prompt a person typed; a turn nobody typed (the wrappers as transcripts record them)
// gets nothing and leaves the epoch's marker
['Another Claude session sent a message:\n<cross-session-message from="x">hi</cross-session-message>', '<task-notification>\n<task-id>b1</task-id>',
  '<cross-session-message from="x">hi</cross-session-message>', '  <agent-message from="x">done</agent-message>'].forEach((prompt, i) => {
  hook('session-start', { session_id: `${sid}-machine-${i}` });
  assert.equal(hook('prompt', { session_id: `${sid}-machine-${i}`, prompt }), '', prompt);
  assert.equal(hook('prompt', { session_id: `${sid}-machine-${i}`, prompt: 'create a UserAvatar component' }), FORCE);
});
hook('session-start', { session_id: `${sid}-typed` });
assert.equal(hook('prompt', { session_id: `${sid}-typed`, prompt: 'why does the <task-notification> parser fail?' }), FORCE);

// the release review's fixes (06, 2g attempt 3; D18 reopened 2026-10-27)
// I1: a session started in a subdirectory takes the git toplevel as its root
const docs = path.join(repo, 'docs');
assert.equal(hook('session-start', { session_id: `${sid}-sub` }, docs), `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
hook('prompt', { session_id: `${sid}-sub` }, docs);
assert.equal(hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }, docs), labels(repo, '.project-map/captured.md'));
// I4: a cited source that cannot be read gets its own label; anything else that fails labels the file as a whole
{
  const read = fs.readFileSync;
  fs.readFileSync = (p, ...a) => { if (String(p).endsWith('style.md')) throw Object.assign(new Error('denied'), { code: 'EPERM' }); return read(p, ...a); };
  try { assert.ok(labels(repo, '.project-map/cited.md').includes('1. verbatim: cannot read docs/style.md; check it, captured 2026-10-22')); } finally { fs.readFileSync = read; }
}
fs.mkdirSync(path.join(repo, '.project-map', 'folder.md'));
assert.match(hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'folder.md') } }), /could not be computed: treat every entry in it as unreviewed/);
// 2n: a folder named like a map file holds no entry, so a Bash command shows none of it
assert.equal(bash('tail -5 .project-map/folder.md'), '');
fs.rmSync(path.join(repo, '.project-map', 'folder.md'), { recursive: true });
// a map file that cannot be read fails closed, whatever the output shows (a link to a folder; a junction on Windows)
fs.symlinkSync(path.join(repo, 'docs'), path.join(repo, '.project-map', 'link.md'), 'junction');
assert.equal(bash('cat .project-map/captured.md'), only(C, [1, 2, 3]) + shut('.project-map/link.md'));
fs.rmSync(path.join(repo, '.project-map', 'link.md'));
// I9: a missing TEMP costs only the forced decision
{
  const gone = path.join(tmp, 'no-such-temp');
  const r = spawnSync('node', [HOOK, 'session-start'], { input: JSON.stringify({ cwd: repo, session_id: `${sid}-t` }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: repo, TEMP: gone, TMP: gone, TMPDIR: gone } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.additionalContext, `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
}
// I13: a byte-order mark does not hide the first entry
put('.project-map/bom.md', `﻿${entry('first', 'A rule.', '2026-10-27')}`);
assert.ok(labels(repo, '.project-map/bom.md').startsWith(`[project map] Labels on the entries of .project-map/bom.md, in file order:\n${UNVERIFIED_NOTE}\n1. first: ${UNREVIEWED}`));
fs.rmSync(path.join(repo, '.project-map', 'bom.md'));
// I11 and 06's 2h: a tracked map file renamed only in letter case is folded as the repo's core.ignorecase says (K2),
// ASCII letters only, as git compares (K3), and in a linked worktree too, whose .git is a file. The setting is made
// both ways on every system, so this checks the mechanism, not the file system. Each listing must also be git's own,
// from the two calls the index made before D16's re-lock.
{
  const cs = path.join(tmp, 'case');
  const g = (cwd, ...a) => assert.equal(spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd }).status, 0);
  const ls = (cwd, ...a) => spawnSync('git', ['ls-files', '-z', ...a], { cwd, encoding: 'utf8' }).stdout.split('\0').filter(Boolean);
  const gits = (d) => `${HEADER}\n.project-map/: ${[...ls(d, '--cached'), ...ls(d, '--others', '--exclude-standard', '--', '.project-map')].map((p) => p.slice(13)).join(', ')}\n`;
  fs.mkdirSync(path.join(cs, '.project-map'), { recursive: true });
  for (const f of ['captured.md', 'Ärger.md']) fs.writeFileSync(path.join(cs, '.project-map', f), entry('a', 'b', '2026-10-27'));
  g(cs, 'init', '-q');
  g(cs, 'add', '-A');
  g(cs, 'commit', '-q', '-m', 'init');
  g(cs, 'worktree', 'add', '-q', path.join(tmp, 'case-wt'));
  for (const d of [cs, path.join(tmp, 'case-wt')]) {
    fs.renameSync(path.join(d, '.project-map', 'captured.md'), path.join(d, '.project-map', 'Captured.md'));
    fs.renameSync(path.join(d, '.project-map', 'Ärger.md'), path.join(d, '.project-map', 'ärger.md'));
    g(d, 'config', 'core.ignorecase', 'true');
    assert.equal(index(d), `${HEADER}\n.project-map/: captured.md, Ärger.md, ärger.md\n`);
    assert.equal(index(d), gits(d));
    g(d, 'config', 'core.ignorecase', 'false');
    assert.equal(index(d), `${HEADER}\n.project-map/: captured.md, Ärger.md, Captured.md, ärger.md\n`);
    assert.equal(index(d), gits(d));
  }
}
// I2: an index past the 10,000-character cap of one hook output is cut at a directory, and says so
{
  const big = `${HEADER}\n${Array.from({ length: 400 }, (_, i) => `packages/package-${i}/: README.md`).join('\n')}\n`;
  const { text, listed, total } = startText(big);
  assert.ok(text.length <= CAP && total === 400 && listed > 0 && listed < 400 && text.endsWith(`\n\n${NAME}`));
  assert.ok(text.includes(`packages/package-${listed - 1}/: README.md\n(${400 - listed} more directories not listed`));
  assert.equal(startText(index(repo)).text, `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
  // the second review's J2: when cut, the map folder's line comes first; J1: one pass, so 10,000 directories are quick
  const withMap = big.replace(/\n$/, '\n.project-map/: captured.md\n');
  assert.ok(startText(withMap).text.includes(`${HEADER}\n.project-map/: captured.md\npackages/package-0/: README.md\n`));
  const huge = `${HEADER}\n${Array.from({ length: 10_000 }, (_, i) => `packages/package-${i}/: README.md`).join('\n')}\n`;
  const t = performance.now();
  assert.ok(startText(huge).text.length <= CAP && performance.now() - t < 100, 'the cut takes one pass');
}
// J3: past the cap, the labels are cut at a line and every entry after the last one shown fails closed
{
  put('.project-map/many.md', Array.from({ length: 301 }, (_, i) => entry(`decision ${i + 1}`, `Rule ${i + 1} applies here.`, '2026-10-27')).join('\n'));
  const l = labels(repo, '.project-map/many.md');
  const shown = (l.match(/^\d+\. /gm) ?? []).length;
  assert.ok(l.length <= CAP && shown > 0 && shown < 301);
  assert.ok(l.endsWith(`(${301 - shown} more labels not shown: treat every entry after entry ${shown} in this file as unreviewed and unverified.)\n`));
  fs.rmSync(path.join(repo, '.project-map', 'many.md'));
  // 06's 2h (K1): one label left is "label"; so is one label line that does not fit at all
  put('.project-map/long.md', Array.from({ length: 5 }, (_, i) => entry(`${i + 1}${'x'.repeat(2300)}`, 'A rule.', '2026-10-27')).join('\n'));
  assert.ok(labels(repo, '.project-map/long.md').endsWith('\n(1 more label not shown: treat every entry after entry 4 in this file as unreviewed and unverified.)\n'));
  put('.project-map/long.md', entry('x'.repeat(10_000), 'A rule.', '2026-10-27'));
  assert.equal(labels(repo, '.project-map/long.md'), '[project map] Labels on the entries of .project-map/long.md, in file order:\n(1 label not shown: treat every entry in this file as unreviewed and unverified.)\n');
  fs.rmSync(path.join(repo, '.project-map', 'long.md'));
}
// J4: a UTF-16 map file (Windows PowerShell 5.1's Out-File and >) gets its labels
{
  const text = `${entry('first', 'A rule.', '2026-10-27')}\n${entry('second', 'Another rule.', '2026-10-27')}`;
  fs.writeFileSync(path.join(repo, '.project-map', 'wide.md'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]));
  assert.equal(labels(repo, '.project-map/wide.md'), `[project map] Labels on the entries of .project-map/wide.md, in file order:\n${UNVERIFIED_NOTE}\n1. first: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n2. second: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n`);
  fs.rmSync(path.join(repo, '.project-map', 'wide.md'));
}

// SessionStart's command through bash, as hooks.json gives it: the full output with Node, the one line without it
const noNode = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^path$/i.test(k))),
  PATH: process.env.PATH.split(path.delimiter).filter((d) => !['node', 'node.exe'].some((n) => fs.existsSync(path.join(d, n)))).join(path.delimiter) };
const shell = (env) => {
  const r = spawnSync('bash', ['-c', hooks.SessionStart[0].hooks[0].command], { input: JSON.stringify({ cwd: repo, session_id: `${sid}-sh` }), encoding: 'utf8', env: { ...env, CLAUDE_PLUGIN_ROOT: PLUGIN, CLAUDE_PROJECT_DIR: repo } });
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
};
assert.equal(shell(process.env).hookSpecificOutput.additionalContext, `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
assert.equal(hook('prompt', { session_id: `${sid}-sh` }), FORCE);
assert.deepEqual(shell(noNode), { systemMessage: 'The project map needs Node 20 or later; install it, or disable the plugin.' });

// outside git: no index, no forced decision, every entry unreviewed
const loose = path.join(tmp, 'loose');
fs.mkdirSync(path.join(loose, '.project-map'), { recursive: true });
fs.writeFileSync(path.join(loose, '.project-map', 'captured.md'), entry('a', 'b', '2026-10-25'));
assert.equal(index(loose), null);
assert.equal(hook('session-start', { session_id: `${sid}-loose` }, loose), `${INSTRUCTION}\n\n${NAME}`);
assert.equal(hook('prompt', { session_id: `${sid}-loose` }, loose), '');
assert.ok(labels(loose, '.project-map/captured.md').includes(`1. a: ${UNREVIEWED}; unverified quote, captured 2026-10-25`));

// a repo with no documents: an empty index, the instruction alone
const bare = path.join(tmp, 'bare');
fs.mkdirSync(bare);
spawnSync('git', ['init', '-q'], { cwd: bare });
assert.equal(index(bare), '');
assert.equal(hook('session-start', { session_id: `${sid}-bare` }, bare), `${INSTRUCTION}\n\n${NAME}`);
// a map file in a repo with no commit yet (no HEAD): listed, and every entry unreviewed
fs.mkdirSync(path.join(bare, '.project-map'));
fs.writeFileSync(path.join(bare, '.project-map', 'captured.md'), entry('a', 'b', '2026-10-27'));
assert.equal(index(bare), `${HEADER}\n.project-map/: captured.md\n`);
assert.equal(hook('read', { tool_input: { file_path: path.join(bare, '.project-map', 'captured.md') } }, bare), `[project map] Labels on the entries of .project-map/captured.md, in file order:\n${UNVERIFIED_NOTE}\n1. a: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n`);
// 2i, L2: a control character in a tracked path is printed as ?, so the path stays on its line. Added to git's index
// only: no file system takes a newline or a tab in a name everywhere
{
  const g = (args, input) => { const r = spawnSync('git', ['-c', 'core.protectNTFS=false', ...args], { cwd: bare, input, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
  g(['update-index', '--add', '--cacheinfo', `100644,${g(['hash-object', '-w', '--stdin'], 'x')},docs/a\nb\tc.md`]);
  assert.equal(index(bare), `${HEADER}\ndocs/: a?b?c.md\n.project-map/: captured.md\n`);
}
// 2k: the root's .claude/rules/ is Claude Code's, so it is left out; a look-alike folder and a nested one stay listed
{
  const rules = path.join(tmp, 'rules');
  const put2 = (f, s) => { fs.mkdirSync(path.dirname(path.join(rules, f)), { recursive: true }); fs.writeFileSync(path.join(rules, f), s); };
  const g = (...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: rules, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };
  fs.mkdirSync(rules);
  g('init', '-q');
  put2('.claude/rules/a.md', '---\npaths:\n  - src/**\n---\nx\n');
  put2('.claude/rules/sub/b.md', 'x\n');
  g('add', '-A');
  g('commit', '-q', '-m', 'rules');
  // only rules: an empty index, the instruction and the naming line alone, and no forced decision
  assert.equal(index(rules), '');
  assert.equal(hook('session-start', { session_id: `${sid}-rules` }, rules), `${INSTRUCTION}\n\n${NAME}`);
  assert.equal(hook('prompt', { session_id: `${sid}-rules`, prompt: 'add a feature' }, rules), '');
  // an untracked map file beside the rules is listed
  put2('.project-map/captured.md', entry('a', 'b', '2026-11-03'));
  assert.equal(index(rules), `${HEADER}\n.project-map/: captured.md\n`);
  put2('.claude/rulesets/c.md', 'x\n');
  put2('pkg/.claude/rules/d.md', 'x\n');
  g('add', '.claude/rulesets/c.md', 'pkg/.claude/rules/d.md');
  g('commit', '-q', '-m', 'more');
  assert.equal(index(rules), `${HEADER}\n.claude/rulesets/: c.md\npkg/.claude/rules/: d.md\n.project-map/: captured.md\n`);
  // 2m: Claude Code loads only names ending in .md there, case and all, so other documents stay listed
  put2('.claude/rules/policy.txt', 'x\n');
  put2('.claude/rules/Upper.MD', 'x\n');
  g('add', '.claude/rules/policy.txt', '.claude/rules/Upper.MD');
  assert.equal(index(rules), `${HEADER}\n.claude/rules/: Upper.MD, policy.txt\n.claude/rulesets/: c.md\npkg/.claude/rules/: d.md\n.project-map/: captured.md\n`);
}

// V2-D27: while v1's statusline or timer shim is on disk, session start adds one line for the user and leaves the
// output for Claude unchanged; without them its stdout is what it was before D27
assert.equal(V1_LEFT, 'second-brain v1 left its statusline or timer on this machine. To remove them: https://github.com/Cain-Ish/claude-code-plugin#coming-from-v1');
{
  const { BRAIN_DIR: _, ...noBrain } = process.env;
  const start = (env) => {
    const r = spawnSync('node', [HOOK, 'session-start'], { input: JSON.stringify({ cwd: repo, session_id: `${sid}-v1` }), encoding: 'utf8', env: { ...noBrain, CLAUDE_PROJECT_DIR: repo, ...env } });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout;
  };
  const before = JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: `${INSTRUCTION}

${index(repo)}
${NAME}` } });
  const brain = path.join(tmp, 'v1-brain');
  assert.equal(start({ BRAIN_DIR: brain }), before);
  fs.mkdirSync(path.join(brain, 'bin'), { recursive: true });
  assert.equal(start({ BRAIN_DIR: brain }), before);
  for (const f of ['buddy-statusline.sh', 'sb-extract-drain.sh']) {
    fs.writeFileSync(path.join(brain, 'bin', f), '');
    assert.equal(start({ BRAIN_DIR: brain }), JSON.stringify({ systemMessage: V1_LEFT, ...JSON.parse(before) }));
    fs.rmSync(path.join(brain, 'bin', f));
  }
  // another file in bin/ is not v1's shim
  fs.writeFileSync(path.join(brain, 'bin', 'other.sh'), '');
  assert.equal(start({ BRAIN_DIR: brain }), before);
  // without BRAIN_DIR: .second-brain in the home folder
  const home = path.join(tmp, 'home');
  assert.equal(start({ HOME: home, USERPROFILE: home }), before);
  fs.mkdirSync(path.join(home, '.second-brain', 'bin'), { recursive: true });
  fs.writeFileSync(path.join(home, '.second-brain', 'bin', 'sb-extract-drain.sh'), '');
  assert.equal(JSON.parse(start({ HOME: home, USERPROFILE: home })).systemMessage, V1_LEFT);
  // a BRAIN_DIR that is a file, not a folder: no line, no failure
  fs.writeFileSync(path.join(tmp, 'brain-file'), '');
  assert.equal(start({ BRAIN_DIR: path.join(tmp, 'brain-file') }), before);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log('selftest ok');
