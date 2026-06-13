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
    expect(md).toMatch(/related: \[router-daemon, vps-ufw-depinned\]/);  // valid YAML (β), not bracketless [[..]], [[..]]
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
    const first = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    await projectGraphToPages(dir);
    const second = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(second.match(/<!-- graph:begin/g)?.length).toBe(1);
    expect(second).toBe(first); // byte-stable across runs (no daily-date churn)
  });
  it('renders a relates out-edge under Related (not dropped)', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'relates', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md).toMatch(/\*\*Related:\*\* \[\[router-daemon\]\]/);
  });
  it('an in-only node gets related: but no empty Dependencies husk', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    // edge points TO router-daemon; router-daemon has no out-edges of its own
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'router-daemon.md'), 'utf-8');
    expect(md).toMatch(/related: \[wg-tunnel\]/);       // gets the inbound relation (β form)
    expect(md).not.toContain('<!-- graph:begin');        // but no empty block
  });
  it('does not rewrite a body line that starts with related:', async () => {
    const dir = await setup();
    const page = join(dir, 'wiki', 'entities', 'wg-tunnel.md');
    await fsp.writeFile(page, `---\ntitle: wg-tunnel\ntype: entities\nrelated: []\n---\n\n# wg-tunnel\n\nrelated: this is prose not frontmatter\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(page, 'utf-8');
    expect(md).toContain('related: this is prose not frontmatter'); // body untouched
    expect(md).toMatch(/^related: \[router-daemon\]/m);             // frontmatter updated (β form)
  });

  it('emits valid-YAML β frontmatter and consumes a legacy block-style related: list', async () => {
    const dir = await setup();
    const page = join(dir, 'wiki', 'entities', 'wg-tunnel.md');
    // legacy block-style list — the single-line rewrite used to orphan these children
    await fsp.writeFile(page, `---\ntitle: wg-tunnel\ntype: entities\nrelated:\n  - stale-a\n  - stale-b\n---\n\n# wg-tunnel\n\nbody\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(page, 'utf-8');
    expect(md).toMatch(/^related: \[router-daemon\]$/m);   // canonical β
    expect(md).not.toMatch(/^[ \t]+- stale-/m);            // no orphaned block-list children
    const frontmatter = md.match(/^---\n([\s\S]*?)\n---/)![1];
    expect(frontmatter).not.toContain('[[');               // no bracketless wiki-link form in frontmatter (body ## Dependencies still uses [[..]])
  });

  it('scrubs related: → [] and removes the Dependencies block when a page loses its only edge (orphan-GC)', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const wg1 = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(wg1).toMatch(/related: \[router-daemon\]/);
    expect(wg1).toContain('<!-- graph:begin');
    // invalidate the sole edge → BOTH endpoints become edgeless and must be scrubbed
    await appendEdge(log, { op: 'invalidate', from: 'wg-tunnel', to: 'router-daemon', type: 'requires', valid_to: '2026-05-10', recorded_at: '2026-05-10T00:00:00Z' });
    const r2 = await projectGraphToPages(dir);
    expect(r2.pagesUpdated).toBeGreaterThanOrEqual(2);
    const wg2 = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    const rd2 = await fsp.readFile(join(dir, 'wiki', 'entities', 'router-daemon.md'), 'utf-8');
    expect(wg2).toMatch(/^related: \[\]$/m);
    expect(wg2).not.toContain('<!-- graph:begin');     // husk removed
    expect(rd2).toMatch(/^related: \[\]$/m);            // child that lost its only parent is cleaned
    // idempotent after scrub — a clean edgeless page is never rewritten again
    const r3 = await projectGraphToPages(dir);
    expect(r3.pagesUpdated).toBe(0);
  });

  it('does not project an edge whose endpoint has no page on disk (deleted node → no dangling link)', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'ghost-deleted-page', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    const wg = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(wg).not.toContain('ghost-deleted-page');    // dead endpoint never projected
    expect(wg).toMatch(/^related: \[\]$/m);            // page stays clean
  });
});
