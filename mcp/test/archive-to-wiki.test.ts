import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { archiveToWiki } from '../src/tools/archive-to-wiki.js';

const tpl = `# PROJECT: test
## Open blockers
- [resolved] flaky test in module X
- [active] still working on Y
`;

describe('archive_to_wiki', () => {
  let brainDir: string, knowledgeDir: string;
  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'arch-b-'));
    knowledgeDir = mkdtempSync(join(tmpdir(), 'arch-k-'));
    mkdirSync(join(brainDir, 'projects', 'test-slug'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'test-slug', 'PROJECT.md'), tpl, 'utf-8');
  });
  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    rmSync(knowledgeDir, { recursive: true, force: true });
  });

  it('moves resolved blocker to wiki/issues/<slug>/ with back-ref', async () => {
    const res = await archiveToWiki({
      slug: 'test-slug', sourceSection: 'blockers',
      entryText: 'flaky test in module X', targetCategory: 'issues',
      brainDir, knowledgeDir,
    });
    expect(res.ok).toBe(true);
    expect(existsSync(res.archived_path)).toBe(true);
    const content = readFileSync(join(brainDir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/→ wiki\/issues\/test-slug\//);
    expect(content).not.toContain('[resolved] flaky test in module X');
    expect(content).toContain('[active] still working on Y');
  });
});
