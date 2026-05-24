import { describe, it, expect } from 'vitest';
import { extractGist, extractHeadings, hashContent } from '../src/tools/doc-sources.js';

describe('extractGist', () => {
  it('prefers the H1 heading', () => {
    expect(extractGist('---\ntitle: "FM"\n---\n# The H1\n\nbody')).toBe('The H1');
  });
  it('falls back to frontmatter title when no H1', () => {
    expect(extractGist('---\ntitle: "FM title"\n---\n\n## Sub\n')).toBe('FM title');
  });
  it('falls back to first non-empty line when neither', () => {
    expect(extractGist('\n\nFirst real line\nsecond')).toBe('First real line');
  });
});

describe('extractHeadings', () => {
  it('returns H2/H3 headings, not H1', () => {
    expect(extractHeadings('# Title\n## A\ntext\n### B\n#### C')).toEqual(['## A', '### B']);
  });
});

describe('hashContent', () => {
  it('is stable and content-sensitive', () => {
    expect(hashContent('abc')).toBe(hashContent('abc'));
    expect(hashContent('abc')).not.toBe(hashContent('abd'));
    expect(hashContent('abc')).toMatch(/^[0-9a-f]{64}$/);
  });
});
