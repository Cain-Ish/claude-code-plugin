// 06, section 3, S5 (V2-D29): setup copies plugin/templates/ into a repo, Anthropic's layout for Claude. Each file is
// created with 'wx' when missing; a file that exists changes only as the two notes below allow; nothing is committed.
// Templates sit under undotted names, so this plugin's own repo never loads them as live rules, agents or a nested
// CLAUDE.md. Since 06, section 4,
// 4b (D29 reopened), an instruction file or .gitattributes that lacks setup's section or line gets it appended, but only
// when git shows that file committed and unchanged. Since 06, section 6 (D29 reopened), a kept file whose text is a
// template an earlier release shipped is replaced with this version's, under the same guard.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { git, inRepo, configDir, utf16, decode } from './map.mjs';

// the third field: the hashes (sum, below) of the texts earlier releases shipped for that file, 2.3.0's then 2.4.0's.
// A release that changes a template adds its old hash here, and its old text to test/earlier/ (the self-test checks)
export const FILES = [
  ['CLAUDE.template.md', 'CLAUDE.md'],
  ['claude/rules/project-map.md', '.claude/rules/project-map.md', ['ee1a057e8299bc76', 'a35728b3712e83a5']],
  ['claude/skills/map-review/SKILL.md', '.claude/skills/map-review/SKILL.md', ['3b63bc2d0cb5baa3', '744cac5ea8919e92', '7ff1c09c889ebe9c', '2c564cbd2d263dac', '6d3e35da1c6033c9', '7e5d413c03dfa3ea', 'd2e13952443549c2']],
  ['claude/agents/decision-checker.md', '.claude/agents/decision-checker.md'],
  ['claude/agents/codebase-guide.md', '.claude/agents/codebase-guide.md'],
  ['claude/agents/memory-curator.md', '.claude/agents/memory-curator.md'],
  ['project-map/README.md', '.project-map/README.md', ['4a02743e2f4bc9d4', '293b97c319f11bf8', '15a4bb133893f00e']],
  ['project-map/decisions.md', '.project-map/decisions.md'],
  ['project-map/dreams.md', '.project-map/dreams.md'],
  ['gitattributes.txt', '.gitattributes'],
];
const POINTER = '## Team memory';
export const sum = (text) => crypto.createHash('sha256').update(text.replace(/\r\n/g, '\n')).digest('hex').slice(0, 16);

// a target whose nearest existing folder resolves outside the repo takes no write (inRepo, map.mjs): a link at any
// depth (.claude, or .claude/skills) could aim it anywhere (/code-review's finding: only the top folder was checked)
const there = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };
// project memory needs auto memory on (Claude Code's docs). shortcut: managed settings are not read; read them if an
// organisation turns auto memory off there
function autoMemoryOff(root) {
  if (process.env.CLAUDE_CODE_DISABLE_AUTO_MEMORY === '1') return true;
  const user = path.join(configDir(), 'settings.json');
  return [user, path.join(root, '.claude', 'settings.json'), path.join(root, '.claude', 'settings.local.json')].some((f) => {
    try { return JSON.parse(fs.readFileSync(f, 'utf8')).autoMemoryEnabled === false; } catch { return false; }
  });
}

