// Shared by the harness (native.mjs) and the stage 2 hook (deliver.mjs): a rule's check, and the files a session
// changed in its worktree.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const slash = (p) => String(p ?? '').replace(/\\/g, '/');

// fresh: files the run created; a newOnly check skips files that existed before (their old content is not the run's).
export function check(c, files, reply, fresh = null) {
  const re = (s) => new RegExp(s, c.flags ?? '');
  const sel = c.where === 'reply' ? [reply] : Object.entries(files)
    .filter(([p]) => new RegExp(c.path ?? '.').test(p) && (!c.newOnly || !fresh || fresh.has(p))).map(([, t]) => t);
  if (!sel.length) return false;
  const all = (x) => [x ?? []].flat();
  if (!all(c.must).every((m) => sel.some((t) => re(m).test(t)))) return false;
  if (all(c.mustNot).some((m) => sel.some((t) => re(m).test(t)))) return false;
  return true;
}

export function changedFiles(dir) {
  const out = {};
  const fresh = new Set();
  const st = spawnSync('git', ['-c', 'core.longpaths=true', '-c', 'core.quotepath=off', 'status', '--porcelain', '-uall'],
    { cwd: dir, encoding: 'utf8', maxBuffer: 64 << 20 });
  for (const l of (st.stdout ?? '').split('\n')) {
    const p = slash(l.slice(3).trim().replace(/^"|"$/g, ''));
    if (!p || p === '.claude/settings.local.json' || !fs.existsSync(path.join(dir, p))) continue;
    out[p] = fs.readFileSync(path.join(dir, p), 'utf8');
    if (l.startsWith('??') || l.startsWith('A')) fresh.add(p);
  }
  return { files: out, fresh };
}
