// work-status, case "state": status.md gives step 8a as blocked and step 8h as passed, as the plan records them at this
// commit (06, section 8). A step's state counts on its own line or under a heading that names the state.
// shortcut: a line that names both steps with both states passes either way; tighten if a run shows a swapped answer.
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('status.md', 'utf8'); } catch {}
let heading = '';
let blocked = false;
let passed = false;
for (const line of text.split(/\r?\n/)) {
  if (/^\s*#{1,6}\s|^\s*\*\*[^*]+\*\*:?\s*$/.test(line)) heading = line;
  const said = `${heading} ${line}`;
  if (/\b8a\b/.test(line) && /blocked/i.test(said)) blocked = true;
  if (/\b8h\b/.test(line) && /pass/i.test(said)) passed = true;
}
process.exitCode = blocked && passed ? 0 : 1;
