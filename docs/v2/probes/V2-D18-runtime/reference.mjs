// D18's reference-state bench driver, as 06's 2h attempt 4 registered it: before each pair a 10-second CPU sample (above
// 10%, the pair waits and the sample repeats, for at most 3 hours); in each pair plugin/test/bench.mjs runs for the
// control, then the candidate; a pair is valid when every empty-Node p95 at 8 concurrent is at most 100 ms in both runs.
// Up to 6 pairs; 3 valid pairs give a result. Prints counts only.
//   node reference.mjs <repo> <control plugin dir> <candidate plugin dir> <out dir> [calls]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [repo, control, candidate, out, calls = '200'] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const busy = () => os.cpus().reduce((a, { times: t }) => ({ b: a.b + t.user + t.nice + t.sys + t.irq, t: a.t + t.user + t.nice + t.sys + t.irq + t.idle }), { b: 0, t: 0 });
const cpu = async () => { const a = busy(); await sleep(10_000); const b = busy(); return +(100 * (b.b - a.b) / (b.t - a.t)).toFixed(1); };
const bench = (plugin) => {
  const r = spawnSync('node', [path.join(plugin, 'test', 'bench.mjs'), repo, calls], { encoding: 'utf8', maxBuffer: 16 << 20 });
  return JSON.parse(r.stdout);
};
const at8 = (res) => Object.entries(res).filter(([k]) => k.endsWith('@8'));

fs.mkdirSync(out, { recursive: true });
const deadline = Date.now() + 3 * 3600_000;
const pairs = [];
let waited = 0;
while (pairs.filter((p) => p.valid).length < 3 && pairs.length < 6 && Date.now() < deadline) {
  const c = await cpu();
  if (c > 10) { waited++; if (waited % 10 === 1) console.log(`${new Date().toISOString()} cpu ${c}%: waiting`); await sleep(50_000); continue; }
  const n = pairs.length + 1;
  const ctl = bench(control);
  const cand = bench(candidate);
  fs.writeFileSync(path.join(out, `pair${n}-control.json`), JSON.stringify(ctl, null, 1));
  fs.writeFileSync(path.join(out, `pair${n}.json`), JSON.stringify(cand, null, 1));
  const valid = [...at8(ctl), ...at8(cand)].every(([, v]) => v.emptyP95 <= 100);
  pairs.push({ n, cpu: c, valid, control: Object.fromEntries(at8(ctl).map(([k, v]) => [k, [v.addedP95, v.errors]])),
    candidate: Object.fromEntries(at8(cand).map(([k, v]) => [k, [v.addedP95, v.errors]])) });
  console.log(JSON.stringify(pairs.at(-1)));
}
const valid = pairs.filter((p) => p.valid);
const result = valid.length < 3 ? 'no result' : valid.every((p) => Object.values(p.candidate).every(([a, e]) => a <= 100 && e === 0)) ? 'pass' : 'fail';
fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify({ result, waitedSamples: waited, pairs }, null, 1));
console.log(`result: ${result} (${valid.length} valid of ${pairs.length} pairs; ${waited} samples over 10%)`);
