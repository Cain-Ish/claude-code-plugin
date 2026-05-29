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
});
//# sourceMappingURL=knowledge-neighbors.test.js.map