import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync, utimesSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { lockPathFor, withFileLock } from './hot-file-lock.js';

describe('hot-file-lock (E3, audit 2026-10)', () => {
  let dir: string, file: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'hot-lock-'));
    file = join(dir, 'PROJECT.md');
    writeFileSync(file, '# PROJECT: t\n', 'utf-8');
  });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); vi.restoreAllMocks(); });

  it('uses lib.sh sb_archive_lock\'s path: ".<name>.lock" next to the file', () => {
    expect(lockPathFor(file)).toBe(join(dir, '.PROJECT.md.lock'));
  });

  it('waits for a held lock and runs once it is released, then removes its own lock', async () => {
    writeFileSync(lockPathFor(file), `${process.pid}.held\n`);
    let ran = false;
    const p = withFileLock(file, () => 'busy', async () => { ran = true; return 'ran'; });
    await new Promise(r => setTimeout(r, 300));
    expect(ran).toBe(false);
    rmSync(lockPathFor(file));
    expect(await p).toBe('ran');
    expect(existsSync(lockPathFor(file))).toBe(false);
  });

  it('a live holder past the wait: returns busy(reason), never runs fn, leaves the lock alone', async () => {
    writeFileSync(lockPathFor(file), `${process.pid}.held\n`);
    let ran = false;
    const res = await withFileLock(file, reason => `busy: ${reason}`, async () => { ran = true; return 'ran'; }, 300);
    expect(ran).toBe(false);
    expect(res).toMatch(/^busy: PROJECT\.md lock not taken .*holder \d+\.held/);
    expect(readFileSync(lockPathFor(file), 'utf-8')).toBe(`${process.pid}.held\n`);
  });

  it('steals a stale lock (older than 60 s, holder pid gone) and says so', async () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    writeFileSync(lockPathFor(file), '999999999.dead\n');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lockPathFor(file), old, old);
    expect(await withFileLock(file, () => 'busy', async () => 'ran', 2000)).toBe('ran');
    expect(err.mock.calls.some(c => /stealing a stale lock/.test(String(c[0])))).toBe(true);
    expect(existsSync(lockPathFor(file))).toBe(false);
  });

  // Re-audit S8-4: the lib.sh twin tests these three (test-transcript-archive.sh); the TS side did not.
  it('puts back a fresh lock that replaced the stale one between its read and the steal', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    writeFileSync(lockPathFor(file), '999999999.dead\n');
    const old = new Date(Date.now() - 120_000);
    utimesSync(lockPathFor(file), old, old);
    const fsp = (await import('fs')).promises;
    const realRename = fsp.rename;
    vi.spyOn(fsp, 'rename').mockImplementationOnce(async (a: any, b: any) => {
      writeFileSync(lockPathFor(file), 'fresh.9\n');   // another writer won the race
      return realRename(a, b);
    });
    let ran = false;
    expect(await withFileLock(file, () => 'busy', async () => { ran = true; return 'ran'; }, 300)).toBe('busy');
    expect(ran).toBe(false);
    expect(readFileSync(lockPathFor(file), 'utf-8')).toBe('fresh.9\n');
  });

  it('leaves a lock that is no longer its own (stolen while held) in place', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(await withFileLock(file, () => 'busy', async () => { writeFileSync(lockPathFor(file), 'other.1\n'); return 'ran'; })).toBe('ran');
    expect(readFileSync(lockPathFor(file), 'utf-8')).toBe('other.1\n');
  });

  it('hands fn an owned() probe that turns false once the lock is stolen (re-audit R5-1)', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const seen: boolean[] = [];
    await withFileLock(file, () => 'busy', async owned => {
      seen.push(await owned());
      writeFileSync(lockPathFor(file), 'other.1\n');
      seen.push(await owned());
      return 'ran';
    });
    expect(seen).toEqual([true, false]);
  });

  it('steals a lock past the 600 s hard bound even when its holder pid answers', async () => {
    const orig = Object.getOwnPropertyDescriptor(process, 'platform')!;
    vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      Object.defineProperty(process, 'platform', { value: 'linux' });   // win32 counts every pid as gone
      writeFileSync(lockPathFor(file), `${process.pid}.hung\n`);
      const old = new Date(Date.now() - 700_000);
      utimesSync(lockPathFor(file), old, old);
      expect(await withFileLock(file, () => 'busy', async () => 'ran', 2000)).toBe('ran');
    } finally { Object.defineProperty(process, 'platform', orig); }
  });

  it('does not steal a young lock even when its holder pid is gone', async () => {
    writeFileSync(lockPathFor(file), '999999999.dead\n');
    expect(await withFileLock(file, () => 'busy', async () => 'ran', 300)).toBe('busy');
  });

  it('a failing unlock does not fail a successful write (TS-R5)', async () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    const fsp = (await import('fs')).promises;
    const realRm = fsp.rm;
    vi.spyOn(fsp, 'rm').mockImplementation(async (p: any, o: any) => {
      if (String(p).endsWith('.lock')) throw Object.assign(new Error('EBUSY'), { code: 'EBUSY' });
      return realRm(p, o);
    });
    expect(await withFileLock(file, () => 'busy', async () => 'ran')).toBe('ran');
    expect(err.mock.calls.some(c => /could not remove the lock/.test(String(c[0])))).toBe(true);
  });

  it('on win32 a lock older than 60 s counts as abandoned even when its pid answers (TS-R6)', async () => {
    const orig = Object.getOwnPropertyDescriptor(process, 'platform')!;
    const old = new Date(Date.now() - 120_000);
    vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      Object.defineProperty(process, 'platform', { value: 'win32' });
      writeFileSync(lockPathFor(file), `${process.pid}.msys
`);
      utimesSync(lockPathFor(file), old, old);
      expect(await withFileLock(file, () => 'busy', async () => 'ran', 2000)).toBe('ran');
      Object.defineProperty(process, 'platform', { value: 'linux' });
      writeFileSync(lockPathFor(file), `${process.pid}.live
`);
      utimesSync(lockPathFor(file), old, old);
      expect(await withFileLock(file, () => 'busy', async () => 'ran', 300)).toBe('busy');
    } finally { Object.defineProperty(process, 'platform', orig); }
  });
});
