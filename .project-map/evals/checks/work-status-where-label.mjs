// work-status, case "where-label" (where it should not be used): answer.md names plugin/scripts/map.mjs, the product
// file that writes the "unverified quote" label at this commit.
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('answer.md', 'utf8'); } catch {}
process.exitCode = /map\.mjs/.test(text) ? 0 : 1;
