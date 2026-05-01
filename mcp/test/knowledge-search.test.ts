import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch } from '../src/tools/knowledge-search.js';

describe('knowledge_search v1', () => {
  let knowledgeDir: string;
  beforeEach(() => {
    knowledgeDir = mkdtempSync(join(tmpdir(), 'ks-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'concepts'), { recursive: true });
    mkdirSync(join(knowledgeDir, 'wiki', 'learnings'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'learnings', '2026-04-29-counting-pipeline.md'),
      `# Counting pipeline fallback gotcha\n\nDate: 2026-04-29\n\nUsing grep -c with || echo 0 corrupts...\n`,
      'utf-8'
    );
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'shell-patterns.md'),
      `# Shell patterns\n\nGeneral shell-script idioms.\n`,
      'utf-8'
    );
  });
  afterEach(() => { rmSync(knowledgeDir, { recursive: true, force: true }); });

  it('returns top candidates ranked by token overlap', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates[0].path).toMatch(/counting-pipeline\.md$/);
  });

  it('respects scope filter', async () => {
    const res = await knowledgeSearch({ query: 'shell', scope: 'concepts', knowledgeDir });
    expect(res.candidates.every(c => c.path.includes('/concepts/'))).toBe(true);
  });

  it('returns empty candidates on no match', async () => {
    const res = await knowledgeSearch({ query: 'unrelatedstring1234', knowledgeDir });
    expect(res.candidates).toEqual([]);
  });
});
