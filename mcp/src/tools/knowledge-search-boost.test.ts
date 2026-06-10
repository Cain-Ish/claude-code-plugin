import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeSearch } from './knowledge-search.js';

// R2.1 (MCP-SEARCH-1): graph boosts must be computed from FROZEN pre-boost base
// scores and capped at <=1x each page's own base. The old in-place mutation
// compounded geometrically through hub pages (~10,000x observed live), and the
// relative floor then evicted exact-title matches.
describe('hub-proof graph boost', () => {
  let kd: string;
  const page = (cat: string, slug: string, title: string, body: string) =>
    writeFileSync(join(kd, 'wiki', cat, `${slug}.md`),
      `---\ntitle: "${title}"\ndescription: "${title}"\ntype: ${cat}\n---\n\n# ${title}\n\n${body}\n`);

  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    kd = mkdtempSync(join(tmpdir(), 'sb-boost-'));
    mkdirSync(join(kd, 'wiki', 'concepts'), { recursive: true });
    mkdirSync(join(kd, 'graph'), { recursive: true });
    // Target: exact-title match for the query.
    page('concepts', 'wg-watchdog', 'wireguard tunnel watchdog restart',
      'The watchdog restarts the wireguard tunnel when the handshake goes stale. '.repeat(4));
    // Hub: weak text match, but connected to EVERY filler page.
    page('concepts', 'big-hub', 'architecture overview',
      'General overview page; mentions the tunnel once. '.repeat(4));
    // Zero-base page: no query tokens at all, linked to the hub.
    page('concepts', 'zero-base', 'unrelated gardening notes',
      'Tomatoes and compost only, nothing else. '.repeat(4));
    // 20 fillers each weakly matching one query token and linked to the hub.
    const edges: string[] = [];
    for (let i = 0; i < 20; i++) {
      page('concepts', `filler-${i}`, `note ${i}`,
        `This note mentions the tunnel briefly. Padding text for length here. `.repeat(3));
      edges.push(JSON.stringify({ op: 'assert', from: `filler-${i}`, to: 'big-hub', type: 'relates', valid_from: '2026-01-01', valid_to: null, recorded_at: '2026-01-01T00:00:00Z', source: 'test' }));
    }
    edges.push(JSON.stringify({ op: 'assert', from: 'big-hub', to: 'zero-base', type: 'relates', valid_from: '2026-01-01', valid_to: null, recorded_at: '2026-01-01T00:00:00Z', source: 'test' }));
    writeFileSync(join(kd, 'graph', 'edges.jsonl'), edges.join('\n') + '\n');
  });
  afterAll(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    rmSync(kd, { recursive: true, force: true });
  });

  it('exact-title page outranks the dense hub', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.length).toBeGreaterThan(0);
    expect(r.candidates[0].path).toContain('wg-watchdog');
  });

  it('exact-title page is not floor-evicted from the top-8', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.some(c => c.path.includes('wg-watchdog'))).toBe(true);
  });

  it('a zero-base page cannot ride the graph into the results', async () => {
    const r = await knowledgeSearch({ query: 'wireguard tunnel watchdog restart', knowledgeDir: kd });
    expect(r.candidates.some(c => c.path.includes('zero-base'))).toBe(false);
  });
});

// Invariant: total received boost is capped at <=1x a page's own base score, so
// with-graph score <= 2x without-graph score for the SAME corpus and query.
// The pre-R2.1 in-place accumulation violates this through any dense hub.
describe('boost cap invariant (<=2x base)', () => {
  let kdGraph: string; let kdPlain: string;
  const mk = (root: string, withEdges: boolean) => {
    mkdirSync(join(root, 'wiki', 'concepts'), { recursive: true });
    const page = (slug: string, title: string, body: string) =>
      writeFileSync(join(root, 'wiki', 'concepts', `${slug}.md`),
        `---\ntitle: "${title}"\ndescription: "${title}"\ntype: concepts\n---\n\n# ${title}\n\n${body}\n`);
    // Hub matches 'watchdog' weakly; sorts AFTER the fillers so the old code
    // propagates its already-inflated score onward (worst-case ordering).
    // Strong enough to pass the relevance floor in BOTH runs (measurable base),
    // weak enough that the old code's 20 filler contributions blow past 2x.
    page('zz-hub', 'general overview', 'Overview of the watchdog and the watchdog restart path. ' + 'Pure padding sentence here. '.repeat(4));
    const edges: string[] = [];
    for (let i = 0; i < 20; i++) {
      const tok = i % 2 === 0 ? 'watchdog' : 'restart';
      page(`filler-${String(i).padStart(2, '0')}`, `note ${i}`, `Short note about the ${tok} behavior.`);
      edges.push(JSON.stringify({ op: 'assert', from: `filler-${String(i).padStart(2, '0')}`, to: 'zz-hub', type: 'relates', valid_from: '2026-01-01', valid_to: null, recorded_at: '2026-01-01T00:00:00Z', source: 'test' }));
    }
    if (withEdges) {
      mkdirSync(join(root, 'graph'), { recursive: true });
      writeFileSync(join(root, 'graph', 'edges.jsonl'), edges.join('\n') + '\n');
    }
  };
  beforeAll(() => {
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
    kdGraph = mkdtempSync(join(tmpdir(), 'sb-cap-g-'));
    kdPlain = mkdtempSync(join(tmpdir(), 'sb-cap-p-'));
    mk(kdGraph, true); mk(kdPlain, false);
  });
  afterAll(() => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    rmSync(kdGraph, { recursive: true, force: true });
    rmSync(kdPlain, { recursive: true, force: true });
  });

  it('hub score with graph <= 2x its no-graph base', async () => {
    const q = 'watchdog restart';
    const hub = (r: Awaited<ReturnType<typeof knowledgeSearch>>) =>
      r.candidates.find(c => c.path.includes('zz-hub'))?.score ?? 0;
    const withG = hub(await knowledgeSearch({ query: q, knowledgeDir: kdGraph }));
    const withoutG = hub(await knowledgeSearch({ query: q, knowledgeDir: kdPlain }));
    expect(withoutG).toBeGreaterThan(0); // hub must be measurable in both runs
    expect(withG).toBeLessThanOrEqual(withoutG * 2.01);
  });
});
