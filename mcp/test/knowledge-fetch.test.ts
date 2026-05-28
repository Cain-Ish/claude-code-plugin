import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeFetch } from '../src/tools/knowledge-fetch.js';
import { estimateTokens } from '../src/tools/egress-budget.js';

describe('knowledge_fetch', () => {
  let knowledgeDir: string;
  beforeEach(() => {
    knowledgeDir = mkdtempSync(join(tmpdir(), 'kf-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'concepts'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'widget.md'),
      `---\ntitle: "Widget"\ndescription: "A widget is a small gizmo"\n---\n\n# Widget\n\nIntro para.\n\n## Design\n\nDesign details here.\n\n## Summary\n\nWidgets are small gizmos used for X.\n`,
      'utf-8'
    );
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'nosum.md'),
      `---\ntitle: "NoSum"\ndescription: "Page without a summary"\n---\n\n# NoSum\n\n## Alpha\n\ntext\n`,
      'utf-8'
    );
  });
  afterEach(() => { rmSync(knowledgeDir, { recursive: true, force: true }); });

  it('gist tier returns the frontmatter description + pointer', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'gist', knowledgeDir });
    expect(r.tier).toBe('gist');
    expect(r.text).toBe('A widget is a small gizmo');
    expect(r.path).toMatch(/widget\.md$/);
    expect(r.pointer).toContain('widget');
  });

  it('skeleton tier returns description + headings', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'skeleton', knowledgeDir });
    expect(r.text).toContain('A widget is a small gizmo');
    expect(r.text).toContain('## Design');
    expect(r.text).toContain('## Summary');
    expect(r.text).not.toContain('Design details here');
  });

  it('summary tier returns the ## Summary section when present', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'summary', knowledgeDir });
    expect(r.text).toContain('Widgets are small gizmos used for X');
  });

  it('summary tier falls back to skeleton + note when no ## Summary exists', async () => {
    const r = await knowledgeFetch({ slug: 'nosum', tier: 'summary', knowledgeDir });
    expect(r.text).toContain('## Alpha');
    expect(r.text.toLowerCase()).toContain('no summary');
  });

  it('full tier returns the body and stays within the egress budget', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'full', knowledgeDir });
    expect(r.text).toContain('Design details here');
    expect(estimateTokens(r.text)).toBeLessThanOrEqual(2000);
  });

  it('returns path=null and a helpful message for an unknown slug', async () => {
    const r = await knowledgeFetch({ slug: 'does-not-exist', tier: 'gist', knowledgeDir });
    expect(r.path).toBeNull();
    expect(r.text.toLowerCase()).toContain('not found');
  });

  it('resolves duplicate slugs deterministically (lexicographically-first path)', async () => {
    mkdirSync(join(knowledgeDir, 'wiki', 'decisions'), { recursive: true });
    writeFileSync(join(knowledgeDir, 'wiki', 'concepts', 'dup.md'), `---\ndescription: "concepts dup"\n---\n# dup\n`, 'utf-8');
    writeFileSync(join(knowledgeDir, 'wiki', 'decisions', 'dup.md'), `---\ndescription: "decisions dup"\n---\n# dup\n`, 'utf-8');
    const a = await knowledgeFetch({ slug: 'dup', tier: 'gist', knowledgeDir });
    const b = await knowledgeFetch({ slug: 'dup', tier: 'gist', knowledgeDir });
    expect(a.path).toBe(b.path);                  // stable across calls
    expect(a.path).toMatch(/concepts[/\\]dup\.md$/); // 'concepts' sorts before 'decisions'
  });

  it('rejects glob metacharacters in the slug at validation', async () => {
    // Post-G-MCP-1 (path-guard validateSlug): slugs are constrained to
    // [a-zA-Z0-9._-]. A slug containing '*' is rejected at validation
    // before any filesystem lookup — stricter than the previous
    // escape-and-not-found path. 'widget' still exists; 'wi*get' is denied.
    const r = await knowledgeFetch({ slug: 'wi*get', tier: 'gist', knowledgeDir });
    expect(r.path).toBeNull();
    expect(r.text.toLowerCase()).toContain('invalid slug');
  });
});
