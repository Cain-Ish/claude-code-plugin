import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { parseDoc } from './knowledge-search.js';
import { appendEdge } from './graph-store.js';
import { projectGraphToPages } from './graph-project.js';
import { knowledgeValidate } from './knowledge-validate.js';

// The projector/validator/parseDoc trio must agree on what "no relations" looks
// like in bytes (deep-review P1/P2/P3). These are round-trip + idempotency
// property tests — the class the regex-reader suite never had.

describe('P1 — parseDoc: related: [] is authoritative (empty != absent)', () => {
  it('an explicit related: [] is NOT re-filled from body [[links]]', () => {
    const doc = parseDoc('---\ntitle: A\ntype: entities\nrelated: []\n---\n\n# A\n\nsee [[other]]\n', '/w/wiki/entities/a.md');
    expect(doc.related).toEqual([]);   // authoritative empty — projector's cleaned form survives a read
  });
  it('an ABSENT related: key still falls back to body [[links]]', () => {
    const doc = parseDoc('---\ntitle: A\ntype: entities\n---\n\n# A\n\nsee [[other]]\n', '/w/wiki/entities/a.md');
    expect(doc.related).toEqual(['other']);
  });
});

async function gwiki(): Promise<{ dir: string; page: (s: string, fm: string, body?: string) => Promise<void> }> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'rrt-'));
  await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  const page = (s: string, fm: string, body = `\n# ${s}\n\nbody\n`) =>
    fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`), `---\n${fm}\n---\n${body}`);
  return { dir, page };
}

describe('P3 — orphan-GC scrubs a legacy BLOCK-LIST related: on an edgeless page', () => {
  it('a never-edged page with a block-list related: collapses to related: []', async () => {
    const { dir, page } = await gwiki();
    await page('lonely', 'title: lonely\ntype: entities\nrelated:\n  - dead-a\n  - dead-b');
    await page('x', 'title: x\ntype: entities\nrelated: []');
    await page('y', 'title: y\ntype: entities\nrelated: []');
    // a real edge between OTHER pages so the projector actually runs (records.length>0)
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'x', to: 'y', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'lonely.md'), 'utf-8');
    const fm = md.match(/^---\n([\s\S]*?)\n---/)![1];
    expect(fm).toMatch(/^related: \[\]$/m);            // scrubbed
    expect(fm).not.toMatch(/^[ \t]+- dead-/m);         // no orphaned block-list children survive
  });
});

describe('P2 — reindex is byte-idempotent on a graph-enabled corpus', () => {
  it('project→validate→project→validate leaves an edgeless page with a body link byte-stable', async () => {
    const { dir, page } = await gwiki();
    // edgeless page that has a body [[link]] and is MISSING the related: key (so patch would run)
    await page('p', 'title: p\ntype: entities', '\n# p\n\nrefers to [[q]] in prose\n');
    await page('q', 'title: q\ntype: entities\nrelated: []');
    await page('r', 'title: r\ntype: entities\nrelated: []');
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'q', to: 'r', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const cycle = async () => { await projectGraphToPages(dir); await knowledgeValidate(dir, { autofix: true }); };
    await cycle();
    const a = await fsp.readFile(join(dir, 'wiki', 'entities', 'p.md'), 'utf-8');
    await cycle();
    const b = await fsp.readFile(join(dir, 'wiki', 'entities', 'p.md'), 'utf-8');
    expect(b).toBe(a);   // identical input → identical bytes across full reindex cycles
    // and the page must NOT carry a phantom related: [q] derived from the body link
    expect(b.match(/^---\n([\s\S]*?)\n---/)![1]).toMatch(/^related: \[\]$/m);
  });
});
