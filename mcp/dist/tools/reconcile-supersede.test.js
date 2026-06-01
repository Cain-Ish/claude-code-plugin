import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeRelate } from './knowledge-relate.js';
import { knowledgeNeighbors } from './knowledge-neighbors.js';
// Locks the structural contract the maintainer's deterministic SUPERSEDE procedure relies on
// (spec 2026-06-01-dream-consolidation-v2 §B2.2): out-edge enumeration returns stored-from
// edges only, and knowledge_relate(invalidate) closes the stored (from,type,to) row — NOT the
// bidirectional read projection — so an inbound edge and unnamed out-edges stay live.
describe('SUPERSEDE directionality (deterministic enumerated invalidation)', () => {
    const pairs = (r) => r.edges.map(e => `${e.from}->${e.to}:${e.type}`).sort();
    it('enumerates only old\'s out-edges; invalidating a named one leaves inbound + unnamed edges live', async () => {
        const dir = await fs.mkdtemp(join(tmpdir(), 'sup-'));
        await knowledgeRelate({ from: 'old', to: 'x', type: 'requires', knowledgeDir: dir });
        await knowledgeRelate({ from: 'old', to: 'y', type: 'part_of', knowledgeDir: dir });
        await knowledgeRelate({ from: 'z', to: 'old', type: 'requires', knowledgeDir: dir }); // inbound
        // (b) enumerate out-edges — stored-from only, never the inbound z->old
        const out = await knowledgeNeighbors({ slug: 'old', direction: 'out', knowledgeDir: dir });
        expect(pairs(out)).toEqual(['old->x:requires', 'old->y:part_of']);
        // (d) invalidate ONLY the named edge (old,requires,x)
        const inv = await knowledgeRelate({
            from: 'old', to: 'x', type: 'requires', invalidate: true, valid_to: '2020-01-01', knowledgeDir: dir,
        });
        expect(inv.ok).toBe(true);
        // unnamed out-edge stays live; the named one is gone
        const liveOut = await knowledgeNeighbors({ slug: 'old', direction: 'out', knowledgeDir: dir });
        expect(pairs(liveOut)).toEqual(['old->y:part_of']);
        // inbound edge untouched (directionality guard)
        const inbound = await knowledgeNeighbors({ slug: 'old', direction: 'in', knowledgeDir: dir });
        expect(pairs(inbound)).toContain('z->old:requires');
    });
});
//# sourceMappingURL=reconcile-supersede.test.js.map