import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { captureItem, listItems, setStatus, unprocessedCount, rawDir } from './raw-inbox.js';

async function brain(): Promise<{ brainDir: string; slug: string }> {
  const brainDir = await fs.mkdtemp(join(tmpdir(), 'raw-'));
  const slug = 'alpha';
  await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
  return { brainDir, slug };
}
const NOW = '2026-06-03T14:15:00Z';

describe('raw-inbox', () => {
  it('captures pasted text as a markdown item with provenance frontmatter', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste',
      content: 'a rate-limit note', now: NOW });
    expect(r.duplicate).toBe(false);
    expect(r.id).toMatch(/^20260603T141500Z-/);
    const items = await listItems(brainDir, slug);
    expect(items).toHaveLength(1);
    expect(items[0].status).toBe('unprocessed');
    expect(items[0].content_type).toBe('text/markdown');
    expect(items[0].captured_by).toBe('user');
    expect(items[0].body).toContain('a rate-limit note');
  });

  it('captures a URL as an offline pointer (no fetch), content_type text/uri-list', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'url',
      source: 'https://example.com/spec', content: 'https://example.com/spec', now: NOW });
    const items = await listItems(brainDir, slug);
    expect(items[0].content_type).toBe('text/uri-list');
    expect(items[0].source).toBe('https://example.com/spec');
    expect(items[0].body).toContain('https://example.com/spec');
    expect(r.id).toContain('example-com');
  });

  it('captures a text file into the body; a binary file into a blob sidecar', async () => {
    const { brainDir, slug } = await brain();
    const txt = join(brainDir, 'note.md');
    await fs.writeFile(txt, '# Title\nbody text');
    await captureItem({ brainDir, slug, kind: 'file', source: txt, now: NOW });
    const bin = join(brainDir, 'pic.bin');
    await fs.writeFile(bin, Buffer.from([0x00, 0x01, 0x02, 0x00]));
    const rb = await captureItem({ brainDir, slug, kind: 'file', source: bin, now: '2026-06-03T14:16:00Z' });
    const items = await listItems(brainDir, slug);
    const text = items.find(i => i.source === txt)!;
    expect(text.blob).toBeUndefined();
    expect(text.body).toContain('body text');
    const binItem = items.find(i => i.source === bin)!;
    expect(binItem.blob).toBe(`${rb.id}.bin`);
    await expect(fs.access(join(rawDir(brainDir, slug), `${rb.id}.bin`))).resolves.toBeUndefined();
  });

  it('is idempotent: re-capturing identical content returns the existing unprocessed item', async () => {
    const { brainDir, slug } = await brain();
    const a = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'same', now: NOW });
    const b = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'same', now: '2026-06-03T15:00:00Z' });
    expect(b.duplicate).toBe(true);
    expect(b.id).toBe(a.id);
    expect(await unprocessedCount(brainDir, slug)).toBe(1);
  });

  it('records an optional target_node and supports status transitions + count', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste',
      content: 'evidence', targetNode: 'auth-design', now: NOW });
    expect((await listItems(brainDir, slug))[0].target_node).toBe('auth-design');
    expect(await unprocessedCount(brainDir, slug)).toBe(1);
    expect(await setStatus(brainDir, slug, r.id, 'discarded')).toBe(true);
    expect(await unprocessedCount(brainDir, slug)).toBe(0);
    expect((await listItems(brainDir, slug))[0].status).toBe('discarded');
  });

  it('rejects an unsafe slug', async () => {
    const { brainDir } = await brain();
    await expect(captureItem({ brainDir, slug: '../escape', kind: 'paste', source: 'paste',
      content: 'x', now: NOW })).rejects.toThrow();
  });

  it('flags a malformed item (missing frontmatter) without throwing', async () => {
    const { brainDir, slug } = await brain();
    await fs.mkdir(rawDir(brainDir, slug), { recursive: true });
    await fs.writeFile(join(rawDir(brainDir, slug), 'broken.md'), 'no frontmatter here');
    const items = await listItems(brainDir, slug);
    const broken = items.find(i => i.id === 'broken')!;
    expect(broken.malformed).toBe(true);
    expect(await unprocessedCount(brainDir, slug)).toBe(1);
  });
});
