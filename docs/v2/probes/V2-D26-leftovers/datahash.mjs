// V2-D26's data check: one hash over the user's v1 data, leaving out what the route removes (the brain's bin/
// folder and its timer env file). Usage: node datahash.mjs <brain dir> <knowledge dir>
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const h = crypto.createHash('sha256');
let n = 0;
for (const root of process.argv.slice(2)) {
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = path.join(d, e.name);
      const rel = path.relative(root, p).split(path.sep).join('/');
      if (rel === 'bin' || rel === '.extract-timer-env') continue;
      if (e.isDirectory()) walk(p); else { h.update(`${root.length}:${rel}\0`).update(fs.readFileSync(p)); n++; }
    }
  };
  if (fs.existsSync(root)) walk(root);
}
console.log(`${h.digest('hex').slice(0, 16)} (${n} files)`);
