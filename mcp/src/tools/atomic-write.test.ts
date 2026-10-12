import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { atomicWriteJson, writeFileAtomic } from './atomic-write.js';

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

  it('concurrent in-process writes never tear the JSON (audit M2)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'aw3-'));
    const f = join(dir, 'state.json');
    const big = (c: string) => ({ d: c.repeat(2_000_000) });
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
    for (let i = 0; i < 20; i++) {
      await Promise.all([atomicWriteJson(f, big('a')), atomicWriteJson(f, big('b'))]);
      JSON.parse(await fs.readFile(f, 'utf-8'));
    }
    // Shared tmp name => the loser's rename finds its tmp already consumed (ENOENT). Windows may still
    // EPERM a rename racing an open target; that is an OS limit and leaves valid JSON.
    expect(err.mock.calls.filter(c => String(c[0]).includes('ENOENT'))).toEqual([]);
    } finally { err.mockRestore(); await fs.rm(dir, { recursive: true, force: true }); }
  });

  it('fails SOFT on an unwritable target (no throw — must never break a hook)', async () => {
    await expect(atomicWriteJson('/nonexistent_dir_zzz/state.json', { v: 1 })).resolves.toBeUndefined();
  });
});

// writeFileAtomic: the text writer under the PROJECT.md/USER.md lock (moved from hot-file-lock.ts).
describe('writeFileAtomic', () => {
  let dir: string, file: string;
  beforeEach(async () => {
    dir = await fs.mkdtemp(join(tmpdir(), 'awt-'));
    file = join(dir, 'PROJECT.md');
    await fs.writeFile(file, '# PROJECT: t\n', 'utf-8');
  });
  afterEach(async () => { await fs.rm(dir, { recursive: true, force: true }); });

  it('replaces the content via a same-directory temp file and leaves none behind', async () => {
    await writeFileAtomic(file, '# PROJECT: t\nnew body\n');
    expect(await fs.readFile(file, 'utf-8')).toBe('# PROJECT: t\nnew body\n');
    expect(await fs.readdir(dir)).toEqual(['PROJECT.md']);
  });

  const eperm = () => Object.assign(new Error('busy'), { code: 'EPERM' });
  const mkIo = (renames: Array<() => void>) => {
    const log: string[] = [];
    const io = {
      writeFile: async (f: string, d: string) => { log.push(`write ${f === file ? 'target' : 'tmp'}:${d}`); },
      rename: async () => { log.push('rename'); const r = renames.shift(); if (r) r(); },
      rm: async () => { log.push('rm'); },
      sleep: async () => { log.push('sleep'); },
    };
    return { io, log };
  };

  it('retries a transient EPERM rename, then succeeds (TS-R1)', async () => {
    const { io, log } = mkIo([() => { throw eperm(); }, () => { throw eperm(); }]);
    await writeFileAtomic(file, 'x', io);
    expect(log.filter(l => l === 'rename').length).toBe(3);
    expect(log.some(l => l === 'write target:x')).toBe(false);
  });

  it('falls back to an in-place write when the rename stays blocked (TS-R1)', async () => {
    const { io, log } = mkIo(Array.from({ length: 50 }, () => () => { throw eperm(); }));
    await writeFileAtomic(file, 'x', io);
    expect(log).toContain('write target:x');
    expect(log[log.length - 1]).toBe('rm');
  });

  // Re-audit TS-1: on Windows the in-place write lands, then rm(tmp) is refused (AV/indexer). Throwing there made
  // archive_to_wiki delete the page PROJECT.md already points to; the leftover temp is debris, not a failure.
  it('resolves once the in-place write landed even when the temp cannot be removed (re-audit TS-1)', async () => {
    const { io, log } = mkIo(Array.from({ length: 50 }, () => () => { throw eperm(); }));
    io.rm = async () => { log.push('rm'); throw Object.assign(new Error('EBUSY rm'), { code: 'EBUSY' }); };
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      await expect(writeFileAtomic(file, 'x', io)).resolves.toBeUndefined();
      expect(log).toContain('write target:x');
      expect(err).toHaveBeenCalledTimes(1);
      expect(String(err.mock.calls[0][0])).toContain('EBUSY rm');
    } finally { err.mockRestore(); }
  });

  it('names its temp file so the ensure-dirs debris sweep (*.tmp.*) can reap a killed write (re-audit R5-9)', async () => {
    const tmps: string[] = [];
    const io = { writeFile: async (f: string) => { tmps.push(f); }, rename: async () => {}, rm: async () => {}, sleep: async () => {} };
    await writeFileAtomic(file, 'x', io);
    expect(tmps).toHaveLength(1);
    expect(tmps[0].startsWith(`${file}.tmp.`)).toBe(true);
  });

  it('does not retry a non-transient rename error (TS-R1)', async () => {
    const { io, log } = mkIo([() => { throw Object.assign(new Error('x'), { code: 'ENOSPC' }); }]);
    await expect(writeFileAtomic(file, 'x', io)).rejects.toThrow('x');
    expect(log.filter(l => l === 'rename').length).toBe(1);
  });
});
