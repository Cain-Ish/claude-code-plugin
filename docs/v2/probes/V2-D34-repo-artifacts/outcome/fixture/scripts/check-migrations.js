// Checks db/migrations: every migration has its .down.sql, numbers are unique, and every number above 0002 lies in
// a range reserved in db/reserved.txt. Prints OK, or one line per problem.
import fs from 'node:fs';

const dir = 'db/migrations';
const ranges = fs.readFileSync('db/reserved.txt', 'utf8').split('\n')
  .map((l) => l.match(/^\s*(\S+)\s+(\d{4})-(\d{4})\s*$/)).filter(Boolean)
  .map(([, team, lo, hi]) => ({ team, lo: Number(lo), hi: Number(hi) }));
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.sql'));
const ups = files.filter((f) => !f.endsWith('.down.sql'));
const problems = [];
const seen = new Map();
for (const f of ups) {
  const m = f.match(/^(\d{4})_[\w-]+\.sql$/);
  if (!m) { problems.push(`bad name: ${f}`); continue; }
  const n = Number(m[1]);
  if (seen.has(n)) problems.push(`number ${m[1]} used twice: ${seen.get(n)}, ${f}`);
  seen.set(n, f);
  if (!files.includes(f.replace(/\.sql$/, '.down.sql'))) problems.push(`no rollback: ${f}`);
  if (n > 2 && !ranges.some((r) => n >= r.lo && n <= r.hi)) problems.push(`number outside every reserved range: ${f}`);
}
for (const f of files.filter((x) => x.endsWith('.down.sql'))) {
  if (!ups.includes(f.replace(/\.down\.sql$/, '.sql'))) problems.push(`rollback without a migration: ${f}`);
}
console.log(problems.length ? problems.join('\n') : 'OK');
process.exitCode = problems.length ? 1 : 0;
