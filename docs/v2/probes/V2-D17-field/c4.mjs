// C4 (README.md): node c4.mjs <units.json> <judged.json> <repo root>
// Documents of each yes directory read before the epoch's first change. judged.json (raw/, gitignored) holds the
// reader's judgments of each forced answer (C3), keyed by epoch time: { claim: bool, yes: [directory, ...] }.
import fs from 'node:fs';
import path from 'node:path';

const [units, judged, root] = process.argv.slice(2);
if (!root) throw new Error('usage: node c4.mjs <units.json> <judged.json> <repo root>');
const ROOT = path.resolve(root).replace(/\\/g, '/').toLowerCase() + '/';
const YES = JSON.parse(fs.readFileSync(judged, 'utf8'));
const W = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
const abs = (p) => path.resolve(ROOT, String(p ?? '')).replace(/\\/g, '/');
const inRepo = (p) => abs(p).toLowerCase().startsWith(ROOT);
const rel = (p) => abs(p).slice(ROOT.length);

for (const s of JSON.parse(fs.readFileSync(units, 'utf8'))) for (const e of s.epochs) {
  const j = YES[e.at];
  if (!j) continue;
  const t = e.turns.find((x) => x.forced);
  const firstAny = t.tools.findIndex((x) => W.has(x.name));
  const firstRepo = t.tools.findIndex((x) => W.has(x.name) && inRepo(x.file));
  const row = { at: e.at, claim: j.claim, firstAny, firstRepo };
  for (const [label, cut, broad] of [['primary', firstRepo, false], ['any-write', firstAny, false], ['broad', firstRepo, true]]) {
    if (cut < 0) { row[label] = 'no change in turn'; continue; }
    const before = t.tools.slice(0, cut);
    // primary: the Read tool; broad adds Bash text naming the document, a Grep scoped to it, and a rule file loaded natively
    const touched = (doc) => before.some((x) => ((x.name === 'Read' || (broad && x.name === 'NestedMemory')) && inRepo(x.file) && rel(x.file) === doc)
      || (broad && ((x.name === 'Bash' && (x.input?.command ?? '').includes(doc)) || (x.name === 'Grep' && x.input?.path && rel(x.input.path) === doc))));
    const per = j.yes.map((d) => {
      const docs = (e.index.find((x) => x.dir === d)?.docs ?? []).map((f) => (d === '.' ? f : `${d}/${f}`));
      const read = docs.filter(touched);
      // broad: the root CLAUDE.md is loaded natively at every epoch start
      if (broad && d === '.' && docs.includes('CLAUDE.md') && !read.includes('CLAUDE.md')) read.push('CLAUDE.md');
      return { d, n: docs.length, read: read.length };
    });
    row[label] = { lenient: per.every((p) => p.read > 0), strict: per.every((p) => p.read === p.n), yesDirs: per.length, dirsRead: per.filter((p) => p.read).length, docsYes: per.reduce((n, p) => n + p.n, 0), docsRead: per.reduce((n, p) => n + p.read, 0) };
  }
  console.log(JSON.stringify(row));
}
