// Scores part 1 of V2-D21 from the judges' verdicts, the run keys and the hand verification. Writes counts only.
// Usage: node score.mjs <d21-raw-dir> [--list]. --list prints the claimed duplicates to verify (local output only).
import fs from 'node:fs';

const [dir, flag] = process.argv.slice(2);
const TASKS = ['P1-build', 'P2-build', 'R0-build'];
const read = (f) => JSON.parse(fs.readFileSync(`${dir}/${f}`, 'utf8'));
const verify = fs.existsSync(`${dir}/verify.json`) ? read('verify.json') : {};
const same = (a, b) => (a ?? '').toLowerCase().includes((b ?? '').toLowerCase());

const out = { tasks: {}, counted: { runs: 0, runsWithDuplicate: 0 }, controlsNamed: 0 };
for (const task of TASKS) {
  const key = read(`key-${task}.json`), v = read(`verdicts-${task}.json`);
  const labels = Object.keys(key).filter((k) => k !== 'control');
  const judged = new Map(v.runs.map((r) => [r.label, r]));
  const c = key.control;
  const isControl = (r, u) => r.label === c.label && same(u.unit, c.unit);
  const control = judged.get(c.label)?.units.find((u) => isControl({ label: c.label }, u));
  const named = control?.verdict === 'duplicate' && same(control.original?.file, c.original.file) && same(control.original?.unit, c.original.unit);
  const t = { runs: labels.length, judgedRuns: 0, units: 0, claimed: 0, confirmed: 0, rejected: 0, unverified: 0,
    runsWithDuplicate: 0, runsWithReuse: 0, byArm: {}, controlNamed: named };
  for (const label of labels) {
    const r = judged.get(label);
    const arm = key[label].split('/')[0];
    const a = (t.byArm[arm] ??= { runs: 0, runsWithDuplicate: 0, runsWithReuse: 0 });
    a.runs++;
    if (!r) continue;
    t.judgedRuns++;
    const units = r.units.filter((u) => !isControl(r, u));
    t.units += units.length;
    let dup = false;
    for (const u of units.filter((x) => x.verdict === 'duplicate')) {
      t.claimed++;
      const s = verify[task]?.[label]?.[u.unit];
      if (flag === '--list') console.log(task, label, key[label], `${u.file} :: ${u.unit}`, '->', `${u.original?.file} :: ${u.original?.unit}`, '|', u.why, '|', s ?? 'UNVERIFIED');
      if (s === 'confirmed') { t.confirmed++; dup = true; } else if (s) t.rejected++; else t.unverified++;
    }
    if (dup) { t.runsWithDuplicate++; a.runsWithDuplicate++; }
    if ((r.reused ?? []).length) { t.runsWithReuse++; a.runsWithReuse++; }
  }
  t.informative = t.runsWithReuse >= 3;
  if (named) out.controlsNamed++;
  if (t.informative) { out.counted.runs += t.runs; out.counted.runsWithDuplicate += t.runsWithDuplicate; }
  out.tasks[task] = t;
}
const informative = TASKS.filter((k) => out.tasks[k].informative).length;
const complete = TASKS.every((k) => out.tasks[k].judgedRuns === out.tasks[k].runs && out.tasks[k].unverified === 0);
out.verdict = !complete ? 'incomplete'
  : out.controlsNamed < 3 || informative < 2 ? 'no verdict: attempt 1 fails'
  : out.counted.runsWithDuplicate <= 1 ? '(a) locks' : 'part 2: (b) and (c) against the duplicating runs';
console.log(JSON.stringify(out, null, 1));
if (flag !== '--list' && complete) {
  fs.mkdirSync(new URL('results/', import.meta.url), { recursive: true });
  fs.writeFileSync(new URL('results/part1.json', import.meta.url), JSON.stringify(out, null, 1) + '\n');
}
