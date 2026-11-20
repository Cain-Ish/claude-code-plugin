// 06, section 3, S4: the topic-file bar, read from A1's V2 run folders after the eval scored them.
//   node s4topic.mjs <eval scratch dir>
// Per run (V2-run<i>/repo-H/.project-map): whether a topic file was written (a .md file other than captured.md whose
// front matter has name and description), and how many entries carry an id line and a verified line. No text kept.
import fs from 'node:fs';
import path from 'node:path';

const scratch = path.resolve(process.argv[2]);
const blocks = (t) => t.replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b));
const rows = [];
for (const d of fs.readdirSync(scratch).filter((x) => /^V2-run\d+$/.test(x)).sort((a, b) => parseInt(a.slice(6), 10) - parseInt(b.slice(6), 10))) {
  const map = path.join(scratch, d, 'repo-H', '.project-map');
  const files = fs.existsSync(map) ? fs.readdirSync(map).filter((f) => f.endsWith('.md')) : [];
  let topic = false, entries = 0, withId = 0, withVerified = 0;
  for (const f of files) {
    const t = fs.readFileSync(path.join(map, f), 'utf8').replace(/\r/g, '');
    const fm = /^---\n([\s\S]*?)\n---\n/.exec(t);
    if (f !== 'captured.md' && fm && /^name:\s*\S/m.test(fm[1]) && /^description:\s*\S/m.test(fm[1])) topic = true;
    for (const b of blocks(t)) { entries++; if (/^- id:\s*\S/m.test(b)) withId++; if (/^- verified:\s*\d{4}-\d{2}-\d{2}/m.test(b)) withVerified++; }
  }
  rows.push({ run: Number(d.slice(6)), files: files.length, topic, entries, withId, withVerified, capturedMd: files.includes('captured.md') });
}
const out = { runs: rows.length, topicRuns: rows.filter((r) => r.topic).length, idAndVerifiedRuns: rows.filter((r) => r.entries > 0 && r.withId === r.entries && r.withVerified === r.entries).length, rows };
console.log(JSON.stringify(out, null, 1));
