import { describe, it, expect } from 'vitest';
import { promises as fs, mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { captureItem, listItems, setStatus, unprocessedCount, rawDir, markProcessed } from './raw-inbox.js';

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

  it('setStatus rejects a path-traversal id and never touches a file outside raw/', async () => {
    const { brainDir, slug } = await brain();
    await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'real', now: NOW });
    const victim = join(brainDir, 'projects', slug, 'victim.md'); // a sibling of raw/, outside it
    await fs.writeFile(victim, '---\nstatus: keep\n---\n');
    const ok = await setStatus(brainDir, slug, '../victim', 'discarded');
    expect(ok).toBe(false);
    expect(await fs.readFile(victim, 'utf-8')).toBe('---\nstatus: keep\n---\n');
  });

  it('sanitizes newlines in frontmatter values so a crafted source cannot inject/flip status', async () => {
    const { brainDir, slug } = await brain();
    await captureItem({ brainDir, slug, kind: 'url',
      source: 'http://x/\nstatus: discarded', content: 'http://x/\nstatus: discarded', now: NOW });
    const items = await listItems(brainDir, slug);
    expect(items).toHaveLength(1);
    expect(items[0].status).toBe('unprocessed'); // the injected "status: discarded" did NOT take effect
    expect(items[0].source).not.toContain('\n');
    expect(await unprocessedCount(brainDir, slug)).toBe(1);
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

  it('markProcessed sets status processed and the target_node back-ref', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'drain me', now: NOW });
    expect(await markProcessed(brainDir, slug, r.id, 'auth-design')).toBe(true);
    const item = (await listItems(brainDir, slug))[0];
    expect(item.status).toBe('processed');
    expect(item.target_node).toBe('auth-design');
    expect(await unprocessedCount(brainDir, slug)).toBe(0);
  });

  it('markProcessed without a node still processes (no target_node added)', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'no node', now: NOW });
    expect(await markProcessed(brainDir, slug, r.id)).toBe(true);
    const item = (await listItems(brainDir, slug))[0];
    expect(item.status).toBe('processed');
    expect(item.target_node).toBeUndefined();
  });

  it('markProcessed rejects an unsafe id and a missing id', async () => {
    const { brainDir, slug } = await brain();
    expect(await markProcessed(brainDir, slug, '../evil', 'x')).toBe(false);
    expect(await markProcessed(brainDir, slug, 'nope', 'x')).toBe(false);
  });

  it('markProcessed replaces a pre-existing target_node with no duplicate line', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste',
      content: 'pre-attached', targetNode: 'old-node', now: NOW });
    expect(await markProcessed(brainDir, slug, r.id, 'new-node')).toBe(true);
    const item = (await listItems(brainDir, slug))[0];
    expect(item.status).toBe('processed');
    expect(item.target_node).toBe('new-node');
    const raw = await fs.readFile(join(rawDir(brainDir, slug), `${r.id}.md`), 'utf-8');
    expect((raw.match(/^target_node:/gm) || []).length).toBe(1); // exactly one — no duplicate
  });

  it('round-trips the origin provenance field', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-raw-origin-'));
    await captureItem({ brainDir: dir, slug: 'proja', kind: 'paste', source: 'paste', content: 'hello world', origin: 'proja' });
    const [item] = await listItems(dir, 'proja');
    expect(item.origin).toBe('proja');
    rmSync(dir, { recursive: true, force: true });
  });

  it('treats a legacy item with no origin as well-formed (origin undefined)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-raw-legacy-'));
    const raw = join(dir, 'projects', 'proja', 'raw');
    mkdirSync(raw, { recursive: true });
    writeFileSync(join(raw, '20260101-000000-x.md'),
      '---\nid: 20260101-000000-x\nsource: x\ncaptured_at: 2026-01-01T00:00:00Z\n' +
      'captured_by: user\ncontent_type: text/markdown\nstatus: unprocessed\nhash: abc\ngist: x\n---\n\nbody\n');
    const [item] = await listItems(dir, 'proja');
    expect(item.origin).toBeUndefined();
    expect(item.malformed).toBeFalsy();
    rmSync(dir, { recursive: true, force: true });
  });
});
