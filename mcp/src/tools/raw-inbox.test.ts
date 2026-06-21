import { describe, it, expect } from 'vitest';
import { promises as fs, mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { captureItem, listItems, setStatus, unprocessedCount, rawDir, markProcessed, partitionPending, pruneProcessed } from './raw-inbox.js';
import type { RawItem } from './raw-inbox.js';

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

  it('pruneProcessed removes processed + discarded items (and blob siblings), keeps unprocessed + malformed', async () => {
    const { brainDir, slug } = await brain();
    // unprocessed → KEEP
    const keep = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'keep me', now: NOW });
    // processed → PRUNE
    const proc = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'drained', now: '2026-06-03T14:16:00Z' });
    await markProcessed(brainDir, slug, proc.id, 'some-node');
    // discarded → PRUNE
    const disc = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'noise', now: '2026-06-03T14:17:00Z' });
    await setStatus(brainDir, slug, disc.id, 'discarded');
    // binary, processed → PRUNE the .md AND its sibling blob
    const bin = join(brainDir, 'pic.bin');
    await fs.writeFile(bin, Buffer.from([0x00, 0x01, 0x00]));
    const binItem = await captureItem({ brainDir, slug, kind: 'file', source: bin, now: '2026-06-03T14:18:00Z' });
    await markProcessed(brainDir, slug, binItem.id, 'pic-node');
    const blobPath = join(rawDir(brainDir, slug), `${binItem.id}.bin`);
    await expect(fs.access(blobPath)).resolves.toBeUndefined(); // blob exists pre-prune
    // binary, DISCARDED → also PRUNE the .md AND its blob (closed-state branch, same as processed)
    const bin2 = join(brainDir, 'pic2.bin');
    await fs.writeFile(bin2, Buffer.from([0x00, 0x02, 0x00]));
    const binDisc = await captureItem({ brainDir, slug, kind: 'file', source: bin2, now: '2026-06-03T14:19:00Z' });
    await setStatus(brainDir, slug, binDisc.id, 'discarded');
    const blobPath2 = join(rawDir(brainDir, slug), `${binDisc.id}.bin`);
    await expect(fs.access(blobPath2)).resolves.toBeUndefined(); // blob exists pre-prune
    // malformed (missing frontmatter) → KEEP (needs manual repair)
    await fs.writeFile(join(rawDir(brainDir, slug), 'broken.md'), 'no frontmatter');

    const removed = await pruneProcessed(brainDir, slug);
    expect(removed).toBe(4); // proc + disc + binItem + binDisc (.md count; blobs not double-counted)

    const ids = (await listItems(brainDir, slug)).map(i => i.id);
    expect(ids).toContain(keep.id);        // unprocessed kept
    expect(ids).toContain('broken');       // malformed kept
    expect(ids).not.toContain(proc.id);    // processed pruned
    expect(ids).not.toContain(disc.id);    // discarded pruned
    expect(ids).not.toContain(binItem.id); // binary processed pruned
    await expect(fs.access(blobPath)).rejects.toThrow(); // blob sibling pruned too
    expect(ids).not.toContain(binDisc.id); // binary discarded pruned
    await expect(fs.access(blobPath2)).rejects.toThrow(); // discarded-binary blob pruned too
  });

  it('pruneProcessed is a no-op when nothing is closed (returns 0, keeps everything)', async () => {
    const { brainDir, slug } = await brain();
    await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'pending', now: NOW });
    expect(await pruneProcessed(brainDir, slug)).toBe(0);
    expect(await listItems(brainDir, slug)).toHaveLength(1);
  });

  it('pruneProcessed rejects an unsafe slug', async () => {
    const { brainDir } = await brain();
    await expect(pruneProcessed(brainDir, '../escape')).rejects.toThrow();
  });
});

describe('partitionPending', () => {
  const mk = (over: Partial<RawItem>): RawItem => ({
    id: 'i', source: 's', captured_at: 't', captured_by: 'user', content_type: 'text/markdown',
    status: 'unprocessed', hash: 'h', gist: 'g', body: 'b', ...over,
  });
  it('drains own-origin, legacy (no origin), holds foreign, skips processed/malformed', () => {
    const items: RawItem[] = [
      mk({ id: 'own', origin: 'proja' }),
      mk({ id: 'legacy' }),                                   // no origin → conservative default
      mk({ id: 'foreign', origin: 'projb' }),                // different project → held back
      mk({ id: 'done', origin: 'proja', status: 'processed' }),
      mk({ id: 'bad', origin: 'proja', malformed: true }),
    ];
    const { drainable, foreign } = partitionPending(items, 'proja');
    expect(drainable.map(i => i.id)).toEqual(['own', 'legacy']);
    expect(foreign.map(i => i.id)).toEqual(['foreign']);
  });
});
