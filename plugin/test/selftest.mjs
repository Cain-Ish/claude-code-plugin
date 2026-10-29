// The skeleton's self-test (06, step 2a): the frozen texts, the surfaces, and each hook run as a process in a
// temporary git repo.   node plugin/test/selftest.mjs
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { INSTRUCTION, HEADER, FORCE, NAME, UNREVIEWED, CAP, index, labels, startText } from '../scripts/map.mjs';

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

// the surfaces: 3 hook events, 1 command, no agents, skills or MCP servers; PM6: each names the outcome it serves (06)
const OUTCOME = { SessionStart: 'Capture; Consistency', UserPromptSubmit: 'Consistency', PostToolUse: 'Freshness; trust', 'onboard.md': 'Onboarding' };
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

// the measured product (06, 2g): what installs hashes to what the eval ran. A product change fails here until this
// value moves with a new epoch and its runs.
const files = [];
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) if (e.name !== 'test') (e.isDirectory() ? walk : (p) => files.push(p))(path.join(d, e.name)); };
walk(PLUGIN);
const product = crypto.createHash('sha256');
for (const f of files.map((p) => path.relative(PLUGIN, p).split(path.sep).join('/')).sort()) product.update(f).update(fs.readFileSync(path.join(PLUGIN, f), 'utf8').replace(/\r\n/g, '\n'));
// alpha.4: 2j's Bash labels; checked by this self-test, the smoke and CI only, A1 not re-run on it, by the user's choice
// (06, 2j)
assert.equal(product.digest('hex').slice(0, 12), 'f18d83e328b4', 'the product changed: record its hash with a new epoch (06)');

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
assert.equal(labels(repo, '.project-map/private.md'), `[project map] Labels on the entries of .project-map/private.md, in file order:\n1. y: ${UNREVIEWED}; unverified quote, captured 2026-10-26\n`);
fs.rmSync(path.join(repo, '.gitignore'));
fs.rmSync(path.join(repo, '.project-map', 'private.md'));
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
put('.project-map/bare.md', '### pages\n> Each page has one h1.\n');
git('add', '-A');
git('commit', '-q', '-m', 'cited');
// PM5: a committed entry with no source line is still labelled
assert.equal(labels(repo, '.project-map/bare.md'), '[project map] Labels on the entries of .project-map/bare.md, in file order:\n1. pages: unverified quote\n');
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
// 2j: a map file read through Bash gets what a Read of it gets, byte for byte
const bash = (command) => hook('bash', { tool_input: { command } });
assert.equal(bash('tail -5 .project-map/captured.md'), hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'captured.md') } }));
// the field's 20 commands that named the folder (probes/V2-D17-field, C5 as corrected), with placeholder paths and
// text: the 9 that showed map entries get the file's labels, the 11 others nothing
const append = (tail = '') => `cat >> .project-map/captured.md <<'EOF'\n\n${entry('more', 'Load more items on scroll.', '2026-10-26')}EOF${tail}`;
const py = (tail) => `python -I - <<'EOF'\np='.project-map/captured.md'\ns=open(p,encoding='utf-8').read()\nopen(p,'w',encoding='utf-8').write(s.replace('CDN','cdn'))\nEOF\n${tail}`;
const FIELD = [
  [true, 'git status --short && grep -n "^### " .project-map/captured.md'],
  [true, append('\ntail -3 .project-map/captured.md')],
  [true, py('tail -6 .project-map/captured.md')],
  [true, 'sed -n 385,470p docs/style.md; echo ======; cat .project-map/captured.md'],
  [true, append('\ntail -7 .project-map/captured.md')],
  [true, 'tail -30 .project-map/captured.md'],
  [true, 'tail -20 .project-map/captured.md'],
  [true, 'cd /work/repo && tail -15 .project-map/captured.md'],
  [true, `cd /work/repo && PYTHONIOENCODING=utf-8 ${py('tail -6 .project-map/captured.md; git switch -q master; git status --short')}`],
  [false, `for d in docs . research; do n=$(git ls-files "$d" | grep -E '\\.(md|txt)$' | wc -l); b=$(git ls-files "$d" | xargs cat | wc -c); echo "$d $n $b"; done; git status --short; ls .project-map 2>&1`],
  [false, 'git status --short && git diff --stat && ls .project-map 2>&1 | head -2'],
  [false, 'cd /work/repo && ls -la .project-map 2>&1; git status --short'],
  [false, "grep -n '^#' docs/style.md | head -60; echo; wc -c .project-map/captured.md; ls .project-map"],
  [false, append()],
  [false, append()],
  [false, append()],
  [false, `cd /work/repo && ${append()}`],
  [false, `cd /work/repo && ${py("git add -A -- . ':!.project-map' && git status --short | head -40")}`],
  [false, `cd /work/repo && git status --short && cat > "/tmp/msg.txt" <<'EOF'\nA commit message, more of it.\nEOF\ngit add -A -- . ':!.project-map' && git commit -q -F "/tmp/msg.txt" 2>&1 | tail -1`],
  [false, "cd /work/repo && git add -A -- . ':!.project-map' && git status --short | head -30 && git commit -q -F \"/tmp/msg.txt\""],
];
for (const [reads, command] of FIELD) assert.equal(bash(command), reads ? labels(repo, '.project-map/captured.md') : '', command);
// two map files in one command, one of them named twice: each file's labels once, in order of mention
assert.equal(bash('cat .project-map/new.md .project-map/captured.md; tail -2 .project-map/new.md'), labels(repo, '.project-map/new.md') + labels(repo, '.project-map/captured.md'));
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
assert.equal(bash('tail -5 .project-map/folder.md'), hook('read', { tool_input: { file_path: path.join(repo, '.project-map', 'folder.md') } }));
fs.rmSync(path.join(repo, '.project-map', 'folder.md'), { recursive: true });
// I9: a missing TEMP costs only the forced decision
{
  const gone = path.join(tmp, 'no-such-temp');
  const r = spawnSync('node', [HOOK, 'session-start'], { input: JSON.stringify({ cwd: repo, session_id: `${sid}-t` }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: repo, TEMP: gone, TMP: gone, TMPDIR: gone } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.additionalContext, `${INSTRUCTION}\n\n${index(repo)}\n${NAME}`);
}
// I13: a byte-order mark does not hide the first entry
put('.project-map/bom.md', `﻿${entry('first', 'A rule.', '2026-10-27')}`);
assert.ok(labels(repo, '.project-map/bom.md').startsWith(`[project map] Labels on the entries of .project-map/bom.md, in file order:\n1. first: ${UNREVIEWED}`));
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
  assert.equal(labels(repo, '.project-map/wide.md'), `[project map] Labels on the entries of .project-map/wide.md, in file order:\n1. first: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n2. second: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n`);
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
assert.equal(hook('read', { tool_input: { file_path: path.join(bare, '.project-map', 'captured.md') } }, bare), `[project map] Labels on the entries of .project-map/captured.md, in file order:\n1. a: ${UNREVIEWED}; unverified quote, captured 2026-10-27\n`);
// 2i, L2: a control character in a tracked path is printed as ?, so the path stays on its line. Added to git's index
// only: no file system takes a newline or a tab in a name everywhere
{
  const g = (args, input) => { const r = spawnSync('git', ['-c', 'core.protectNTFS=false', ...args], { cwd: bare, input, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
  g(['update-index', '--add', '--cacheinfo', `100644,${g(['hash-object', '-w', '--stdin'], 'x')},docs/a\nb\tc.md`]);
  assert.equal(index(bare), `${HEADER}\ndocs/: a?b?c.md\n.project-map/: captured.md\n`);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log('selftest ok');
