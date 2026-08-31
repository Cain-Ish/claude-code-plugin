import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pinToProject } from './pin-to-project.js';

const tpl = `# PROJECT: test
## Goal
do thing
## State
in progress
## Conventions
none
## Recent decisions
- nothing
## Open blockers

## Cross-references

`;

describe('pin_to_project', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'pin-proj-'));
    mkdirSync(join(dir, 'projects', 'test-slug'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), tpl, 'utf-8');
  });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it('appends [active] blocker', async () => {
    const res = await pinToProject({ text: 'API rate limit', slug: 'test-slug', section: 'blockers', brainDir: dir });
    expect(res.ok).toBe(true);
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/## Open blockers\s*\n- \[active\] API rate limit/);
  });

  it('appends [decision] entry', async () => {
    const res = await pinToProject({ text: 'picked SQLite over Postgres', slug: 'test-slug', section: 'decisions', brainDir: dir });
    expect(res.ok).toBe(true);
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/\[decision\] picked SQLite over Postgres/);
  });

  it('rejects unknown section', async () => {
    const res = await pinToProject({ text: 'x', slug: 'test-slug', section: 'goal' as any, brainDir: dir });
    expect(res.ok).toBe(false);
  });

  // --- Decision-capture ritual (0.48.0): dated entries, reasoning, explicit supersession ---

  it('decision entries are date-first so mark_stale can age them', async () => {
    const res = await pinToProject({ text: 'picked SQLite over Postgres', slug: 'test-slug', section: 'decisions', brainDir: dir });
    expect(res.ok).toBe(true);
    // - [YYYY-MM-DD] [decision] <text> — date IMMEDIATELY after "- " (mark_stale contract)
    expect(res.line_added).toMatch(/^- \[\d{4}-\d{2}-\d{2}\] \[decision\] picked SQLite over Postgres$/);
  });

  it('reasoning and rejected render as a (why: …; rejected: …) suffix', async () => {
    const res = await pinToProject({
      text: 'chose flock over mkdir for the lock', slug: 'test-slug', section: 'decisions', brainDir: dir,
      reasoning: 'flock releases on process death', rejected: 'mkdir — stale dir survives a crash',
    });
    expect(res.ok).toBe(true);
    expect(res.line_added).toMatch(/\[decision\] chose flock over mkdir for the lock \(why: flock releases on process death; rejected: mkdir — stale dir survives a crash\)$/);
  });

  it('dedupes a dated decision on core text even when reasoning differs', async () => {
    const r1 = await pinToProject({ text: 'use jsonl ledger', slug: 'test-slug', section: 'decisions', brainDir: dir, reasoning: 'zero native deps' });
    expect(r1.reason).toBeUndefined();
    const r2 = await pinToProject({ text: 'use jsonl ledger', slug: 'test-slug', section: 'decisions', brainDir: dir, reasoning: 'different wording' });
    expect(r2.ok).toBe(true);
    expect(r2.reason).toBe('already present');
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content.split('\n').filter(l => l.includes('use jsonl ledger')).length).toBe(1);
  });

  it('supersedes marks the old bullet, never deletes it', async () => {
    await pinToProject({ text: 'drain timeout is thirty seconds', slug: 'test-slug', section: 'decisions', brainDir: dir });
    const res = await pinToProject({
      text: 'drain timeout is now 120 seconds', slug: 'test-slug', section: 'decisions', brainDir: dir,
      supersedes: 'thirty seconds',
    });
    expect(res.ok).toBe(true);
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    const lines = content.split('\n');
    const old = lines.find(l => l.includes('thirty seconds'));
    expect(old).toMatch(/^- \[superseded\] /);           // marked …
    expect(old).toContain('drain timeout is thirty seconds'); // … not deleted
    expect(lines.some(l => l.includes('now 120 seconds') && !l.includes('[superseded]'))).toBe(true);
  });

  it('supersedes miss still pins and reports the miss', async () => {
    const res = await pinToProject({
      text: 'switch to doubling backoff', slug: 'test-slug', section: 'decisions', brainDir: dir,
      supersedes: 'no such earlier decision',
    });
    expect(res.ok).toBe(true);
    expect(res.reason).toBe('supersedes target not found');
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toContain('switch to doubling backoff');
  });

  it('supersedes never re-marks an already-superseded bullet', async () => {
    await pinToProject({ text: 'cap is two hundred', slug: 'test-slug', section: 'decisions', brainDir: dir });
    await pinToProject({ text: 'cap is now five hundred', slug: 'test-slug', section: 'decisions', brainDir: dir, supersedes: 'two hundred' });
    const res = await pinToProject({ text: 'cap is now six hundred', slug: 'test-slug', section: 'decisions', brainDir: dir, supersedes: 'two hundred' });
    expect(res.ok).toBe(true);
    // the already-superseded bullet must not be double-prefixed
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).not.toMatch(/\[superseded\] \[superseded\]/);
    expect(res.reason).toBe('supersedes target not found');
  });

  it('dedupes within a section: same text twice yields one entry', async () => {
    const r1 = await pinToProject({ text: 'API rate limit', slug: 'test-slug', section: 'blockers', brainDir: dir });
    expect(r1.ok).toBe(true);
    expect(r1.reason).toBeUndefined();
    const r2 = await pinToProject({ text: 'API rate limit', slug: 'test-slug', section: 'blockers', brainDir: dir });
    expect(r2.ok).toBe(true);
    expect(r2.reason).toBe('already present');
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    const occurrences = content.split('\n').filter(l => l === '- [active] API rate limit');
    expect(occurrences.length).toBe(1);
  });
});
