import { describe, it, expect } from 'vitest';
import { parseAiBlock, stripAiBlock, validateAiBlock, renderAiBlock, AI_BLOCK_SCHEMAS } from './ai-block.js';
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
        const b = parseAiBlock(page);
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
    it('treats an UNTERMINATED ai:begin (no ai:end) as NOT a block (parse null, strip no-op)', () => {
        const md = ['---', 'title: x', '---', '<!-- ai:begin -->', 'claim: c', '', '# real prose continues forever'].join('\n');
        expect(parseAiBlock(md)).toBeNull();
        expect(stripAiBlock(md)).toBe(md); // must not eat the rest of the page
    });
    it('keeps the begin-marker annotation on its own line (a stray > in the tail is fine)', () => {
        const md = ['<!-- ai:begin (note: A > B) -->', 'claim: kept', 'action: a', '<!-- ai:end -->'].join('\n');
        expect(parseAiBlock(md).claim).toBe('kept');
    });
    it('folds a continuation line into the previous field value', () => {
        const md = ['<!-- ai:begin -->', 'claim: line one', '  continued', 'action: do it', '<!-- ai:end -->'].join('\n');
        expect(parseAiBlock(md).claim).toBe('line one continued');
    });
});
describe('renderAiBlock', () => {
    it('renders schema-ordered fields in markers; drops unknown + empty fields', () => {
        const out = renderAiBlock('learnings', { action: 'do it', claim: 'the claim', bogus: 'x', scope: '' });
        expect(out).toMatch(/^<!-- ai:begin/);
        expect(out.trimEnd()).toMatch(/<!-- ai:end -->$/);
        expect(out.indexOf('claim: the claim')).toBeLessThan(out.indexOf('action: do it')); // schema order
        expect(out).not.toContain('bogus'); // closed vocabulary
        expect(out).not.toContain('scope:'); // empty field dropped
    });
    it('round-trips through parseAiBlock', () => {
        const block = { claim: 'c', action: 'a' };
        expect(parseAiBlock(renderAiBlock('learnings', block))).toMatchObject(block);
    });
    it('returns empty string when no schema field has a value', () => {
        expect(renderAiBlock('learnings', { bogus: 'x' })).toBe('');
    });
});
//# sourceMappingURL=ai-block.test.js.map