export function setup(root, pluginRoot) {
  // only at a repo's top: run anywhere else (a home folder) it would write Claude's user-level .claude/ (the
  // devils-advocate review)
  if (!fs.existsSync(path.join(root, '.git'))) return 'Setup runs at the top of a git repository. This folder is not one, so nothing was created.';
  // a home folder kept in git (dotfiles) is still a home folder: its .claude/ is Claude's user-level configuration
  let home = false;
  try { home = fs.realpathSync.native(root) === fs.realpathSync.native(os.homedir()); } catch {}
  if (home) return 'Setup runs in a project\'s repository, not in your home folder, whose .claude/ is your own Claude configuration. Nothing was created.';
  const created = [], kept = [], refused = [], forYou = [], added = new Map();
  // N9 (the field report of 2026-11-23): setup writes on whatever branch is checked out, beside any work in progress
  const head = git(root, 'branch', '--show-current');
  const branch = head.status ? 'a branch git did not name' : head.stdout.trim() ? `branch ${head.stdout.trim()}` : 'a detached HEAD';
  const before = (git(root, '--no-optional-locks', 'status', '--porcelain').stdout ?? '').split('\n').filter(Boolean).length;
  // N7: Claude Code reads ./CLAUDE.md or ./.claude/CLAUDE.md, so a repo with only the second gets no second file
  const instr = !there(path.join(root, 'CLAUDE.md')) && there(path.join(root, '.claude', 'CLAUDE.md')) ? '.claude/CLAUDE.md' : 'CLAUDE.md';
  for (const [from, to] of FILES) {
    if (to === 'CLAUDE.md' && instr !== to) { kept.push(instr); continue; }
    const target = path.join(root, to);
    if (!inRepo(root, path.dirname(target))) { refused.push(to); continue; }
    const text = fs.readFileSync(path.join(pluginRoot, 'templates', from), 'utf8');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    try { fs.writeFileSync(target, text, { flag: 'wx' }); created.push(to); } catch (e) { if (e.code !== 'EEXIST') throw e; kept.push(to); }
  }
  // what an existing file lacks is appended only to a regular, singly linked file inside the repo that git tracks under
  // that exact name with no skip-worktree or assume-unchanged flag (`ls-files -v` says "H", so untracked and ignored
  // files fail here) and shows unchanged (an empty `git status`), so the addition is its diff's only change; any other
  // file stays as it is, and the text goes to the user (06, section 4, 4b; agy's reviews). The old bytes stay a prefix;
  // the text takes the file's line ending, after a newline if the file lacks a final one
  // decoded as the hooks read it, so a UTF-16 file's section is found (AU-14, 06, 9)
  const read = (f) => { try { return decode(fs.readFileSync(path.join(root, f))); } catch { return ''; } };
  // --no-optional-locks: a status refresh would rewrite .git/index
  const unchanged = (f) => { const s = git(root, '--no-optional-locks', 'status', '--porcelain', '--', f); return s.status === 0 && s.stdout === ''; };
  const safe = (f) => {
    const p = path.join(root, f);
    let file = false;
    try { const s = fs.lstatSync(p); file = s.isFile() && s.nlink === 1; } catch {}
    // a UTF-16 file (Windows PowerShell 5.1 writes one) would take UTF-8 bytes it cannot show (the audit, 4k)
    return file && !utf16(fs.readFileSync(p)) && inRepo(root, path.dirname(p)) && git(root, 'ls-files', '-v', '--', f).stdout === `H ${f}\n` && unchanged(f);
  };
  const eolOf = (text) => (/^[^\n]*\r\n/.test(text) ? '\r\n' : '\n');
  const complete = (f, text, what, ask, blankLine) => {
    if (!safe(f)) return forYou.push(`${ask}\n${text}`);
    const p = path.join(root, f);
    const old = fs.readFileSync(p, 'utf8'), eol = eolOf(old);
    fs.appendFileSync(p, `${old && !old.endsWith('\n') ? eol : ''}${blankLine && old.trim() ? eol : ''}${text.split(/\r?\n/).join(eol)}${eol}`);
    added.set(f, what);
  };
  if (!['CLAUDE.md', '.claude/CLAUDE.md'].some((f) => read(f).includes(POINTER))) {
    const section = `${POINTER}${fs.readFileSync(path.join(pluginRoot, 'templates', 'CLAUDE.template.md'), 'utf8').split(POINTER)[1].trimEnd()}`;
    complete(instr, section, 'the team-memory section', `${instr} has no team-memory section. Proposed, at its end:`, true);
  }
  if (kept.includes('.gitattributes') && !/^\.project-map\/dreams\.md\s+merge=union\s*$/m.test(read('.gitattributes'))) {
    complete('.gitattributes', '.project-map/dreams.md merge=union', "the dream log's merge line", ".gitattributes lacks the dream log's merge line. Proposed, as its own line:", false);
  }
  // 06, section 6 (D29 reopened): a kept file that is an earlier release's template holds nothing of the repo's own,
  // so it takes this version's, in its own line ending; the diff is the upgrade, and git checkout undoes it
  // one the guard stops, or that cannot be written (read-only), is named apart: it is no change of the repo's own
  const updated = [], stuck = [];
  for (const [from, to, earlier = []] of FILES) {
    if (!kept.includes(to) || !earlier.includes(sum(read(to)))) continue;
    if (safe(to)) try { fs.writeFileSync(path.join(root, to), fs.readFileSync(path.join(pluginRoot, 'templates', from), 'utf8').split(/\r?\n/).join(eolOf(read(to)))); updated.push(to); continue; } catch {}
    stuck.push(to);
  }
  const same = kept.filter((f) => !added.has(f) && !updated.includes(f));
  const out = [`Created (${created.length}): ${created.join(', ') || 'nothing'}`, `Kept as they were (${same.length}): ${same.join(', ') || 'nothing'}`];
  if (updated.length) out.push(`Updated to this version's templates, as each was an earlier version's, unchanged (${updated.length}): ${updated.join(', ')}`);
  if (stuck.length) out.push(`Not updated, though each is an earlier version's template, since git does not show it committed and unchanged or it cannot be written (${stuck.length}): ${stuck.join(', ')}. Once it is, run setup again.`);
  if (added.size) out.push(`Added to files that existed (${added.size}): ${[...added].map(([f, what]) => `${f} (${what})`).join(', ')}`);
  if (refused.length) out.push(`Refused, because a folder resolves outside the repo: ${refused.join(', ')}`);
  // N10 (the field report): a kept file the repo changed is not replaced, so its newer template reaches it only by
  // hand. Only the plugin's own files are compared: the instruction file, the topic files and .gitattributes are the user's
  const differ = FILES.filter(([from, to]) => kept.includes(to) && !stuck.includes(to) && (to.startsWith('.claude/') || to === '.project-map/README.md')
    && read(to).replace(/\r\n/g, '\n') !== fs.readFileSync(path.join(pluginRoot, 'templates', from), 'utf8').replace(/\r\n/g, '\n'));
  if (differ.length) out.push(`Differ from this version's templates, changed in this repo (${differ.length}): ${differ.map(([from, to]) => `${to} (${path.join(pluginRoot, 'templates', from)})`).join(', ')}`);
  // 06, section 6, attempt 2: the diff comes in the report, since Claude may not read the template outside the repo
  for (const [from, to] of differ) {
    const d = git(root, 'diff', '--no-index', '--no-color', '--no-ext-diff', '--ignore-cr-at-eol', '--', to, path.join(pluginRoot, 'templates', from)).stdout ?? '';
    const at = d.indexOf('\n@@');
    if (at < 0) continue;
    const hunks = d.slice(at + 1).trimEnd();
    out.push(`Diff of ${to} against this version's template (+ the template's lines, - this file's own):\n${hunks.length > 4000 ? `${hunks.slice(0, 4000)}\n(cut at 4,000 characters)` : hunks}`);
  }
  if (autoMemoryOff(root)) out.push('Warning: auto memory is off here, so the three agents keep no project memory until it is on (/memory).');
  else out.push('The three agents keep their notes in .claude/agent-memory/, made on their first write; review those with the map.');
  out.push(...forYou.map((s) => `For you: ${s}`));
  // a run that wrote nothing has no files of its own to keep apart (the review of 4j)
  const wrote = created.length || added.size || updated.length;
  out.push(`${wrote ? 'Written' : 'Ran'} on ${branch}.${wrote && before ? ` The tree already held ${before} uncommitted change${before === 1 ? '' : 's'} before setup ran: commit setup's files on their own.` : ''}`);
  out.push(wrote ? 'Nothing is committed: review the new files in the diff, and commit them.' : 'Nothing was written.');
  return out.join('\n');
}
