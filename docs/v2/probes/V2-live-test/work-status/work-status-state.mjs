// work-status, case "state": status.md gives the current section's steps their states: at least one passed, and 8k
// (registered 2026-11-25, not built at this commit) as registered, planned or not built. Steps may be named in ranges
// ("8b to 8j"), so no single passed step's id is required (the live test's L-12).
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('status.md', 'utf8'); } catch {}
const passed = /\bpass(ed|es)?\b/i.test(text);
const open = text.split(/\r?\n/).some((l) => /\b8k\b/.test(l) && /registered|not (yet )?built|planned|to build|pending/i.test(l));
process.exitCode = passed && open ? 0 : 1;
