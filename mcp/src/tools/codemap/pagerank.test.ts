import { describe, it, expect } from 'vitest';
import { pagerank } from './pagerank.js';

// Hand-checkable chain from the plan (Task A3): A imports B and C, B imports C.
// C receives the most link mass, B some, A none => rank C > B > A.
const CHAIN_NODES = ['A', 'B', 'C'];
const CHAIN_EDGES: Array<[string, string]> = [
  ['A', 'B'],
  ['A', 'C'],
  ['B', 'C'],
];

describe('pagerank', () => {
  it('hand-checkable A->B, A->C, B->C: C outranks B outranks A', () => {
    const r = pagerank(CHAIN_NODES, CHAIN_EDGES);
    expect(r.size).toBe(3);
    expect(r.get('C')!).toBeGreaterThan(r.get('B')!);
    expect(r.get('B')!).toBeGreaterThan(r.get('A')!);
  });

  it('redistributes dangling mass: ranks stay a probability distribution (sum ~ 1)', () => {
    // C has no out-edges (dangling); without redistribution the sum leaks below 1.
    const r = pagerank(CHAIN_NODES, CHAIN_EDGES);
    const sum = [...r.values()].reduce((a, b) => a + b, 0);
    expect(sum).toBeCloseTo(1, 9);
  });

  it('two runs on the same input are identical (ordering exact, values exact)', () => {
    const r1 = pagerank(CHAIN_NODES, CHAIN_EDGES);
    const r2 = pagerank(CHAIN_NODES, CHAIN_EDGES);
    expect([...r1.keys()]).toEqual([...r2.keys()]);
    expect([...r1.entries()]).toEqual([...r2.entries()]);
  });

  it('is input-order independent: shuffled nodes/edges give identical ordering, values within tolerance', () => {
    const r1 = pagerank(CHAIN_NODES, CHAIN_EDGES);
    const shuffledNodes = ['C', 'A', 'B'];
    const shuffledEdges: Array<[string, string]> = [
      ['B', 'C'],
      ['A', 'C'],
      ['A', 'B'],
    ];
    const r2 = pagerank(shuffledNodes, shuffledEdges);
    // Ordering (Map iteration = sorted id order) must be EXACTLY equal.
    expect([...r1.keys()]).toEqual([...r2.keys()]);
    expect([...r2.keys()]).toEqual(['A', 'B', 'C']);
    // Values: tolerance only (the plan's cross-platform posture), though sorted
    // accumulation should make them bit-identical here too.
    for (const id of CHAIN_NODES) {
      expect(r2.get(id)!).toBeCloseTo(r1.get(id)!, 12);
    }
  });

  it('keeps an edgeless node present with the base rank', () => {
    const r = pagerank(['A', 'B', 'C', 'D'], [['A', 'B']]);
    expect(r.has('D')).toBe(true);
    expect(r.get('D')!).toBeGreaterThan(0);
    // A, C, D all have zero in-links => identical rank; B gets A's mass on top.
    expect(r.get('D')!).toBe(r.get('C')!);
    expect(r.get('D')!).toBe(r.get('A')!);
    expect(r.get('B')!).toBeGreaterThan(r.get('D')!);
  });

  it('a single isolated node converges to rank 1', () => {
    const r = pagerank(['solo'], []);
    expect(r.size).toBe(1);
    expect(r.get('solo')!).toBeCloseTo(1, 9);
  });

  it('returns an empty map for an empty node list', () => {
    expect(pagerank([], []).size).toBe(0);
  });

  it('damping 0 yields the uniform distribution regardless of edges', () => {
    const r = pagerank(CHAIN_NODES, CHAIN_EDGES, { damping: 0 });
    for (const id of CHAIN_NODES) expect(r.get(id)!).toBeCloseTo(1 / 3, 12);
  });

  it('honors the iterations option (fewer iterations => less converged values)', () => {
    const one = pagerank(CHAIN_NODES, CHAIN_EDGES, { iterations: 1 });
    const full = pagerank(CHAIN_NODES, CHAIN_EDGES);
    expect(one.get('C')!).not.toBe(full.get('C')!);
  });

  it('throws (fail loud) on an edge endpoint missing from the node list', () => {
    expect(() => pagerank(['A'], [['A', 'GHOST']])).toThrow(/GHOST/);
    expect(() => pagerank(['A'], [['GHOST', 'A']])).toThrow(/GHOST/);
  });

  it('throws (fail loud) on invalid options', () => {
    expect(() => pagerank(CHAIN_NODES, CHAIN_EDGES, { damping: 1 })).toThrow(/damping/);
    expect(() => pagerank(CHAIN_NODES, CHAIN_EDGES, { iterations: 0 })).toThrow(/iterations/);
    expect(() => pagerank(CHAIN_NODES, CHAIN_EDGES, { epsilon: 0 })).toThrow(/epsilon/);
  });
});
