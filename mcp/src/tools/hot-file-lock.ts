import { promises as fs } from 'fs';
import { randomInt } from 'crypto';
import { basename, dirname, join } from 'path';

// E3 (audit 2026-10): PROJECT.md and USER.md are read-modify-written by the bash merge
// (merge-project-update.sh, lib.sh sb_pin_to_user) AND by pin_to_project / pin_to_user /
// archive_to_wiki. Unlocked, a pin landing inside a merge's window returned ok:true and was then
// overwritten by the merge's final mv. Every writer holds ONE on-disk lock per file: lib.sh
// sb_archive_lock's noclobber file ".<name>.lock" next to it, holding "<pid>.<nonce>". Same stale
// rule as lib.sh: steal only when older than 60 s and the holder pid is gone, or older than 600 s
// whatever the pid says, by rename-then-verify (a fresh lock that replaced the stale one is put
// back). A bash holder's MSYS pid may not answer process.kill on Windows; it then counts as gone
// after the 60 s age, as lib.sh already accepts for a holder under another runtime.
const STALE_MS = 60_000;
const HUNG_MS = 600_000;
export const LOCK_WAIT_MS = 15_000;

export function lockPathFor(file: string): string {
  return join(dirname(file), `.${basename(file)}.lock`);
}

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
const firstLine = async (f: string) => (await fs.readFile(f, 'utf-8')).split(/\r?\n/)[0];

function holderGone(token: string): boolean {
  const pid = token.split('.')[0];
  if (!/^\d+$/.test(pid)) return true;
  // A bash holder's pid is an MSYS pid that means nothing to Windows; the caller has already checked the age.
  if (process.platform === 'win32') return true;
  try { process.kill(Number(pid), 0); return false; }
  catch (e) { return (e as NodeJS.ErrnoException).code === 'ESRCH'; }
}

async function stealIfStale(lf: string): Promise<void> {
  let age: number, holder: string;
  try { age = Date.now() - (await fs.stat(lf)).mtimeMs; holder = await firstLine(lf); }
  catch { return; }   // released meanwhile: the caller just retries its create
  if (age <= STALE_MS || (age <= HUNG_MS && !holderGone(holder))) return;
  const grab = join(dirname(lf), `.steal-${process.pid}-${randomInt(1e9)}${basename(lf)}`);
  try { await fs.rename(lf, grab); } catch { return; }   // gone already, or another stealer won
  const got = await firstLine(grab).catch(() => '');
  if (got !== holder) {
    await fs.writeFile(lf, `${got}\n`, { flag: 'wx' }).catch(() =>
      console.error(`[hot-file-lock] took a fresh lock by mistake (holder ${got}) on ${lf} and could not put it back; two writers may overlap`));
  } else {
    console.error(`[hot-file-lock] stealing a stale lock (${Math.round(age / 1000)} s old, holder ${holder || '?'}) on ${lf}`);
  }
  await fs.rm(grab, { force: true });
}

/** Run fn holding file's shared lock. Still busy after waitMs: return busy(reason), nothing run. */
export async function withFileLock<T>(
  file: string, busy: (reason: string) => T, fn: () => Promise<T>, waitMs = LOCK_WAIT_MS,
): Promise<T> {
  const lf = lockPathFor(file);
  const token = `${process.pid}.${randomInt(1e9)}`;
  const end = Date.now() + waitMs;
  let lastCode = 'EEXIST';
  for (;;) {
    try { await fs.writeFile(lf, `${token}\n`, { flag: 'wx' }); break; }
    catch (e) {
      lastCode = (e as NodeJS.ErrnoException).code ?? String(e);
      // EPERM/EACCES too: Windows refuses a create for a moment while the old lock is being deleted.
      if (lastCode !== 'EEXIST' && lastCode !== 'EPERM' && lastCode !== 'EACCES') throw e;
    }
    await stealIfStale(lf);
    if (Date.now() >= end) {
      const holder = await firstLine(lf).catch(() => 'none');
      return busy(`${basename(file)} lock not taken within ${Math.round(waitMs / 1000)} s (${lastCode}, holder ${holder}); nothing written, retry`);
    }
    await sleep(100);
  }
  try { return await fn(); }
  finally {
    const held = await firstLine(lf).catch(() => '');
    if (held === token) {
      // A failing unlock (Windows EBUSY) must not turn a successful write into an error; the lock goes stale.
      await fs.rm(lf, { force: true }).catch(e =>
        console.error(`[hot-file-lock] could not remove the lock on ${basename(file)}: ${(e as Error).message}; it goes stale in ${STALE_MS / 1000} s`));
    }
    else console.error(`[hot-file-lock] the lock on ${basename(file)} is no longer ours (ours ${token}, now ${held || 'none'}: stolen while held); left as it is`);
  }
}

let seq = 0;
const RENAME_RETRY = new Set(['EPERM', 'EACCES', 'EBUSY']);
const RENAME_BACKOFF_MS = [10, 20, 40, 80, 160, 200, 200, 200, 200, 200, 200];   // ~1.5 s
export interface AtomicIo {
  writeFile: (f: string, d: string) => Promise<void>;
  rename: (a: string, b: string) => Promise<void>;
  rm: (f: string) => Promise<void>;
  sleep: (ms: number) => Promise<void>;
}
const realIo: AtomicIo = {
  writeFile: (f, d) => fs.writeFile(f, d, 'utf-8'),
  rename: (a, b) => fs.rename(a, b),
  rm: f => fs.rm(f, { force: true }),
  sleep,
};

/**
 * Replace file atomically: write a temp file in the SAME directory, then rename it over file.
 * On Windows the rename fails EPERM/EACCES/EBUSY while any reader has file open: retry ~1.5 s, then
 * write in place (callers hold the file lock, so only plain readers can see the non-atomic window).
 */
export async function writeFileAtomic(file: string, data: string, io: AtomicIo = realIo): Promise<void> {
  const tmp = `${file}.${process.pid}.${Date.now()}.${seq++}.tmp`;
  try {
    await io.writeFile(tmp, data);
    for (let i = 0; ; i++) {
      try { await io.rename(tmp, file); return; }
      catch (e) {
        if (!RENAME_RETRY.has((e as NodeJS.ErrnoException).code ?? '')) throw e;
        if (i >= RENAME_BACKOFF_MS.length) break;
        await io.sleep(RENAME_BACKOFF_MS[i]);
      }
    }
    await io.writeFile(file, data);
    await io.rm(tmp);
  } catch (e) { await io.rm(tmp).catch(() => {}); throw e; }
}
