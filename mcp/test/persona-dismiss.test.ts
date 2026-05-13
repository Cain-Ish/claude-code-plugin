import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { personaDismiss } from '../src/tools/persona-dismiss.js';

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
