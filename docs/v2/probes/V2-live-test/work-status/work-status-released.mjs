// work-status, case "released": status.md says 2.6.0 is in progress and not released, and names 2.5.1, the last
// release, as plugin.json and the plan record them at this commit.
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('status.md', 'utf8'); } catch {}
const open = /\b(not|un)[\s-]*(yet\s+)?(released|merged|shipped|tagged|published)\b|in progress/i.test(text);
process.exitCode = /2\.6\.0/.test(text) && /2\.5\.1/.test(text) && open ? 0 : 1;
