import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeSearch } from './knowledge-search.js';
import { episodicSearch, renderEpisodicSearch } from './episodic-search.js';

// R2.3 (MCP-SEARCH-2): output must be interpretable — additive score_norm on
// one 0..1 scale, and an explicit degraded flag when vector search is dead.
// Raw `score` stays untouched (KNOWLEDGE_MIN_SCORE callers filter on it).
describe('search output contract', () => {
  let kd: string; let brain: string;
  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    delete process.env.SB_BRAIN_DIR; process.env.BRAIN_DIR = mkdtempSync(join(tmpdir(), 'sb-contract-ac-')); // hermetic access-counts
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

  // D3 (2026-10-07): the engine flag above never reached the model — the MCP tool printed rows (or
  // "No matching conversations found.") and dropped result.degraded, although its description
  // promised it. These assert the TOOL TEXT (renderEpisodicSearch, which server.ts returns as is;
  // server-tools-contract.test.ts locks that delegation).
  const BUDGET = 2000;

  it('episodic_search text: a concept array with no vectors says vector search is unavailable and how to retry', async () => {
    const r = await episodicSearch({ query: ['tunnels', 'wireguard'] }, brain);
    expect(r.degraded).toBe('vector-unavailable');
    const text = renderEpisodicSearch(r, BUDGET);
    expect(text).not.toBe('No matching conversations found.');
    expect(text).toMatch(/vector search unavailable \(embeddings missing\)/);
    expect(text).toMatch(/retry as a single string query/);
  });

  it('episodic_search text: text-only rows carry a degraded footer after the rows', async () => {
    const r = await episodicSearch({ query: 'tunnels' }, brain);
    expect(r.degraded).toBe('text-only');
    const text = renderEpisodicSearch(r, BUDGET);
    expect(text).toContain('**User**: how do tunnels work');
    expect(text.trimEnd().split('\n').pop()).toMatch(/^_Degraded: vector search unavailable \(embeddings missing\)/);
  });

  it('episodic_search text: text-only with no match says the miss is text-only, not a plain "not found"', async () => {
    const r = await episodicSearch({ query: 'zzqx nonexistent' }, brain);
    expect(r.results).toEqual([]);
    expect(r.degraded).toBe('text-only');
    const text = renderEpisodicSearch(r, BUDGET);
    expect(text).toMatch(/^No matching conversations found/);
    expect(text).toMatch(/text matching only/);
    expect(text).toMatch(/vector search unavailable \(embeddings missing\)/);
  });

  it('episodic_search text: no degraded flag -> no footer, and the plain not-found line', async () => {
    const hit = await episodicSearch({ query: 'tunnels', mode: 'text' }, brain);
    expect(renderEpisodicSearch(hit, BUDGET)).not.toMatch(/Degraded|vector search unavailable/);
    const miss = await episodicSearch({ query: 'zzqx nonexistent', mode: 'text' }, brain);
    expect(renderEpisodicSearch(miss, BUDGET)).toBe('No matching conversations found.');
  });

  it('episodic_search text: the footer survives the egress cap (appended after capList)', async () => {
    const r = await episodicSearch({ query: 'tunnels' }, brain);
    const two = { ...r, results: [r.results[0], { ...r.results[0], sessionId: 's2' }] };
    const text = renderEpisodicSearch(two, 1);   // 1 token: capList keeps only the top row
    expect(text).toContain('1 more —');
    expect(text.trimEnd().split('\n').pop()).toMatch(/^_Degraded: vector search unavailable/);
  });
});
