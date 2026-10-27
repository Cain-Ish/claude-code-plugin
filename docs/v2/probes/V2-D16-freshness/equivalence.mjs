// V2-D16 reopened (2026-10-26), the equivalence half of attempt (a): the old labels() and index() (map-497ba915.mjs)
// against plugin/'s, byte for byte. The attempt ran with the new library in a plugin copy, moved into plugin/ after it
// passed. Takes worktrees of P1, P2 and R0 at their pinned commits and writes .project-map/ files in them. Prints and
// saves counts only.   node equivalence.mjs <p1> <p2> <r0>
// EQ_OLD, EQ_NEW (library paths) and EQ_OUT (a results name) compare another pair: D18's fixes, 06 2g attempt 3.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OLD = await import(pathToFileURL(path.resolve(process.env.EQ_OLD ?? path.join(HERE, 'map-497ba915.mjs'))).href);
const NEW = await import(pathToFileURL(path.resolve(process.env.EQ_NEW ?? path.join(HERE, '..', '..', '..', '..', 'plugin', 'scripts', 'map.mjs'))).href);
const BENCHMAP = path.join(HERE, '..', '..', '..', '..', 'plugin', 'test', 'benchmap.mjs');
const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const WORD = /[\p{L}\p{N}]+/gu;
let seed = 0x5eed2026;
const rand = () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t ^= t + Math.imul(t ^ (t >>> 7), 61 | t); return ((t ^ (t >>> 14)) >>> 0) / 2 ** 32; };
const pick = (a) => a[Math.floor(rand() * a.length)];
const entry = (i, quote, src) => `### q${i}\n> ${quote}\n\n- source: ${src}, 2026-10-20\n- when: ["x"]\n`;

const out = {};
const differ = [];
const same = (what, a, b) => { out.compared = (out.compared ?? 0) + 1; if (a !== b) differ.push(what); };
const mapDir = (repo) => path.join(repo, '.project-map');
const write = (repo, name, entries) => { fs.mkdirSync(path.dirname(path.join(mapDir(repo), name)), { recursive: true }); fs.writeFileSync(path.join(mapDir(repo), name), entries.join('\n')); };
const compareLabels = (label, repo, name) => {
  const a = OLD.labels(repo, `.project-map/${name}`);
  out.notFound = (out.notFound ?? 0) + (a.match(/not found word for word/g) ?? []).length;
  out.found = (out.found ?? 0) + a.split('\n').filter((l) => / unreviewed, not yet committed$/.test(l)).length;
  same(`${label} labels ${name}`, a, NEW.labels(repo, `.project-map/${name}`));
};

