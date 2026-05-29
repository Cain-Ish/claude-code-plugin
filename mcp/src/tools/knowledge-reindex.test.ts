import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { appendEdge } from './graph-store.js';
import { knowledgeReindex } from './knowledge-reindex.js';

describe('knowledgeReindex integrates projection', () => {
  it('projects edges onto pages during reindex', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ri-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    for (const s of ['a-page', 'b-page']) {
      await fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`), `---\ntitle: ${s}\ntype: entities\nrelated: []\n---\n\n# ${s}\n`);
    }
    await appendEdge(join(dir, 'graph', 'edges.jsonl'),
      { op: 'assert', from: 'a-page', to: 'b-page', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await knowledgeReindex(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'a-page.md'), 'utf-8');
    expect(md).toMatch(/related: \[\[b-page\]\]/);
    expect(md).toMatch(/\*\*Requires:\*\* \[\[b-page\]\]/);
  });
  it('reindex with no graph dir still works (no-op projection)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ri0-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'solo.md'), `---\ntitle: solo\ntype: entities\n---\n\n# solo\n`);
    const r = await knowledgeReindex(dir);
    expect(r.pagesIndexed).toBe(1);
  });
});
