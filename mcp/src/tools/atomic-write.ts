import { promises as fs } from 'fs';

// P9 (deep-review): full-file JSON state was written with a plain fs.writeFile
// (truncate-then-write). A crash mid-write leaves a truncated file and the
// reader fails open to EMPTY — silently destroying the episodic index, access
// counts, or a completed dream's status. The house convention is tmp+rename
// (rename(2) is atomic on POSIX) — already used by the opus ledger; this
// centralizes it. Fail-soft: a write failure must not throw into a hook.
//
// 0.45.2: fail-soft is NOT the same as fail-SILENT. The catch used to discard the
// error entirely — no message anywhere — so a failed status.json write left the dream
// looking `running` forever with no diagnostic. maintain-llm-drain.sh already has a
// branch for that shape and attributes it to "external interference", which is the
// wrong diagnosis when the real cause is a swallowed ENOSPC/EACCES one layer down.
// The no-throw contract stays (hooks must not break); the error now reaches stderr,
// which for the MCP server is a real, captured channel.
let writeCounter = 0;

// pid alone collides for two writes racing in one process (torn JSON, audit M2): add timestamp + counter.
function uniqueTmp(filePath: string): string {
  return `${filePath}.tmp.${process.pid}.${Date.now()}.${writeCounter++}`;
}

export async function atomicWriteJson(filePath: string, value: unknown): Promise<void> {
  const tmp = uniqueTmp(filePath);
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);   // atomic replace — reader never sees a torn file
  } catch (err) {
    console.error(
      `atomicWriteJson: FAILED to write ${filePath}: ${err instanceof Error ? err.message : String(err)}`,
    );
    try { await fs.unlink(tmp); } catch { /* already gone */ }
  }
}


// jit-index.ts's rebuildJitIndex needs the OPPOSITE contract from atomicWriteJson above: a
// failed write must REJECT, not be swallowed to a console.error and a clean exit 0. Its own
// docstring already promised "throws on a write failure" — atomicWriteJson silently made that
// false. Same tmp+rename mechanics (atomic replace, tmp cleaned up on failure); the tmp suffix
// adds a monotonic counter + timestamp (not just pid) so two writes racing within one process
// (or two processes sharing a pid on a platform that recycles them fast) never collide on the
// same tmp path.
export async function atomicWriteJsonStrict(filePath: string, value: unknown): Promise<void> {
  const tmp = uniqueTmp(filePath);
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);   // atomic replace — reader never sees a torn file
  } catch (err) {
    try { await fs.unlink(tmp); } catch { /* already gone, or never created */ }
    throw err;
  }
}

// The text writer for the hot files (PROJECT.md, USER.md) under their hot-file-lock.ts lock.
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
  sleep: ms => new Promise<void>(r => setTimeout(r, ms)),
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
