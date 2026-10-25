// V2-D16 reopened (2026-10-25), option (b)'s check: the plugin's own read labels on copies of D14's M2 repos, the
// untouched tree and three seeds per entry found today. Counts only, to results/readfind.json.
//   node readfind.mjs <folder holding M2-run1..M2-run10>
// The load half of the check is plugin/test/bench.mjs on P2 with a 30-entry map file (see DECISIONS.md, V2-D16).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { labels } from '../../../../plugin/scripts/map.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MAPFILE = '.project-map/captured.md';
const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const blocks = (t) => t.replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b));
// the D16 part of an entry's label line: none, notFound or unverified
const kindOf = (out, i) => {
  const line = out.split('\n').find((l) => l.startsWith(`${i + 1}. `)) ?? '';
  return line.includes('not found word for word in') ? 'notFound' : line.includes('unverified quote') ? 'unverified' : 'none';
};
// where the quote's first stretch of three or more words sits in the file, as D16's attempt 2 matched it
function firstStretch(quote, text) {
  const w = quote.split(/…|\.\.\./).map(words).find((x) => x.length >= 3);
  const re = new RegExp(w.map((x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^\\p{L}\\p{N}]+'), 'iu');
  return re.exec(text);
}

const base = process.argv[2];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'd16-readfind-'));
const copy = (run, name) => { const d = path.join(tmp, `${run}-${name}`); fs.cpSync(path.join(base, run, 'repo-H'), d, { recursive: true }); return d; };
const res = { untouched: { none: 0, notFound: 0, unverified: 0 }, seeds: { edit: 0, delete: 0, rename: 0, of: 0 }, labelsSayingChanged: 0 };
const seen = [];

for (const run of fs.readdirSync(base).filter((d) => /^M2-run\d+$/.test(d)).sort()) {
  const clean = copy(run, 'clean');
  const out = labels(clean, MAPFILE);
  seen.push(out);
  const bs = blocks(fs.readFileSync(path.join(clean, MAPFILE), 'utf8'));
  bs.forEach((b, i) => {
    const k = kindOf(out, i);
    res.untouched[k]++;
    if (k !== 'none') return;
    // a found entry: three seeds in its source file, one at a time, each on a fresh copy
    const quote = b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n');
    const src = /^- source:(.*)$/m.exec(b)[1];
    const at = src.match(/[\w.-]+(?:\/[\w.-]+)*\.\w+/g).map((p) => p.replace(/^\.\//, '')).find((p) => fs.existsSync(path.join(clean, p)));
    res.seeds.of++;
    for (const seed of ['edit', 'delete', 'rename']) {
      const d = copy(run, `${i}-${seed}`);
      const f = path.join(d, at);
      const text = fs.readFileSync(f, 'utf8');
      const m = firstStretch(quote, text);
      if (seed === 'rename') fs.renameSync(f, `${f}.renamed`);
      else {
        const span = m[0];
        const mid = span.split(/([^\p{L}\p{N}]+)/u);
        mid[2] = 'zzzz'; // the second word of the stretch
        fs.writeFileSync(f, text.slice(0, m.index) + (seed === 'edit' ? mid.join('') : '') + text.slice(m.index + span.length));
      }
      const o = labels(d, MAPFILE);
      seen.push(o);
      if (kindOf(o, i) === 'notFound') res.seeds[seed]++;
    }
  });
}
res.labelsSayingChanged = seen.filter((o) => /changed/i.test(o)).length;
res.pass = res.untouched.none === 4 && res.untouched.notFound === 5 && res.untouched.unverified === 79
  && res.seeds.of === 4 && res.seeds.edit + res.seeds.delete + res.seeds.rename === 12 && res.labelsSayingChanged === 0;
fs.rmSync(tmp, { recursive: true, force: true });
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'readfind.json'), `${JSON.stringify(res, null, 1)}\n`);
console.log(JSON.stringify(res));
