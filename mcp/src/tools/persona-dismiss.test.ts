import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { personaDismiss } from './persona-dismiss.js';

// INDEPENDENT ORACLE = the filesystem. The persona-context.sh backoff gate READS
// $BRAIN_DIR/.persona-dismissals.jsonl; this pins that the WRITER lands in the same dir, so the
// reader/writer don't diverge under a non-default BRAIN_DIR (the deep-review split-path finding).
const exists = (p: string) => fs.access(p).then(() => true, () => false);

describe('persona_dismiss writer/reader path parity', () => {
  it('writes .persona-dismissals.jsonl under the provided brainDir (not a hardcoded $HOME)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'pd-'));
    const res = await personaDismiss({ brainDir: dir, reason: 'noise' });
    expect(res.ok).toBe(true);
    const f = join(dir, '.persona-dismissals.jsonl');
    expect(await exists(f)).toBe(true);                       // ORACLE: the file the gate reads
    const j = JSON.parse((await fs.readFile(f, 'utf-8')).trim());
    expect(j.at).toMatch(/^\d{4}-\d{2}-\d{2}T/);              // full ISO — the gate's (.at)[0:10] slice depends on this
  });

  it('accumulates appends + reports count_7d from that same brainDir file', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'pd2-'));
    await personaDismiss({ brainDir: dir });
    const res = await personaDismiss({ brainDir: dir });
    expect(res.count_7d).toBe(2);
  });
});
