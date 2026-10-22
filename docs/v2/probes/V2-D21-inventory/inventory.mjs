// V2-D21 option (b), the inventory: the files tracked at a commit whose path matches a pattern, grouped by directory,
// names only. No parser: git's own file list is the whole input, for any stack.
//   node inventory.mjs <repo> <commit> <path regex> <out file> [first line]
// V2-D22's pull check passes its own first line (the instruction) and a document-file pattern.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const [repo, commit, pattern, out, header] = process.argv.slice(2);
const re = new RegExp(pattern);
const files = execFileSync('git', ['-C', repo, 'ls-tree', '-r', '--name-only', commit], { encoding: 'utf8', maxBuffer: 64 << 20 })
  .split('\n').filter((p) => p && re.test(p));
const byDir = new Map();
for (const p of files) {
  const i = p.lastIndexOf('/');
  const d = i < 0 ? '.' : p.slice(0, i);
  if (!byDir.has(d)) byDir.set(d, []);
  byDir.get(d).push(p.slice(i + 1));
}
const text = (header ?? '[d21-inventory] Files that already exist in this repository (git ls-files at this commit; '
  + 'source directories only), by directory:') + '\n' + [...byDir].map(([d, f]) => `${d}/: ${f.join(', ')}`).join('\n') + '\n';
fs.writeFileSync(out, text);
console.log(`${files.length} files, ${byDir.size} directories, ${Buffer.byteLength(text)} bytes`);
