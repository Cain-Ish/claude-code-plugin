import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeRelate } from './knowledge-relate.js';
import { loadEdges } from './graph-store.js';

async function kdir(): Promise<string> { return fsp.mkdtemp(join(tmpdir(), 'kr-')); }

describe('knowledgeRelate', () => {
  it('asserts an edge to the log', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', knowledgeDir: dir });
    expect(r.ok).toBe(true);
    const edges = await loadEdges(join(dir, 'graph', 'edges.jsonl'));
    expect(edges[0]).toMatchObject({ op: 'assert', from: 'a', to: 'b', type: 'requires', source: 'manual', confidence: 'high' });
  });
  it('invalidate=true writes an invalidate record with valid_to', async () => {
    const dir = await kdir();
    await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', knowledgeDir: dir });
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', invalidate: true, valid_to: '2026-05-29', knowledgeDir: dir });
    expect(r.ok).toBe(true);
    const edges = await loadEdges(join(dir, 'graph', 'edges.jsonl'));
    expect(edges[1]).toMatchObject({ op: 'invalidate', valid_to: '2026-05-29' });
  });
  it('rejects an invalid slug', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: '../etc/passwd', to: 'b', type: 'requires', knowledgeDir: dir });
    expect(r.ok).toBe(false);
  });
  it('rejects an invalid edge type', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'bogus' as any, knowledgeDir: dir });
    expect(r.ok).toBe(false);
  });
  it('rejects invalidate when there is no open edge to close', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', invalidate: true, valid_to: '2026-05-29', knowledgeDir: dir });
    expect(r.ok).toBe(false);
    expect(r.reason).toMatch(/no open/i);
    // and nothing was written
    expect(await loadEdges(join(dir, 'graph', 'edges.jsonl'))).toEqual([]);
  });
  it('rejects a non-ISO valid_from', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', valid_from: 'yesterday', knowledgeDir: dir });
    expect(r.ok).toBe(false);
    expect(r.reason).toMatch(/valid_from/);
  });
});
