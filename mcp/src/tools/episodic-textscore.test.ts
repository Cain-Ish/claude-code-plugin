import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { episodicSearch } from './episodic-search.js';

// P8 (deep-review): episodic text-mode similarity was a CONSTANT 0.5 — the
// AND-loop broke on the first miss, so the push condition forced
// hits/tokens.length === 1 every time, and the list was sliced UNSORTED. A
// ranking test that only checked ordering would pass while ranking was dead.
// ORACLE: the actual .similarity VALUES must DIFFER by overlap density, and a
// denser-overlap exchange must rank first — not a re-read of the impl's claim.

async function brainWith(exchanges: Record<string, unknown>[]): Promise<string> {
  const brain = await fs.mkdtemp(join(tmpdir(), 'epi-ts-'));
  const base = { sessionId: 's', project: 'p', date: '2026-06-01', archivePath: '/x', lineStart: 0, lineEnd: 1, embedding: [] };
  await fs.writeFile(join(brain, 'episodic-index.json'), JSON.stringify({
    model: 'none', indexed_files: {},
    exchanges: exchanges.map((e, i) => ({ id: `e${i}`, ...base, ...e })),
  }));
  return brain;
}

describe('episodic textSearch ranking (P8 — must not collapse to a constant)', () => {
  it('a denser-overlap exchange scores STRICTLY higher and ranks first', async () => {
    // both contain all query tokens (AND-gate passes for both); 'dense' repeats them.
    const brain = await brainWith([
      { userSnippet: 'router daemon config', assistantSnippet: 'one mention each' },                         // weak
      { userSnippet: 'router router daemon daemon', assistantSnippet: 'router daemon router daemon again' }, // dense
    ]);
    const r = await episodicSearch({ query: 'router daemon', limit: 5, mode: 'text' }, brain);
    expect(r.results.length).toBe(2);
    const dense = r.results.find(x => x.userSnippet.startsWith('router router'))!;
    const weak = r.results.find(x => x.userSnippet === 'router daemon config')!;
    expect(dense.similarity).toBeGreaterThan(weak.similarity);   // discriminates by density
    expect(r.results[0].similarity).toBeGreaterThanOrEqual(r.results[1].similarity); // sorted
    expect(r.results[0].userSnippet.startsWith('router router')).toBe(true);          // dense ranks first
  });

  it('all text scores stay in (0, 0.5] so a vector match (up to 1.0) still outranks', async () => {
    const brain = await brainWith([{ userSnippet: 'router daemon router daemon', assistantSnippet: 'router daemon' }]);
    const r = await episodicSearch({ query: 'router daemon', limit: 5, mode: 'text' }, brain);
    expect(r.results[0].similarity).toBeGreaterThan(0);
    expect(r.results[0].similarity).toBeLessThanOrEqual(0.5);
  });

  it('still AND-gates: an exchange missing a query token is excluded', async () => {
    const brain = await brainWith([
      { userSnippet: 'router only here', assistantSnippet: 'no second token' },   // missing 'daemon'
      { userSnippet: 'router and daemon', assistantSnippet: 'both' },
    ]);
    const r = await episodicSearch({ query: 'router daemon', limit: 5, mode: 'text' }, brain);
    expect(r.results.length).toBe(1);
    expect(r.results[0].userSnippet).toBe('router and daemon');
  });
});
