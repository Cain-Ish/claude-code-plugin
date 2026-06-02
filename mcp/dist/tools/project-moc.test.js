import { describe, it, expect } from 'vitest';
import { buildProjectMocs } from './project-moc.js';
const pages = [
    { slug: 'kiri-redesign', type: 'decisions', project: 'kiri', title: 'Kiri Redesign', description: 'root' },
    { slug: 'kiri-core-design', type: 'decisions', project: 'kiri', title: 'Kiri Core', description: 'core' },
    { slug: 'kiri-privilege-split', type: 'security', project: 'kiri', title: 'Kiri Priv Split', description: 'lpe' },
    { slug: 'bridge-a', type: 'decisions', project: 'cainish-bridge', title: 'Bridge A', description: '' },
    { slug: 'bridge-b', type: 'decisions', project: 'cainish-bridge', title: 'Bridge B', description: '' },
    { slug: 'lonely', type: 'concepts', project: 'solo', title: 'Solo', description: '' },
];
describe('buildProjectMocs', () => {
    it('emits one MOC per project with >= minMembers, grouped by type', () => {
        const mocs = buildProjectMocs(pages, { minMembers: 3 });
        expect([...mocs.keys()].sort()).toEqual(['kiri']); // cainish-bridge=2, solo=1 → gated out
        const k = mocs.get('kiri');
        expect(k).toContain('## decisions');
        expect(k).toContain('[[kiri-redesign]]');
        expect(k).toContain('## security');
        expect(k).toContain('[[kiri-privilege-split]]');
        // deterministic: members sorted by slug within a type group
        expect(k.indexOf('[[kiri-core-design]]')).toBeLessThan(k.indexOf('[[kiri-redesign]]'));
    });
    it('is deterministic — same input, byte-identical output', () => {
        expect(buildProjectMocs(pages, { minMembers: 3 }).get('kiri'))
            .toBe(buildProjectMocs(pages, { minMembers: 3 }).get('kiri'));
    });
    it('respects an empty/whitespace project as no membership', () => {
        const mocs = buildProjectMocs([{ slug: 'x', type: 'concepts', project: '', title: 'X', description: '' }], { minMembers: 1 });
        expect(mocs.size).toBe(0);
    });
});
//# sourceMappingURL=project-moc.test.js.map