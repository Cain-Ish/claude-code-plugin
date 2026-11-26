// 8n check 1: the tree equals the allowlist, no test/ under plugin/. Usage: node check1.mjs <tree>. Exit 1 names each bad path.
import { readdirSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { ALLOW, EXCLUDE } from './product.mjs';

const tree = process.argv[2];
const files = readdirSync(tree, { recursive: true, withFileTypes: true }).filter((d) => d.isFile())
  .map((d) => relative(tree, join(d.parentPath, d.name)).split(sep).join('/')).filter((f) => f !== '.git' && !f.startsWith('.git/')); // a checkout's own git data is not the tree
const under = (f, p) => f === p || f.startsWith(p + '/');
const bad = [
  ...files.filter((f) => !ALLOW.some((p) => under(f, p)) || EXCLUDE.some((p) => under(f, p))).map((f) => `extra: ${f}`),
  ...ALLOW.filter((p) => !files.some((f) => under(f, p))).map((p) => `missing: ${p}`),
];
bad.forEach((b) => console.log(b));
console.log(bad.length ? `check 1 FAILED (${bad.length})` : `check 1 ok (${files.length} files)`);
process.exit(bad.length ? 1 : 0);
