import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs, mkdtempSync, rmSync, readFileSync } from 'fs';
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

// --- folded from mcp/test/persona-dismiss.test.ts (now co-located with its source module) ---

describe('persona_dismiss', () => {
  let brainDir: string;
  beforeEach(() => { brainDir = mkdtempSync(join(tmpdir(), 'ps-dismiss-')); });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('appends a new dismissal entry to .persona-dismissals.jsonl', async () => {
    const r = await personaDismiss({ prompt_snippet: 'noisy suggestion', reason: 'irrelevant', brainDir });
    expect(r.ok).toBe(true);
    expect(r.count_7d).toBe(1);
    const lines = readFileSync(join(brainDir, '.persona-dismissals.jsonl'), 'utf-8').trim().split('\n');
    expect(lines.length).toBe(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed.prompt_snippet).toBe('noisy suggestion');
    expect(parsed.reason).toBe('irrelevant');
  });

  it('count_7d aggregates across appends', async () => {
    await personaDismiss({ brainDir });
    await personaDismiss({ brainDir });
    const r = await personaDismiss({ brainDir });
    expect(r.count_7d).toBe(3);
  });

  it('prunes entries older than 30 days on append', async () => {
    const oldEntry = JSON.stringify({ at: new Date(Date.now() - 40 * 86400000).toISOString() }) + '\n';
    // Seed an old entry then append a fresh one
    const file = join(brainDir, '.persona-dismissals.jsonl');
    // Use Node fs directly to write seed
    const fs = await import('fs');
    fs.writeFileSync(file, oldEntry);
    const r = await personaDismiss({ brainDir });
    const lines = readFileSync(file, 'utf-8').trim().split('\n');
    expect(lines.length).toBe(1); // old entry pruned, new one added
    expect(r.count_7d).toBe(1);
  });

  it('truncates prompt_snippet at 200 chars', async () => {
    const long = 'x'.repeat(300);
    await personaDismiss({ prompt_snippet: long, brainDir });
    const lines = readFileSync(join(brainDir, '.persona-dismissals.jsonl'), 'utf-8').trim().split('\n');
    const parsed = JSON.parse(lines[0]);
    expect(parsed.prompt_snippet.length).toBe(200);
  });
});
