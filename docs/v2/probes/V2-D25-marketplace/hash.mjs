// The product hash of a plugin folder, as plugin/test/selftest.mjs computes it (its `test` folder left out), also
// leaving out a cached copy's `.in_use/` process markers. Usage: node hash.mjs <plugin dir>
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
const files = [];
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) if (e.name !== 'test' && e.name !== '.in_use') (e.isDirectory() ? walk : (p) => files.push(p))(path.join(d, e.name)); };
walk(root);
const h = crypto.createHash('sha256');
for (const f of files.map((p) => path.relative(root, p).split(path.sep).join('/')).sort()) h.update(f).update(fs.readFileSync(path.join(root, f), 'utf8').replace(/\r\n/g, '\n'));
console.log(h.digest('hex').slice(0, 12));
