// plan-check, case "where" (use: false): answer.md names each file the copy's plugin/scripts/dream.mjs writes or copies
// straight into the run folder (path.join(run, '<name>')), leaving out dot files. Any wording.
import fs from 'node:fs';

const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
let ok = false;
try {
  const names = [...now('plugin/scripts/dream.mjs').matchAll(/(?:writeFileSync|copyFileSync)\([^;]*?path\.join\(run, '([^']+)'\)/g)]
    .map((m) => m[1]).filter((n) => !n.startsWith('.'));
  const answer = now('answer.md');
  ok = names.length > 0 && names.every((n) => answer.includes(n));
} catch {}
process.exit(ok ? 0 : 1);
