// Runs scripts/golden.js, saves its output to reports/pricing-<YYYY-MM-DD>.txt (today, local date),
// and prints how many golden cases changed since the most recent earlier report.
// A case counts as changed if its line differs, or it was added or removed.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = new URL('..', import.meta.url);
const reportsDir = new URL('reports/', root);
const d = new Date();
const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

const output = execFileSync(process.execPath, [fileURLToPath(new URL('scripts/golden.js', root))], { encoding: 'utf8' });

const previous = fs.readdirSync(reportsDir)
  .filter((f) => /^pricing-\d{4}-\d{2}-\d{2}\.txt$/.test(f) && f < `pricing-${today}.txt`)
  .sort()
  .at(-1);

fs.writeFileSync(new URL(`pricing-${today}.txt`, reportsDir), output);

const byCase = (text) => new Map(text.split(/\r?\n/).filter(Boolean).map((line) => [line.match(/^case (\S+)/)?.[1] ?? line, line]));
let changed = null;
if (previous) {
  const before = byCase(fs.readFileSync(new URL(previous, reportsDir), 'utf8'));
  const after = byCase(output);
  changed = 0;
  for (const id of new Set([...before.keys(), ...after.keys()])) {
    if (before.get(id) !== after.get(id)) changed++;
  }
}

console.log(`report: reports/pricing-${today}.txt`);
console.log(`previous: ${previous ? `reports/${previous}` : 'none'}`);
console.log(`changed: ${changed ?? 'all (no previous report)'}`);
