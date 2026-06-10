import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeSearch } from './knowledge-search.js';
import { episodicSearch } from './episodic-search.js';

// R2.3 (MCP-SEARCH-2): output must be interpretable — additive score_norm on
// one 0..1 scale, and an explicit degraded flag when vector search is dead.
// Raw `score` stays untouched (KNOWLEDGE_MIN_SCORE callers filter on it).
describe('search output contract', () => {
  let kd: string; let brain: string;
  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    process.env.BRAIN_DIR = mkdtempSync(join(tmpdir(), 'sb-contract-ac-')); // hermetic access-counts
    kd = mkdtempSync(join(tmpdir(), 'sb-contract-'));
    mkdirSync(join(kd, 'wiki', 'concepts'), { recursive: true });
    writeFileSync(join(kd, 'wiki', 'concepts', 'alpha.md'),
      '---\ntitle: "alpha tunnel page"\ndescription: "about tunnels"\ntype: concepts\n---\n\n# alpha tunnel page\n\ntunnel content here for matching\n');
    writeFileSync(join(kd, 'wiki', 'concepts', 'omega.md'),
      '---\ntitle: "omega side note"\ndescription: "mentions tunnel weakly"\ntype: concepts\n---\n\n# omega side note\n\nmostly other prose with one tunnel word\n');
    brain = mkdtempSync(join(tmpdir(), 'sb-contract-brain-'));
    writeFileSync(join(brain, 'episodic-index.json'), JSON.stringify({
      version: 1,
      exchanges: [{
        id: 'x1', sessionId: 's', project: 'p', date: '2026-06-01',
        userSnippet: 'how do tunnels work', assistantSnippet: 'tunnels work via wireguard',
        embedding: [], archivePath: join(brain, 'transcripts', 'a.txt'), lineStart: 1, lineEnd: 2,
      }],
    }));
  });
  afterAll(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    rmSync(kd, { recursive: true, force: true }); rmSync(brain, { recursive: true, force: true });
  });

  it('knowledge_search: score_norm in (0,1], top hit = 1, degraded flagged without embeddings', async () => {
    const r = await knowledgeSearch({ query: 'alpha tunnel', knowledgeDir: kd });
    expect(r.degraded).toBe('bm25-only');
    expect(r.candidates[0].score_norm).toBe(1);
    for (const c of r.candidates) {
      expect(c.score_norm).toBeGreaterThan(0);
      expect(c.score_norm).toBeLessThanOrEqual(1);
      expect(typeof c.score).toBe('number'); // raw score still present, unchanged semantics
    }
  });

  it('knowledge_search: tier present only when project scoping is active', async () => {
    const global = await knowledgeSearch({ query: 'alpha tunnel', knowledgeDir: kd });
    expect(global.candidates[0].tier).toBeUndefined();
  });

  it('episodic_search: vector-requested search with no embeddings reports degraded text-only', async () => {
    const r = await episodicSearch({ query: 'tunnels' }, brain); // mode defaults to 'both'
    expect(r.degraded).toBe('text-only');
    expect(r.results.length).toBeGreaterThan(0); // text fallback still works
  });

  it('episodic_search: explicit text mode is not "degraded"', async () => {
    const r = await episodicSearch({ query: 'tunnels', mode: 'text' }, brain);
    expect(r.degraded).toBeUndefined();
  });
});
