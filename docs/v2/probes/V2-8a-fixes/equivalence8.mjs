// 06, section 8, 8a (the D16 note): the re-find with H5's linear fallback answers as 2.5.1's scan does. Three builds of
// foundIn see the same quotes: 2.5.1 (the scan alone), the candidate, and the candidate with its scan budget at 0 (the
// linear search alone). Documents: this repo's docs/v2 Markdown, plus two of one repeated word. Quotes, seeded:
// stretches taken from a document, the same with one word changed or one dropped, two stretches joined with an
// ellipsis, and long runs of the repeated word. Prints and saves counts only.
//   node equivalence8.mjs <2.5.1 plugin> <candidate plugin>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [oldPlugin, newPlugin] = process.argv.slice(2).map((p) => path.resolve(p));
const load = (p) => import(pathToFileURL(p).href);
const OLD = await load(path.join(oldPlugin, 'scripts', 'map.mjs'));
const NEW = await load(path.join(newPlugin, 'scripts', 'map.mjs'));
const zeroDir = fs.mkdtempSync(path.join(os.tmpdir(), 'eq8-'));
const src = fs.readFileSync(path.join(newPlugin, 'scripts', 'map.mjs'), 'utf8');
if (!src.includes('const SCAN_BUDGET = 200_000;')) throw new Error('no scan budget in the candidate');
fs.writeFileSync(path.join(zeroDir, 'map.mjs'), src.replace('const SCAN_BUDGET = 200_000;', 'const SCAN_BUDGET = 0;'));
const ZERO = await load(path.join(zeroDir, 'map.mjs'));

let seed = 0x8a2026;
const rand = () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t ^= t + Math.imul(t ^ (t >>> 7), 61 | t); return ((t ^ (t >>> 14)) >>> 0) / 2 ** 32; };
const int = (n) => Math.floor(rand() * n);
const WORD = /[\p{L}\p{N}]+/gu;
const docsDir = path.join(HERE, '..', '..');
const docs = [];
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) { if (!['raw', 'results', 'fixture', 'gold', 'old'].includes(e.name)) walk(p); } else if (e.name.endsWith('.md')) docs.push(fs.readFileSync(p, 'utf8').toLowerCase()); } };
walk(docsDir);
docs.push(`${'a '.repeat(60_000)}b c ${'a '.repeat(500)}`, `${'the '.repeat(40_000)}end of the line`);

const out = { documents: docs.length, quotes: 0, found: 0, differences: { candidate: 0, linearOnly: 0 }, kinds: {} };
for (const low of docs) {
  const w = low.match(WORD) ?? [];
  if (w.length < 50) continue;
  const stretch = () => { const k = 3 + int(30), i = int(w.length - k); return w.slice(i, i + k); };
  const repeated = w.filter((x) => x === w[0]).length > w.length / 2;
  for (let n = 0; n < (repeated ? 12 : 60); n++) {
    const kind = repeated ? ['run', 'run-miss'][n % 2] : ['found', 'changed', 'dropped', 'ellipsis'][n % 4];
    let q;
    if (kind === 'run') q = `${`${w[0]} `.repeat(200 + int(300))}${w.at(-3)}`;
    else if (kind === 'run-miss') q = `${`${w[0]} `.repeat(200 + int(300))}zzz`;
    else {
      const s = stretch();
      if (kind === 'changed') s[int(s.length)] = w[int(w.length)];
      if (kind === 'dropped' && s.length > 3) s.splice(1 + int(s.length - 2), 1);
      q = kind === 'ellipsis' ? `${s.join(' ')} … ${stretch().join(' ')}` : s.join(' ');
    }
    const a = OLD.foundIn(q, low), b = NEW.foundIn(q, low), c = ZERO.foundIn(q, low);
    out.quotes++;
    out.found += a ? 1 : 0;
    out.kinds[kind] = (out.kinds[kind] ?? 0) + 1;
    if (a !== b) out.differences.candidate++;
    if (a !== c) out.differences.linearOnly++;
  }
}
fs.rmSync(zeroDir, { recursive: true, force: true });
out.pass = out.differences.candidate === 0 && out.differences.linearOnly === 0;
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'equivalence8.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
