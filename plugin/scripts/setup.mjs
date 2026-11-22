// 06, section 3, S5 (V2-D29): setup copies plugin/templates/ into a repo, Anthropic's layout for Claude. Each file is
// created with 'wx', so a file that exists is never touched; nothing is committed. Templates sit under undotted names,
// so this plugin's own repo never loads them as live rules, agents or a nested CLAUDE.md.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

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

// a target whose nearest existing folder resolves outside the repo takes no write: a link at any depth (.claude, or
// .claude/skills) could aim it anywhere (/code-review's finding: only the top folder was checked)
// The walk stops at a dangling link too (lstat sees it, existsSync does not), and a path that cannot be resolved counts
// as outside (agy's release round: mkdir followed a dangling link out of the repo)
const there = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };
function outside(root, target) {
  try {
    let q = path.dirname(target);
    while (!there(q)) q = path.dirname(q);
    const real = fs.realpathSync.native(q);
    const base = fs.realpathSync.native(root);
    return real !== base && !real.startsWith(base + path.sep);
  } catch { return true; }
}
// project memory needs auto memory on (Claude Code's docs). shortcut: managed settings are not read; read them if an
// organisation turns auto memory off there
function autoMemoryOff(root) {
  if (process.env.CLAUDE_CODE_DISABLE_AUTO_MEMORY === '1') return true;
  const user = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json');
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
  const created = [], kept = [], refused = [], forYou = [];
  for (const [from, to] of FILES) {
    const target = path.join(root, to);
    if (outside(root, target)) { refused.push(to); continue; }
    const text = fs.readFileSync(path.join(pluginRoot, 'templates', from), 'utf8');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    try { fs.writeFileSync(target, text, { flag: 'wx' }); created.push(to); } catch (e) { if (e.code !== 'EEXIST') throw e; kept.push(to); }
  }
  // what an existing file lacks is the user's to add (S5: setup never modifies a file that exists)
  const read = (f) => { try { return fs.readFileSync(path.join(root, f), 'utf8'); } catch { return ''; } };
  if (kept.includes('CLAUDE.md') && !read('CLAUDE.md').includes(POINTER)) {
    const block = fs.readFileSync(path.join(pluginRoot, 'templates', 'CLAUDE.template.md'), 'utf8').split(POINTER)[1];
    forYou.push(`CLAUDE.md has no team-memory section. Proposed, at its end:\n${POINTER}${block.trimEnd()}`);
  }
  if (kept.includes('.gitattributes') && !/^\.project-map\/dreams\.md\s+merge=union\s*$/m.test(read('.gitattributes'))) {
    forYou.push('.gitattributes lacks the dream log\'s merge line. Proposed, as its own line:\n.project-map/dreams.md merge=union');
  }
  const out = [`Created (${created.length}): ${created.join(', ') || 'nothing'}`, `Kept as they were (${kept.length}): ${kept.join(', ') || 'nothing'}`];
  if (refused.length) out.push(`Refused, because a folder resolves outside the repo: ${refused.join(', ')}`);
  if (autoMemoryOff(root)) out.push('Warning: auto memory is off here, so the three agents keep no project memory until it is on (/memory).');
  out.push(...forYou.map((s) => `For you: ${s}`));
  out.push('Nothing is committed: review the new files in the diff, and commit them.');
  return out.join('\n');
}
