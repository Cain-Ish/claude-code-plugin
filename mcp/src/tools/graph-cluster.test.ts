import { describe, it, expect } from 'vitest';
import {
  buildAdjacency, labelPropagate, clusters, memberHash,
  type ClusterPage,
} from './graph-cluster.js';

function adjOf(edges: [string, string][]): Map<string, Set<string>> {
  const m = new Map<string, Set<string>>();
  const add = (x: string, y: string) => {
    let s = m.get(x); if (!s) { s = new Set(); m.set(x, s); } s.add(y);
  };
  for (const [x, y] of edges) { add(x, y); add(y, x); }
  return m;
}
const norm = (m: Map<string, string>) =>
  [...m.entries()].sort().map(([k, v]) => `${k}:${v}`).join(',');

describe('buildAdjacency', () => {
  it('builds an undirected, deduped adjacency from related: + body links; ignores unknown/self', () => {
    const pages: ClusterPage[] = [
      { slug: 'a', related: ['b'], bodyLinks: ['c', 'a', 'ghost'] },
      { slug: 'b', related: ['a'], bodyLinks: [] },
      { slug: 'c', related: [], bodyLinks: ['a'] },
    ];
    const adj = buildAdjacency(pages);
    expect([...adj.get('a')!].sort()).toEqual(['b', 'c']); // self + ghost dropped; a-c undirected
    expect([...adj.get('c')!]).toEqual(['a']);
    expect(adj.has('ghost')).toBe(false);
  });
});

describe('labelPropagate (deterministic)', () => {
  const barbell: [string, string][] = [
    ['a', 'b'], ['b', 'c'], ['a', 'c'],   // triangle 1
    ['x', 'y'], ['y', 'z'], ['x', 'z'],   // triangle 2
    ['c', 'x'],                            // bridge
  ];
  it('partitions a barbell into two communities', () => {
    const r = labelPropagate(adjOf(barbell));
    const comm = (s: string) => r.get(s)!;
    expect(comm('a')).toBe(comm('b'));
    expect(comm('b')).toBe(comm('c'));
    expect(comm('x')).toBe(comm('y'));
    expect(comm('y')).toBe(comm('z'));
    expect(comm('a')).not.toBe(comm('z'));
  });
  it('community id is the smallest slug among members', () => {
    const r = labelPropagate(adjOf(barbell));
    expect(r.get('a')).toBe('a');
    expect(r.get('x')).toBe('x');
  });
  it('is byte-identical across repeated runs AND shuffled insertion order', () => {
    const a1 = labelPropagate(adjOf(barbell));
    const shuffled = adjOf([...barbell].reverse().map(([u, v]) => [v, u] as [string, string]));
    const a2 = labelPropagate(shuffled);
    expect(norm(a2)).toBe(norm(a1)); // shuffle-invariant => no visit-order leakage
  });
});

describe('labelPropagate non-convergence (audit B5)', () => {
  it('a bare pair forms one community', () => {
    const r = labelPropagate(adjOf([['a', 'b']]));
    expect(r.get('a')).toBe(r.get('b'));
  });
  it('a star keeps its hub in the community', () => {
    const r = labelPropagate(adjOf([['hub', 'l1'], ['hub', 'l2'], ['hub', 'l3'], ['hub', 'l4']]));
    expect(new Set(r.values()).size).toBe(1);
  });
});

describe('clusters + memberHash', () => {
  it('groups by community, drops clusters below minSize', () => {
    const labels = new Map(Object.entries({ a: 'a', b: 'a', c: 'a', d: 'a', x: 'x', y: 'x' }));
    const cs = clusters(labels, { minSize: 4 });
    expect(cs.map(c => c.id)).toEqual(['a']);
    expect(cs[0].members).toEqual(['a', 'b', 'c', 'd']);
  });
  it('memberHash changes when a member content-hash changes at stable membership', () => {
    const m = ['a', 'b'];
    const h1 = memberHash(m, { a: 'h1', b: 'h2' });
    const h2 = memberHash(m, { a: 'h1', b: 'CHANGED' });
    const same = memberHash(m, { a: 'h1', b: 'h2' });
    expect(h1).not.toBe(h2);  // content-aware, not set-only
    expect(h1).toBe(same);    // stable
  });
});
