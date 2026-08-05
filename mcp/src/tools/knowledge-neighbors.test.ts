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

  // Project-first retrieval: a project key is usually not a graph node — its edges hang
  // off an anchor entity, mapped by graph/project-registry.jsonl. The resolver makes
  // "start traversal from the current project" work.
  it('resolves an edgeless project slug to its registry anchor (resolved_anchor set)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-anchor-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      '{"anchor":"my-anchor","project":"my-project"}\n', 'utf-8');

    const r = await knowledgeNeighbors({ slug: 'my-project', direction: 'both', knowledgeDir: dir });
    expect(r.slug).toBe('my-project');
    expect(r.resolved_anchor).toBe('my-anchor');
    expect(r.edges.map(e => e.from)).toContain('learning-1');
  });

  it('a slug with its OWN edges is never anchor-resolved (only-when-empty contract)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-own-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'my-project', to: 'direct-dep', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      '{"anchor":"my-anchor","project":"my-project"}\n', 'utf-8');

    const r = await knowledgeNeighbors({ slug: 'my-project', knowledgeDir: dir });
    expect(r.resolved_anchor).toBeUndefined();
    expect(r.edges.map(e => e.to)).toContain('direct-dep');
    expect(r.edges.map(e => e.from)).not.toContain('learning-1');
  });

  it('edgeless slug with NO registry (or no matching row) still returns empty, no resolved_anchor', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-noreg-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeNeighbors({ slug: 'unmapped-project', knowledgeDir: dir });
    expect(r.resolved_anchor).toBeUndefined();
    expect(r.edges).toEqual([]);
  });

  it('as_of queries NEVER anchor-resolve: zero-at-that-date means zero, not the anchor\'s past', async () => {
    // A slug can be both a real entity (edges post-dating as_of) and a registry key;
    // substituting the anchor's history under the queried name would be wrong.
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-asof-anchor-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'my-project', to: 'late-dep', type: 'requires', valid_from: '2026-06-01', recorded_at: '2026-06-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-01-01', recorded_at: '2026-01-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      '{"anchor":"my-anchor","project":"my-project"}\n', 'utf-8');
    const past = await knowledgeNeighbors({ slug: 'my-project', as_of: '2026-03-01', knowledgeDir: dir });
    expect(past.resolved_anchor).toBeUndefined();
    expect(past.edges).toEqual([]);
  });

  it('a REAL node whose edges are direction-filtered to zero is never anchor-substituted', async () => {
    // my-project has one OUTBOUND edge; queried with direction:'in' the honest answer
    // is []. Falling back to the anchor here would present another entity's edges
    // under the queried name (the reproduced ts-review Block finding).
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-dirfilter-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'my-project', to: 'direct-dep', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      '{"anchor":"my-anchor","project":"my-project"}\n', 'utf-8');
    const r = await knowledgeNeighbors({ slug: 'my-project', direction: 'in', knowledgeDir: dir });
    expect(r.resolved_anchor).toBeUndefined();
    expect(r.anchor_miss).toBeUndefined();   // slug IS a graph node — no fallback attempted
    expect(r.edges).toEqual([]);
  });

  it('registry miss is visible: anchor_miss:true when fallback found nothing', async () => {
    // Without this marker "no registry mapping" is indistinguishable from "node with
    // no dependencies" — the invisible-dead-feature premise finding.
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-miss-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeNeighbors({ slug: 'unmapped-project', knowledgeDir: dir });
    expect(r.anchor_miss).toBe(true);
    expect(r.edges).toEqual([]);
  });

  it('a real registry I/O error (EISDIR) throws instead of masquerading as empty', async () => {
    // ENOENT = normal "no registry yet"; anything else must surface as a tool error.
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-eisdir-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.mkdir(join(dir, 'graph', 'project-registry.jsonl'));   // a DIRECTORY at the file path
    await expect(knowledgeNeighbors({ slug: 'unmapped-project', knowledgeDir: dir })).rejects.toThrow();
  });

  it('a valid-JSON row with a traversal-shaped anchor is rejected (validateSlug guard)', async () => {
    // The one guard between a corrupted registry row and neighbors(); a refactor
    // dropping the validateSlug call must fail here.
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-badanchor-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      '{"anchor":"../etc","project":"my-project"}\n', 'utf-8');
    const r = await knowledgeNeighbors({ slug: 'my-project', knowledgeDir: dir });
    expect(r.resolved_anchor).toBeUndefined();
    expect(r.edges).toEqual([]);
  });

  it('malformed registry lines are skipped, valid row still resolves', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-mal-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'learning-1', to: 'my-anchor', type: 'part_of', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await fsp.writeFile(join(dir, 'graph', 'project-registry.jsonl'),
      'not json\n{"anchor":42,"project":"my-project"}\n{"anchor":"my-anchor","project":"my-project"}\n', 'utf-8');
    const r = await knowledgeNeighbors({ slug: 'my-project', knowledgeDir: dir });
    expect(r.resolved_anchor).toBe('my-anchor');
    expect(r.edges.length).toBeGreaterThan(0);
  });
});
