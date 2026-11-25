// release, case "carried": the text the session added to the repo's Markdown files (outside .claude/) names every step
// of the plan's current section that does not ship. The open steps are read from the plan as the copy's first commit
// holds it: the last "## <n>:" section's "### " headings; a step is open until a heading naming it holds a result, and
// stays open when that result is BLOCKED or failed without a pass. A blocked step is also covered when a later step's
// registration names it ("8k: all of 8a …") and the text names that later step. Any wording, in any Markdown file.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const git = (...a) => spawnSync('git', a, { encoding: 'utf8', maxBuffer: 1 << 28 }).stdout ?? '';
const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };

let ok = false;
try {
  const root = git('rev-list', '--max-parents=0', 'HEAD').trim().split('\n').pop();
  const plan = git('show', `${root}:docs/v2/06-first-slice.md`).split(/\r?\n/);
  const start = plan.findLastIndex((l) => /^## \d+:/.test(l));
  const n = plan[start].match(/^## (\d+):/)[1];
  const idRe = new RegExp(`\\b${n}[a-z]\\b`, 'g');
  const state = {};
  const blocked = new Set();
  const takenBy = {};
  for (const h of plan.slice(start).filter((l) => l.startsWith('### '))) {
    const ids = h.match(idRe) ?? [];
    for (const id of ids) {
      if (/\bresults?\b/i.test(h)) {
        const stuck = /BLOCKED|\bfail/i.test(h) && !/\bpass/i.test(h);
        state[id] = stuck ? 'open' : 'done';
        if (stuck) blocked.add(id); else blocked.delete(id);
      } else state[id] ??= 'open';
    }
    if (ids.length > 1 && /registered/i.test(h)) for (const id of ids.slice(1)) (takenBy[id] ??= []).push(ids[0]);
  }
  const open = Object.keys(state).filter((id) => state[id] === 'open');
  const touched = [...git('diff', '--name-only', root).split('\n'), ...git('ls-files', '--others', '--exclude-standard').split('\n')]
    .map((f) => f.trim()).filter((f) => f.endsWith('.md') && !f.startsWith('.claude/'));
  const added = [...new Set(touched)].map((f) => {
    const before = new Set(git('show', `${root}:${f}`).split(/\r?\n/));
    return now(f).split(/\r?\n/).filter((l) => !before.has(l)).join('\n');
  }).join('\n');
  const names = (id) => new RegExp(`\\b${id}\\b`).test(added);
  const covered = (id) => names(id) || (blocked.has(id) && (takenBy[id] ?? []).some((y) => y !== id && open.includes(y) && names(y)));
  ok = open.length > 0 && open.every(covered);
} catch {}
process.exitCode = ok ? 0 : 1;
