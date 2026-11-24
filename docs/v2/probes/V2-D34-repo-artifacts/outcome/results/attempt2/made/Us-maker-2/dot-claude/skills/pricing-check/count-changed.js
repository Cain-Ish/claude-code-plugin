// Usage: node count-changed.js <old-report> <new-report>
// Prints how many golden cases differ (changed, added or removed), keyed by "case <id>".
import fs from 'node:fs';

const load = (p) => new Map(
  fs.readFileSync(p, 'utf8').split(/\r?\n/).filter(Boolean)
    .map((line) => [line.match(/^case (\S+)/)?.[1] ?? line, line.trim()]),
);

const [oldPath, newPath] = process.argv.slice(2);
const before = load(oldPath);
const after = load(newPath);
const ids = new Set([...before.keys(), ...after.keys()]);
console.log([...ids].filter((id) => before.get(id) !== after.get(id)).length);
