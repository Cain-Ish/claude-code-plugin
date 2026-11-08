// The loop's scan step (README, "The loop"): node count.mjs <field repo> <frozen folder>
// Runs field.mjs and field-scope.mjs on every transcript in the frozen folder, and writes field.json and scope.json
// beside them. The folder is under research/raw/ (gitignored): the outputs hold extracts.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [repo, dir] = process.argv.slice(2);
if (!repo || !dir) throw new Error('usage: node count.mjs <field repo> <frozen folder>');
const here = path.dirname(fileURLToPath(import.meta.url));
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(dir, f));
if (!files.length) throw new Error(`no transcripts in ${dir}`);
for (const [script, args] of [['field.mjs', [path.join(dir, 'field.json')]], ['field-scope.mjs', [repo, path.join(dir, 'scope.json')]]]) {
  console.log(`\n== ${script}`);
  const r = spawnSync(process.execPath, [path.join(here, script), ...args, ...files], { stdio: 'inherit' });
  if (r.status) process.exit(r.status);
}
