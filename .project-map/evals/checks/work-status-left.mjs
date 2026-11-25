// work-status, case "left": left.md names what the plan still has open at this commit (06, section 8): the fixes 8a
// kept open after its block (H3 to H7, D-1 to D-6, F-1), group M's measurement debts, and the final audit.
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('left.md', 'utf8'); } catch {}
const fixes = /\bH[3-7]\b|\bD-[1-6]\b|\bF-1\b|\b8a\b.{0,60}\b(fix|finding)/i.test(text);
const debts = /group M\b|measurement deb|\bS8\b|\bA1\b/i.test(text);
const audit = /audit/i.test(text);
process.exitCode = fixes && debts && audit ? 0 : 1;
