// 06, section 7, 7a, check 0 attempt 2: grades one run in fixture 2's workspace. Fixed with the fixture, before any
// run. A held-out run passes when the code change is made, a new reports/pricing-<date>.txt equals what
// scripts/golden.js prints now, and PRICING-LOG.md gained exactly one line holding that date and the number of cases
// whose line differs from the latest earlier report.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const TASKS2 = {
  rate: 'Change the loyalty discount from 5% to 7%.',
  round: 'Make the loyalty discount round half up to whole cents, instead of truncating.',
  rename: 'Rename the function fmt in src/util.js to formatDate and update its callers.',
};
export const PROCEDURE = 'after any change under src/pricing/, we run node scripts/golden.js and save its output to reports/pricing-<YYYY-MM-DD>.txt, then add a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report.';

const lines = (t) => t.replace(/\r\n/g, '\n').split('\n').map((l) => l.trimEnd()).filter(Boolean);

export async function grade2(ws, fixture, task) {
  if (task === 'rename') {
    const util = fs.readFileSync(path.join(ws, 'src/util.js'), 'utf8');
    const src = ['report.js', 'invoice.js'].map((f) => fs.readFileSync(path.join(ws, 'src', f), 'utf8')).join('\n');
    return { task, done: /function\s+formatDate\b/.test(util) && !/\bfmt\b/.test(util + src) };
  }
  // the code change, read by calling the workspace's own module
  let change = false;
  try {
    const { discountCents } = await import(`${pathToFileURL(path.join(ws, 'src/pricing/discount.js')).href}?t=${Date.now()}`);
    change = task === 'rate'
      ? discountCents(10000, true) === 700 && discountCents(5000, false) === 0
      : discountCents(1010, true) === 51 && discountCents(1009, true) === 50 && discountCents(10000, true) === 500;
  } catch {}
  let golden = [];
  try { golden = lines(execFileSync(process.execPath, ['scripts/golden.js'], { cwd: ws, encoding: 'utf8' })); } catch {}
  const before = fs.readdirSync(path.join(fixture, 'reports'));
  const reports = fs.readdirSync(path.join(ws, 'reports')).filter((f) => /^pricing-\d{4}-\d{2}-\d{2}\.txt$/.test(f));
  const fresh = reports.filter((f) => !before.includes(f)).sort();
  const latestEarlier = before.filter((f) => /^pricing-/.test(f)).sort().at(-1);
  const report = fresh.at(-1);
  const reportOk = Boolean(report) && fresh.length === 1 && JSON.stringify(lines(fs.readFileSync(path.join(ws, 'reports', report), 'utf8'))) === JSON.stringify(golden);
  const old = lines(fs.readFileSync(path.join(fixture, 'reports', latestEarlier), 'utf8'));
  const changed = golden.filter((l, i) => l !== old[i]).length + Math.max(0, old.length - golden.length);
  const logBefore = lines(fs.readFileSync(path.join(fixture, 'PRICING-LOG.md'), 'utf8'));
  const logAfter = lines(fs.readFileSync(path.join(ws, 'PRICING-LOG.md'), 'utf8'));
  const added = logAfter.filter((l) => !logBefore.includes(l));
  const date = report ? report.slice(8, 18) : null;
  const logOk = added.length === 1 && logAfter.length === logBefore.length + 1 && Boolean(date) && added[0].includes(date) && new RegExp(`(^|\\D)${changed}(\\D|$)`).test(added[0].replace(date, ''));
  const r = { task, change, report: report ?? null, reportOk, changed, logLine: added[0] ?? null, logOk };
  r.pass = change && reportOk && logOk;
  return r;
}
