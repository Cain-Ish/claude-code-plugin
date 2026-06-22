import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeNeighbors } from './knowledge-neighbors.js';
import { appendEdge } from './graph-store.js';

describe('knowledgeNeighbors', () => {
  it('returns current dependencies of a slug', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeNeighbors({ slug: 'a', direction: 'out', knowledgeDir: dir });
    expect(r.edges.map(e => e.to)).toContain('b');
  });
  it('returns [] when the graph log is absent (no-op)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn0-'));
    const r = await knowledgeNeighbors({ slug: 'a', knowledgeDir: dir });
    expect(r.edges).toEqual([]);
  });
  it('rejects an invalid slug by returning empty edges', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn1-'));
    const r = await knowledgeNeighbors({ slug: '../escape', knowledgeDir: dir });
    expect(r.edges).toEqual([]);
  });

  // MCP arg-plumbing proof: these go THROUGH knowledgeNeighbors (the MCP wrapper),
  // not the underlying graph-store, so they prove the wrapper forwards as_of /
  // depth / direction (knowledge-neighbors.ts:19-22) instead of dropping them and
  // silently using the defaults (now / depth 2 / 'both').
  it('forwards as_of: a date BEFORE invalidation still returns the now-retired edge', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-asof-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'invalidate', from: 'a', to: 'b', type: 'requires', valid_to: '2026-05-20', recorded_at: '2026-05-20T00:00:00Z' });

    // as_of inside the [valid_from, valid_to) window → the retired edge is visible.
    const past = await knowledgeNeighbors({ slug: 'a', direction: 'out', as_of: '2026-05-10', knowledgeDir: dir });
    expect(past.edges.map(e => e.to)).toContain('b');

    // as_of after invalidation → gone. (Pins the discriminator to as_of: a wrapper
    // that dropped as_of would default to `now`, which is also after 2026-05-20,
    // making the past-query ALSO return [] — so the contrast is what proves
    // forwarding, not just one branch.)
    const present = await knowledgeNeighbors({ slug: 'a', direction: 'out', as_of: '2026-05-25', knowledgeDir: dir });
    expect(present.edges.map(e => e.to)).not.toContain('b');
  });

  it('forwards depth + direction: depth:2 direction:in reaches the 2-hop INBOUND neighbour', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-depth-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    // chain  x --requires--> y --requires--> z
    await appendEdge(log, { op: 'assert', from: 'x', to: 'y', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'y', to: 'z', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });

    // From z, INBOUND, depth 2: y is 1 hop in, x is 2 hops in.
    const r = await knowledgeNeighbors({ slug: 'z', direction: 'in', depth: 2, knowledgeDir: dir });
    const froms = r.edges.map(e => e.from);
    expect(froms).toContain('y');                                  // 1-hop inbound
    expect(froms).toContain('x');                                  // 2-hop inbound (depth:2 was forwarded)
    expect(r.edges.find(e => e.from === 'x')?.hops).toBe(2);       // and it really is the 2-hop edge

    // depth:1 must NOT reach x — proves depth (not just direction) is forwarded,
    // and that the depth:2 result above wasn't the default leaking through.
    const shallow = await knowledgeNeighbors({ slug: 'z', direction: 'in', depth: 1, knowledgeDir: dir });
    expect(shallow.edges.map(e => e.from)).toContain('y');
    expect(shallow.edges.map(e => e.from)).not.toContain('x');

    // direction:out from z reaches NOTHING (z has no outbound edge) — proves
    // direction is forwarded, not defaulted to 'both' (which would surface y).
    const outward = await knowledgeNeighbors({ slug: 'z', direction: 'out', depth: 2, knowledgeDir: dir });
    expect(outward.edges).toEqual([]);
  });
});