for (const [label, repo] of ['P1', 'P2', 'R0'].map((l, i) => [l, process.argv[2 + i]])) {
  const counts = { quotes: 0 };
  fs.rmSync(mapDir(repo), { recursive: true, force: true });
  same(`${label} index, no map`, OLD.index(repo), NEW.index(repo));

  // D16's load shape (benchmap.mjs), then seeded variants of each of its entries
  assert.equal(spawnSync('node', [BENCHMAP, repo], { encoding: 'utf8' }).status, 0);
  same(`${label} index, uncommitted map`, OLD.index(repo), NEW.index(repo));
  compareLabels(label, repo, 'captured.md');
  const bench = fs.readFileSync(path.join(mapDir(repo), 'captured.md'), 'utf8').split(/^(?=### )/m);
  const seeds = bench.flatMap((b, i) => {
    const q = /^> (.*)$/m.exec(b)[1].split(' ');
    const src = /^- source: (.*), 2026/m.exec(b)[1];
    const text = fs.readFileSync(path.join(repo, src), 'utf8').toLowerCase().match(WORD);
    return [
      [...q.slice(0, 3), 'zzqxw', ...q.slice(4)].join(' '),
      `${q.slice(0, 4).join(' ')} … ${q.slice(4).join(' ')}`,
      q.slice(0, 2).join(' '),
      text.slice(0, 8).join(' '),
      text.slice(-8).join(' '),
    ].map((s, k) => entry(i * 5 + k, s, src));
  });
  write(repo, 'seeds.md', seeds);
  compareLabels(label, repo, 'seeds.md');

  // edges: a quote whose first word is the tail of a longer word, and a document with astral letters, emoji, combining
  // marks, a dotted capital I, final sigma, a ligature, digits and underscores
  const tails = bench.map((b, i) => {
    const src = /^- source: (.*), 2026/m.exec(b)[1];
    const ws = fs.readFileSync(path.join(repo, src), 'utf8').toLowerCase().match(WORD);
    const at = ws.findIndex((w, k) => w.length >= 5 && k + 3 < ws.length);
    return entry(i, [ws[at].slice(2), ...ws.slice(at + 1, at + 3)].join(' '), src);
  });
  write(repo, 'tails.md', tails);
  compareLabels(label, repo, 'tails.md');
  const EDGE = 'eq-edge.md';
  fs.writeFileSync(path.join(repo, EDGE), '𝐀the cat sat here.\n😀the dog ran far\nİstanbul is big today\nΟΔΟΣ ends here now\n'
    + 'ﬁne print says so\ncafé́ au lait now\nv1.2.3 ships on time\nsnake_case word list\n𠀀the end comes soon\n');
  write(repo, 'edge.md', ['the cat sat', 'the dog ran', 'i̇stanbul is big', 'stanbul is big', 'οδος ends here', 'οδοσ ends here',
    'ﬁne print says', 'fine print says', 'café au lait', 'caf au lait', '1 2 3 ships', 'v1 2 3', 'case word list',
    'snake case word', 'the end comes', 'cat sat here'].map((q, i) => entry(i, q, EDGE)));
  compareLabels(label, repo, 'edge.md');
  fs.rmSync(path.join(repo, EDGE));

  // a nested file and a non-document under the map folder
  write(repo, 'sub/nested.md', [entry(0, 'nested', 'README.md')]);
  fs.writeFileSync(path.join(mapDir(repo), 'notes.txt'), 'x\n');
  fs.writeFileSync(path.join(mapDir(repo), 'skip.json'), '{}\n');
  same(`${label} index, nested map files`, OLD.index(repo), NEW.index(repo));

  // the random differential: runs of 3 to 12 words, as words or as the file's own text; half with one word replaced;
  // some joined by an ellipsis
  const docs = spawnSync('git', ['ls-files', '-z'], { cwd: repo, encoding: 'utf8', maxBuffer: 64 << 20 }).stdout.split('\0')
    .filter((f) => DOC.test(f) && /^[\w./-]+$/.test(f)).map((f) => ({ f, text: fs.readFileSync(path.join(repo, f), 'utf8') }))
    .map((d) => ({ ...d, spans: [...d.text.matchAll(WORD)].map((m) => [m.index, m.index + m[0].length]) })).filter((d) => d.spans.length >= 12);
  const run = (d) => {
    const n = 3 + Math.floor(rand() * 10), at = Math.floor(rand() * (d.spans.length - n));
    const ws = d.spans.slice(at, at + n);
    if (rand() < 0.5) return ws.map(([a, b]) => d.text.slice(a, b).toLowerCase());
    return [d.text.slice(ws[0][0], ws[n - 1][1]).replace(/\s+/g, ' ')];
  };
  for (let f = 0; f < 34; f++) {
    const es = [];
    for (let i = 0; i < 200; i++) {
      const d = pick(docs);
      let parts = run(d);
      if (rand() < 0.5) { const ws = parts.join(' ').split(' '); ws[Math.floor(rand() * ws.length)] = pick(['zzqxw', pick(pick(docs).text.toLowerCase().match(WORD))]); parts = [ws.join(' ')]; }
      if (rand() < 0.2) parts = [parts.join(' '), '…', run(d).join(' ')];
      es.push(entry(i, parts.join(' '), d.f));
      counts.quotes++;
    }
    write(repo, `random-${f}.md`, es);
    compareLabels(label, repo, `random-${f}.md`);
  }
  fs.rmSync(mapDir(repo), { recursive: true, force: true });
  out[label] = counts;
}

out.differences = differ.length;
out.differing = differ.slice(0, 10);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `${process.env.EQ_OUT ?? 'equivalence'}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
