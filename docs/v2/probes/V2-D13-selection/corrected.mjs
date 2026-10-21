// V2-D13: the held rule corrected after attempt 2 (disclosed next to the registered scores, which stand). A card is
// holdable when the whole corpus covers >= 0.5 of its trigrams, and held when the delivered blocks cover >= 0.8 x
// that. Recomputes attempts 1 and 2 at each cap, and attempt 2's ceiling (every block the converter cited).
//   node corrected.mjs <config> <cards>     writes results/held-corrected.json (counts only)
import fs from 'node:fs';
import path from 'node:path';
import { index, rank, deliver, cardGrams, entryGrams, cover } from './select.mjs';
const [cfgArg, cardsArg] = process.argv.slice(2);
const RAW = path.dirname(path.resolve(cfgArg));
const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
const cards = JSON.parse(fs.readFileSync(cardsArg, 'utf8'));
const CAPS = [2, 4, 8, 16, 32];
const out = {};
for (const t of cfg.tasks) {
  const label = t.id.split('-')[0];
  const map = JSON.parse(fs.readFileSync(`${RAW}/d13/maps/${label}.json`, 'utf8')).all;
  const sets = map.map(entryGrams);
  const want = Object.values(cards[t.id]).map((c) => cardGrams(c.text));
  const corpus = want.map((g) => cover(g, sets));
  const held = (got) => want.filter((g, k) => corpus[k] >= 0.5 && cover(g, got) >= 0.8 * corpus[k]).length;
  const a1 = CAPS.map((cap) => held(deliver(map, rank(index(map), t.prompt), cap).out.map((i) => sets[i])));
  const dir = `${RAW}/d13/entries/${label}`;
  const compact = fs.readdirSync(dir).flatMap((f) => { const r = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); return r.entries.map((x) => ({ ...x, file: r.file, heads: map[x.blocks[0]].heads })); });
  const shownEs = compact.map((c) => ({ file: c.file, heads: c.heads, text: c.quote }));
  const ranked = rank(index(compact.map((c) => ({ file: c.file, heads: c.heads, text: `${c.area} ${c.when.join(' ')} ${c.quote}` }))), t.prompt);
  const a2 = CAPS.map((cap) => held(deliver(shownEs, ranked, cap).out.flatMap((i) => compact[i].blocks.map((b) => sets[b]))));
  const ceiling = held([...new Set(compact.flatMap((c) => c.blocks))].map((b) => sets[b]));
  out[t.id] = { rules: want.length, holdable: corpus.filter((c) => c >= 0.5).length, attempt1: a1, attempt2: a2, attempt2Ceiling: ceiling };
  if (label === 'R0') {
    const d = deliver(shownEs, ranked, 8).out;
    fs.writeFileSync(path.join(RAW, 'd13', 'r0-delivered-8kb.json'), JSON.stringify(d.map((i) => ({ area: compact[i].area, file: compact[i].file, quote: compact[i].quote })), null, 1));
  }
}
fs.writeFileSync(new URL('./results/held-corrected.json', import.meta.url), `${JSON.stringify(out, null, 1)}
`);
for (const [k, v] of Object.entries(out)) console.log(k, JSON.stringify(v));
