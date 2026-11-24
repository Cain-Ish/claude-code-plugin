// Usage: node count-changed.mjs <previous-report> <new-report>
// Prints how many golden cases differ between two reports: changed, added or removed (keyed by case id).
import fs from 'node:fs';

const parse = (file) => new Map(
  fs.readFileSync(file, 'utf8').split(/\r?\n/).filter((l) => l.trim())
    .map((l) => [l.trim().split(/\s+/)[1], l.trim().replace(/\s+/g, ' ')]),
);

const [prev, next] = process.argv.slice(2).map(parse);
let changed = 0;
for (const id of new Set([...prev.keys(), ...next.keys()])) {
  if (prev.get(id) !== next.get(id)) changed++;
}
console.log(changed);
