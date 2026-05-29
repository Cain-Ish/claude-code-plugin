import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { appendEdge } from './graph-store.js';
import { projectGraphToPages } from './graph-project.js';

async function setup(): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'gp-'));
  await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  const page = (slug: string) => join(dir, 'wiki', 'entities', `${slug}.md`);
  for (const s of ['wg-tunnel', 'vps-ufw-depinned', 'router-daemon']) {
    await fsp.writeFile(page(s), `---\ntitle: ${s}\ntype: entities\nrelated: []\n---\n\n# ${s}\n\nbody\n`);
  }
  return dir;
}

describe('projectGraphToPages', () => {
  it('no graph log → no-op (pages unchanged)', async () => {
    const dir = await setup();
    const before = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    const r = await projectGraphToPages(dir);
    expect(r.pagesUpdated).toBe(0);
    const after = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(after).toBe(before);
  });
  it('writes related: union and a Dependencies block from current edges', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'affects', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'vps-ufw-depinned', type: 'requires', valid_from: '2026-05-29', recorded_at: '2026-05-29T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md).toMatch(/related: \[\[router-daemon\]\], \[\[vps-ufw-depinned\]\]/);
    expect(md).toContain('<!-- graph:begin');
    expect(md).toMatch(/\*\*Requires:\*\* \[\[vps-ufw-depinned\]\]/);
    expect(md).toMatch(/\*\*Affects:\*\* \[\[router-daemon\]\]/);
    expect(md).toContain('<!-- graph:end -->');
  });
  it('excludes invalidated edges from the projection', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'invalidate', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_to: '2026-05-10', recorded_at: '2026-05-10T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md).not.toMatch(/\*\*Requires:\*\* \[\[router-daemon\]\]/);
  });
  it('is idempotent — second run does not duplicate the block', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'affects', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md.match(/<!-- graph:begin/g)?.length).toBe(1);
  });
});
