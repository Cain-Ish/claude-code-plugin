// 06, section 3, S5 (V2-D29): setup copies plugin/templates/ into a repo, Anthropic's layout for Claude. Each file is
// created with 'wx', so a file that exists is never overwritten; nothing is committed. Templates sit under undotted
// names, so this plugin's own repo never loads them as live rules, agents or a nested CLAUDE.md. Since 06, section 4,
// 4b (D29 reopened), an instruction file or .gitattributes that lacks setup's section or line gets it appended, but only
// when git shows that file committed and unchanged.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { git, inRepo, configDir } from './map.mjs';

const FILES = [
  ['CLAUDE.template.md', 'CLAUDE.md'],
  ['claude/rules/project-map.md', '.claude/rules/project-map.md'],
  ['claude/skills/map-review/SKILL.md', '.claude/skills/map-review/SKILL.md'],
  ['claude/agents/decision-checker.md', '.claude/agents/decision-checker.md'],
  ['claude/agents/codebase-guide.md', '.claude/agents/codebase-guide.md'],
  ['claude/agents/memory-curator.md', '.claude/agents/memory-curator.md'],
  ['project-map/README.md', '.project-map/README.md'],
  ['project-map/decisions.md', '.project-map/decisions.md'],
  ['project-map/dreams.md', '.project-map/dreams.md'],
  ['gitattributes.txt', '.gitattributes'],
];
const POINTER = '## Team memory';

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
  const read = (f) => { try { return fs.readFileSync(path.join(root, f), 'utf8'); } catch { return ''; } };
  // --no-optional-locks: a status refresh would rewrite .git/index
  const unchanged = (f) => { const s = git(root, '--no-optional-locks', 'status', '--porcelain', '--', f); return s.status === 0 && s.stdout === ''; };
  const complete = (f, text, what, ask, blankLine) => {
    const p = path.join(root, f);
    let file = false;
    try { const s = fs.lstatSync(p); file = s.isFile() && s.nlink === 1; } catch {}
    if (!file || !inRepo(root, path.dirname(p)) || git(root, 'ls-files', '-v', '--', f).stdout !== `H ${f}\n` || !unchanged(f)) return forYou.push(`${ask}\n${text}`);
    const old = fs.readFileSync(p, 'utf8'), eol = /^[^\n]*\r\n/.test(old) ? '\r\n' : '\n';
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
  const same = kept.filter((f) => !added.has(f));
  const out = [`Created (${created.length}): ${created.join(', ') || 'nothing'}`, `Kept as they were (${same.length}): ${same.join(', ') || 'nothing'}`];
  if (added.size) out.push(`Added to files that existed (${added.size}): ${[...added].map(([f, what]) => `${f} (${what})`).join(', ')}`);
  if (refused.length) out.push(`Refused, because a folder resolves outside the repo: ${refused.join(', ')}`);
  if (autoMemoryOff(root)) out.push('Warning: auto memory is off here, so the three agents keep no project memory until it is on (/memory).');
  out.push(...forYou.map((s) => `For you: ${s}`));
  out.push('Nothing is committed: review the new files in the diff, and commit them.');
  return out.join('\n');
}
