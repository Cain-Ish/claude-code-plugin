import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { atomicWriteJson } from './atomic-write.js';

// P9 oracle: the write must be observable as all-or-nothing — after it returns,
// the target holds the new value AND no `.tmp.*` sidecar is left behind (a leaked
// tmp means the rename didn't happen / state could be torn). Real filesystem
// facts, not a re-read of the writer's claim.
describe('atomicWriteJson', () => {
  it('writes valid JSON and leaves NO .tmp sidecar', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'aw-'));
    const f = join(dir, 'state.json');
    await atomicWriteJson(f, { a: 1, b: ['x'] });
    expect(JSON.parse(await fs.readFile(f, 'utf-8'))).toEqual({ a: 1, b: ['x'] });
    const leftovers = (await fs.readdir(dir)).filter(n => n.includes('.tmp.'));
    expect(leftovers).toEqual([]);   // rename consumed the tmp file
  });

  it('replaces existing content atomically (old value fully gone)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'aw2-'));
    const f = join(dir, 'state.json');
    await atomicWriteJson(f, { v: 1 });
    await atomicWriteJson(f, { v: 2 });
    expect(JSON.parse(await fs.readFile(f, 'utf-8'))).toEqual({ v: 2 });
  });

  it('fails SOFT on an unwritable target (no throw — must never break a hook)', async () => {
    await expect(atomicWriteJson('/nonexistent_dir_zzz/state.json', { v: 1 })).resolves.toBeUndefined();
  });
});
