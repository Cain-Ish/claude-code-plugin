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
    const norm = (p: string) => p.replace(/\\/g, '/');
    expect(res.candidates.every(c => norm(c.path).includes('/concepts/'))).toBe(true);
  });

  it('returns empty candidates on no match', async () => {
    const res = await knowledgeSearch({ query: 'unrelatedstring1234', knowledgeDir });
    expect(res.candidates).toEqual([]);
  });

  it('labels each candidate with an estimated token count', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    for (const c of res.candidates) {
      expect(typeof c.tokens).toBe('number');
      expect(c.tokens).toBeGreaterThan(0);
    }
  });

  it('returns the curated description as the gist, not a raw frontmatter chop', async () => {
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'gist-page.md'),
      `---\ntitle: "Gist page"\ndescription: "One-line curated gist about widgets"\n---\n\n# Gist page\n\nBody about widgets and gizmos.\n`,
      'utf-8'
    );
    const res = await knowledgeSearch({ query: 'widgets gizmos gist', knowledgeDir });
    const hit = res.candidates.find(c => c.path.endsWith('gist-page.md'));
    expect(hit).toBeDefined();
    expect(hit!.description).toBe('One-line curated gist about widgets');
    expect(hit as any).not.toHaveProperty('first_lines');
  });

  it('surfaces an active-project local doc as a local-doc candidate', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain-'));
    mkdirSync(join(brainDir, 'projects', 'proj'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'proj', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'proj',
      entries: [{ id: 'abc123', path: '/abs/docs/deploy-runbook.md', rel: 'docs/deploy-runbook.md',
        gist: 'Deploy runbook for the cluster', headings: ['## Steps', '## Rollback'],
        hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 1200 }],
    }));
    const res = await knowledgeSearch({ query: 'deploy runbook cluster', knowledgeDir, brainDir, projectSlug: 'proj' });
    const hit = res.candidates.find(c => c.path === '/abs/docs/deploy-runbook.md');
    expect(hit).toBeDefined();
    expect(hit!.source).toBe('local-doc');
    expect(hit!.description).toBe('Deploy runbook for the cluster');
    expect(hit!.tokens).toBe(Math.ceil(1200 / 4));
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('does not leak another project\'s docs and wiki results carry source:wiki', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain2-'));
    mkdirSync(join(brainDir, 'projects', 'other'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'other', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'other',
      entries: [{ id: 'x', path: '/abs/secret.md', rel: 'secret.md', gist: 'counting pipeline grep secret',
        headings: [], hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 100 }],
    }));
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir, brainDir, projectSlug: 'proj' });
    expect(res.candidates.some(c => c.path === '/abs/secret.md')).toBe(false);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('is unchanged (wiki-only) when no brainDir/projectSlug given', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
  });
});
