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
