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
export async function atomicWriteJson(filePath: string, value: unknown): Promise<void> {
  const tmp = `${filePath}.tmp.${process.pid}`;
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

let strictWriteCounter = 0;

// jit-index.ts's rebuildJitIndex needs the OPPOSITE contract from atomicWriteJson above: a
// failed write must REJECT, not be swallowed to a console.error and a clean exit 0. Its own
// docstring already promised "throws on a write failure" — atomicWriteJson silently made that
// false. Same tmp+rename mechanics (atomic replace, tmp cleaned up on failure); the tmp suffix
// adds a monotonic counter + timestamp (not just pid) so two writes racing within one process
// (or two processes sharing a pid on a platform that recycles them fast) never collide on the
// same tmp path.
export async function atomicWriteJsonStrict(filePath: string, value: unknown): Promise<void> {
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}.${strictWriteCounter++}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);   // atomic replace — reader never sees a torn file
  } catch (err) {
    try { await fs.unlink(tmp); } catch { /* already gone, or never created */ }
    throw err;
  }
}
