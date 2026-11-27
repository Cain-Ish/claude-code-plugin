// plan-check, case "newest": plan-status.md names the newest step of the copy's docs/v2/06-first-slice.md (by the
// version its heading names, or else by its number) and at least one decision the ledger's status table leaves open
// (last status word OPEN, REOPENED or BLOCKED), so it does not call everything finished. Any wording.
import fs from 'node:fs';

const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
let ok = false;
try {
  const heads = now('docs/v2/06-first-slice.md').split(/\r?\n/).filter((l) => /^## \d+:/.test(l));
  const last = heads.at(-1) ?? '';
  const version = /\b\d+\.\d+\.\d+\b/.exec(last)?.[0];
  const num = /^## (\d+):/.exec(last)?.[1];
  const open = [];
  for (const l of now('docs/v2/DECISIONS.md').split(/\r?\n/)) {
    const m = /^\| (V2-D\d+) \|[^|]*\|([^|]*)\|/.exec(l.replace(/\\\|/g, '/')); // an escaped pipe is cell text
    if (!m) continue;
    const words = m[2].match(/\b(re-LOCKED|REOPENED|LOCKED|OPEN|BLOCKED|SUPERSEDED|DROPPED)\b/g) ?? [];
    if (['OPEN', 'REOPENED', 'BLOCKED'].includes(words.at(-1))) open.push(m[1]);
  }
  const report = now('plan-status.md');
  const newest = version ? report.includes(version) : new RegExp(`\\b(section|step) ${num}\\b`, 'i').test(report);
  ok = Boolean(last) && newest && open.length > 0 && open.some((id) => new RegExp(`\\b(V2-)?${id.slice(3)}\\b`).test(report));
} catch {}
process.exit(ok ? 0 : 1);
