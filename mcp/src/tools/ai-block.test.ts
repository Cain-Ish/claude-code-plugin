import { describe, it, expect } from 'vitest';
import { parseAiBlock, stripAiBlock, validateAiBlock, AI_BLOCK_SCHEMAS } from './ai-block.js';

const page = [
  '---', 'title: awk', 'type: learnings', '---',
  "<!-- ai:begin (schema'd, machine-first) -->",
  'claim: never interpolate shell vars into awk',
  'trigger: writing awk in a .sh',
  'action: pass via -v + numeric coercion',
  'scope: mawk (Pi default)',
  '<!-- ai:end -->', '', '## Notes', 'mawk errors on empty interpolation. Period.',
].join('\n');

describe('ai-block', () => {
  it('parses the flat key:value block into an object', () => {
    const b = parseAiBlock(page)!;
    expect(b.claim).toBe('never interpolate shell vars into awk');
    expect(b.action).toBe('pass via -v + numeric coercion');
  });
  it('returns null when there is no block', () => {
    expect(parseAiBlock('---\ntitle: x\n---\n# x\nno block here')).toBeNull();
  });
  it('strips the block (for length/first-sentence counts)', () => {
    const s = stripAiBlock(page);
    expect(s).not.toContain('ai:begin');
    expect(s).not.toContain('claim:');
    expect(s).toContain('## Notes');
  });
  it('validateAiBlock reports missing REQUIRED fields for the type', () => {
    expect(validateAiBlock('learnings', { claim: 'x' })).toEqual(['action']);
    expect(validateAiBlock('learnings', { claim: 'x', action: 'y' })).toEqual([]);
    expect(validateAiBlock('unknown-type', { foo: 'bar' })).toEqual([]);
  });
  it('has schemas for the six structured types', () => {
    for (const t of ['learnings', 'decisions', 'entities', 'issues', 'concepts', 'security'])
      expect(AI_BLOCK_SCHEMAS[t].required.length).toBeGreaterThan(0);
  });
  it('folds a continuation line into the previous field value', () => {
    const md = ['<!-- ai:begin -->', 'claim: line one', '  continued', 'action: do it', '<!-- ai:end -->'].join('\n');
    expect(parseAiBlock(md)!.claim).toBe('line one continued');
  });
});
