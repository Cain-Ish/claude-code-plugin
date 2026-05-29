import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  cmpTime, dateOf, loadEdges, foldToCurrent, validAt, neighbors, appendEdge,
} from './graph-store.js';

async function tmpLog(lines: string[]): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-'));
  const p = join(dir, 'edges.jsonl');
  await fsp.writeFile(p, lines.join('\n'));
  return p;
}

// --- A1: cmpTime + dateOf ---------------------------------------------------
describe('cmpTime (lexicographic ISO, half-open valid_to uses strict >)', () => {
  it('orders date-only strings', () => {
    expect(cmpTime('2026-05-21', '2026-05-29')).toBeLessThan(0);
    expect(cmpTime('2026-05-29', '2026-05-21')).toBeGreaterThan(0);
    expect(cmpTime('2026-05-21', '2026-05-21')).toBe(0);
  });
  it('a retire-date (date-only) is NOT after a same-day timestamp', () => {
    expect(cmpTime('2026-05-29', '2026-05-29T12:00:00Z')).toBeLessThan(0);
  });
});

describe('dateOf', () => {
  it('extracts YYYY-MM-DD from an ISO timestamp', () => {
    expect(dateOf('2026-05-29T12:00:00Z')).toBe('2026-05-29');
    expect(dateOf('2026-05-29')).toBe('2026-05-29');
  });
});

// --- A2: loadEdges ----------------------------------------------------------
describe('loadEdges', () => {
  it('returns [] when the file does not exist (graph absent = no-op)', async () => {
    expect(await loadEdges('/no/such/edges.jsonl')).toEqual([]);
  });
  it('parses valid lines and skips a torn final line', async () => {
    const p = await tmpLog([
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' }),
      '{"op":"assert","from":"a","to":"c","type":"aff',
    ]);
    const edges = await loadEdges(p);
    expect(edges).toHaveLength(1);
    expect(edges[0].to).toBe('b');
  });
  it('skips records missing required fields', async () => {
    const p = await tmpLog([
      JSON.stringify({ op: 'assert', from: 'a', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' }),
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'bogus', recorded_at: '2026-05-21T00:00:00Z' }),
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'relates', recorded_at: '2026-05-21T00:00:00Z' }),
    ]);
    expect(await loadEdges(p)).toHaveLength(1);
  });
});

// --- A3: foldToCurrent ------------------------------------------------------
describe('foldToCurrent', () => {
  it('assert then invalidate closes the interval (mark-not-delete)', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T18:30:00Z' },
      { op: 'invalidate', from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires', valid_to: '2026-05-29', recorded_at: '2026-05-29T12:00:00Z' },
    ]);
    expect(cur).toHaveLength(1);
    expect(cur[0]).toMatchObject({ valid_from: '2026-05-21', valid_to: '2026-05-29' });
  });
  it('re-asserting an open edge is idempotent (one entry, still open)', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T00:00:00Z' },
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-22T00:00:00Z' },
    ]);
    expect(cur).toHaveLength(1);
    expect(cur[0].valid_to).toBeNull();
  });
  it('defaults valid_from to the record date when absent', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'a', to: 'b', type: 'relates', recorded_at: '2026-05-21T09:00:00Z' },
    ]);
    expect(cur[0].valid_from).toBe('2026-05-21');
  });
  it('processes records in recorded_at order regardless of file order', () => {
    const cur = foldToCurrent([
      { op: 'invalidate', from: 'a', to: 'b', type: 'requires', valid_to: '2026-05-29', recorded_at: '2026-05-29T00:00:00Z' },
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T00:00:00Z' },
    ]);
    expect(cur[0]).toMatchObject({ valid_from: '2026-05-21', valid_to: '2026-05-29' });
  });
  it('ignores a stray valid_to on an assert (assert only opens, never closes)', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', valid_to: '2026-05-22', recorded_at: '2026-05-21T00:00:00Z' },
    ]);
    expect(cur[0].valid_to).toBeNull(); // not closed by the bogus valid_to
  });
});

describe('validAt — mixed date/timestamp granularity', () => {
  it('a noon-timestamp valid_from is visible to a same-day date-only query', () => {
    const e = { valid_from: '2026-05-29T12:00:00Z', valid_to: null };
    expect(validAt(e, '2026-05-29')).toBe(true);
  });
});

