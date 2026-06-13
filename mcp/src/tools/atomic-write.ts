import { promises as fs } from 'fs';

// P9 (deep-review): full-file JSON state was written with a plain fs.writeFile
// (truncate-then-write). A crash mid-write leaves a truncated file and the
// reader fails open to EMPTY — silently destroying the episodic index, access
// counts, or a completed dream's status. The house convention is tmp+rename
// (rename(2) is atomic on POSIX) — already used by the opus ledger; this
// centralizes it. Fail-soft: a write failure must not throw into a hook.
export async function atomicWriteJson(filePath: string, value: unknown): Promise<void> {
  const tmp = `${filePath}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);   // atomic replace — reader never sees a torn file
  } catch {
    try { await fs.unlink(tmp); } catch { /* already gone */ }
  }
}
