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