describe('loadEdges — type-corrupt records', () => {
  it('skips a record whose valid_to is a number (would corrupt cmpTime)', async () => {
    const p = await tmpLog([
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'requires', valid_to: 123, recorded_at: '2026-05-21T00:00:00Z' }),
      JSON.stringify({ op: 'assert', from: 'a', to: 'c', type: 'relates', recorded_at: '2026-05-21T00:00:00Z' }),
    ]);
    const edges = await loadEdges(p);
    expect(edges).toHaveLength(1);
    expect(edges[0].to).toBe('c');
  });
});

// --- A4: validAt ------------------------------------------------------------
describe('validAt — half-open [valid_from, valid_to)', () => {
  const e = { from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires' as const,
              valid_from: '2026-05-21', valid_to: '2026-05-29' };
  it('is valid mid-interval', () => expect(validAt(e, '2026-05-25')).toBe(true));
  it('is NOT valid before valid_from', () => expect(validAt(e, '2026-05-19')).toBe(false));
  it('is NOT valid AT valid_to (half-open, strict >)', () => expect(validAt(e, '2026-05-29')).toBe(false));
  it('open interval (valid_to null) is valid at now', () => {
    expect(validAt({ ...e, valid_to: null }, '2026-12-31T00:00:00Z')).toBe(true);
  });
  it('a date-only valid_to is closed against a same-day timestamp', () => {
    expect(validAt(e, '2026-05-29T12:00:00Z')).toBe(false);
  });
});

// --- A5: neighbors ----------------------------------------------------------
const G = [
  { from: 'a', to: 'b', type: 'requires' as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'b', to: 'c', type: 'requires' as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'a', to: 'd', type: 'affects'  as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'x', to: 'a', type: 'affects'  as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'a', to: 'old', type: 'requires' as const, valid_from: '2026-05-01', valid_to: '2026-05-10' },
];

describe('neighbors', () => {
  it('direction out, depth 1 returns direct dependencies of a', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', asOf: '2026-05-20' });
    expect(r.map(e => e.to).sort()).toEqual(['b', 'd']);
  });
  it('depth 2 reaches c at a lower score than b', () => {
    const r = neighbors(G, 'a', { depth: 2, direction: 'out', asOf: '2026-05-20' });
    const b = r.find(e => e.to === 'b')!; const c = r.find(e => e.to === 'c')!;
    expect(c).toBeTruthy();
    expect(c.score).toBeLessThan(b.score);
  });
  it('direction in returns blast radius (who points at a)', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'in', asOf: '2026-05-20' });
    expect(r.map(e => e.from)).toContain('x');
  });
  it('edge_types filter restricts traversal', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', edgeTypes: ['affects'], asOf: '2026-05-20' });
    expect(r.map(e => e.to)).toEqual(['d']);
  });
  it('as_of before invalidation still sees the old edge', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', asOf: '2026-05-05' });
    expect(r.map(e => e.to)).toContain('old');
  });
  it('direction both emits each edge exactly once (no double-emit regression)', () => {
    const r = neighbors(G, 'a', { depth: 2, direction: 'both', asOf: '2026-05-20' });
    const ab = r.filter(e => e.from === 'a' && e.to === 'b');
    const bc = r.filter(e => e.from === 'b' && e.to === 'c');
    expect(ab).toHaveLength(1);
    expect(bc).toHaveLength(1);
    expect(ab[0].hops).toBe(1); // min-hop kept
  });
});

// --- A6: appendEdge ---------------------------------------------------------
describe('appendEdge', () => {
  it('appends exactly one JSON line terminated by \\n', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-ap-'));
    const p = join(dir, 'edges.jsonl');
    await appendEdge(p, { op: 'assert', from: 'a', to: 'b', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' });
    await appendEdge(p, { op: 'assert', from: 'a', to: 'c', type: 'affects', recorded_at: '2026-05-21T00:00:01Z' });
    const back = await loadEdges(p);
    expect(back).toHaveLength(2);
    const raw = await fsp.readFile(p, 'utf-8');
    expect(raw.endsWith('\n')).toBe(true);
  });
  it('rejects an invalid edge type', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-ap2-'));
    const p = join(dir, 'edges.jsonl');
    await expect(appendEdge(p, { op: 'assert', from: 'a', to: 'b', type: 'bogus' as any, recorded_at: '2026-05-21T00:00:00Z' }))
      .rejects.toThrow(/invalid edge/i);
  });
});
