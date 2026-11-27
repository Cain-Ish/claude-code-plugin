// plan-check, case "open": plan-status.md names every decision the ledger's status table leaves open, read from the
// copy's own docs/v2/DECISIONS.md: a row whose last status word is OPEN, REOPENED or BLOCKED. Any wording, as V2-Dnn or Dnn.
import fs from 'node:fs';

const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
let ok = false;
try {
  const open = [];
  for (const l of now('docs/v2/DECISIONS.md').split(/\r?\n/)) {
    const m = /^\| (V2-D\d+) \|[^|]*\|([^|]*)\|/.exec(l.replace(/\\\|/g, '/')); // an escaped pipe is cell text
    if (!m) continue;
    const words = m[2].match(/\b(re-LOCKED|REOPENED|LOCKED|OPEN|BLOCKED|SUPERSEDED|DROPPED)\b/g) ?? [];
    if (['OPEN', 'REOPENED', 'BLOCKED'].includes(words.at(-1))) open.push(m[1]);
  }
  const report = now('plan-status.md');
  ok = report.trim() !== '' && open.every((id) => new RegExp(`\\b(V2-)?${id.slice(3)}\\b`).test(report));
} catch {}
process.exit(ok ? 0 : 1);
