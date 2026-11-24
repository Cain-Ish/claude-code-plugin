// 06, section 7, 7a, check 3: grades one held-out or should-not run in its workspace. Fixed with the fixture,
// before any run. A held-out run passes when the migrations are the fixture's plus exactly one new 0003 pair (no
// other migration added or changed), the check script prints OK, and the up file does the task.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

export const TASKS = {
  phone: 'Add a database migration that adds a nullable phone column to the users table.',
  tags: 'Add a database migration that creates a tags table with an id and a name.',
  rename: 'Rename the function fmt in src/util.js to formatDate and update its callers.',
};
const UP = {
  phone: [/alter\s+table\s+["`]?users["`]?\s+add\s+(column\s+)?["`]?phone\b/i],
  tags: [/create\s+table\s+(if\s+not\s+exists\s+)?["`]?tags\b/i, /\bid\b/i, /\bname\b/i],
};
const DOWN = { phone: [/\bphone\b/i], tags: [/drop\s+table\s+(if\s+exists\s+)?["`]?tags\b/i] };

const migrations = (root) => Object.fromEntries(fs.readdirSync(path.join(root, 'db/migrations')).filter((f) => f.endsWith('.sql'))
  .map((f) => [f, fs.readFileSync(path.join(root, 'db/migrations', f), 'utf8')]));

export function grade(ws, fixture, task) {
  if (task === 'rename') {
    const util = fs.readFileSync(path.join(ws, 'src/util.js'), 'utf8');
    const src = ['report.js', 'invoice.js'].map((f) => fs.readFileSync(path.join(ws, 'src', f), 'utf8')).join('\n');
    return { task, done: /function\s+formatDate\b/.test(util) && !/\bfmt\b/.test(util + src) };
  }
  const before = migrations(fixture), after = migrations(ws);
  const changed = Object.keys(before).filter((f) => after[f] !== before[f]);
  const added = Object.keys(after).filter((f) => !(f in before));
  const up = added.find((f) => /^0003_[\w-]+\.sql$/.test(f) && !f.endsWith('.down.sql'));
  const down = up && up.replace(/\.sql$/, '.down.sql');
  let check = '';
  try { check = execFileSync(process.execPath, ['scripts/check-migrations.js'], { cwd: ws, encoding: 'utf8' }).trim(); } catch (e) { check = String(e.stdout ?? '').trim() || 'error'; }
  const r = {
    task,
    numbered: Boolean(up && added.length === 2 && added.includes(down)),
    added,
    changed,
    checkOk: check === 'OK',
    upDoesTask: Boolean(up && UP[task].every((re) => re.test(after[up]))),
    downUndoes: Boolean(up && after[down] && DOWN[task].every((re) => re.test(after[down]))),
  };
  r.pass = r.numbered && changed.length === 0 && r.checkOk && r.upDoesTask && r.downUndoes;
  return r;
}
