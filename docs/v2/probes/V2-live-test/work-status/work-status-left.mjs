// work-status, case "left": left.md names what the plan still has open: 8a's hardening (by its ids, or as 8a or 8k,
// where it moved on 2026-11-25), group M's measurement debts, and the final audit's items. It accepts any wording that
// names them, since the plan's records change between commits (the live test's L-12).
import fs from 'node:fs';

let text = '';
try { text = fs.readFileSync('left.md', 'utf8'); } catch {}
const fixes = /\bH[3-7]\b|\bD-[1-6]\b|\bF-1\b|\b8a\b|\b8k\b/i.test(text);
const debts = /group M\b|measurement deb|\bS8\b|\bA1\b/i.test(text);
const audit = /audit/i.test(text);
process.exitCode = fixes && debts && audit ? 0 : 1;
