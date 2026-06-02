import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { addFrontmatter, knowledgeValidate } from './knowledge-validate.js';
describe('addFrontmatter category typing', () => {
    it('types a frontmatter-less page under wiki/themes/ as type: themes', async () => {
        const dir = await fs.mkdtemp(join(tmpdir(), 'kv-themes-'));
        const wiki = join(dir, 'wiki');
        const f = join(wiki, 'themes', 'architecture.md');
        await fs.mkdir(join(wiki, 'themes'), { recursive: true });
        await fs.writeFile(f, '# Architecture\n\nbody\n');
        await addFrontmatter(f, wiki);
        const out = await fs.readFile(f, 'utf-8');
        expect(out).toMatch(/^type: themes$/m); // not the 'state' fallback
    });
    it('still falls back to state for an unknown category', async () => {
        const dir = await fs.mkdtemp(join(tmpdir(), 'kv-unk-'));
        const wiki = join(dir, 'wiki');
        const f = join(wiki, 'whatever', 'x.md');
        await fs.mkdir(join(wiki, 'whatever'), { recursive: true });
        await fs.writeFile(f, '# X\n\nbody\n');
        await addFrontmatter(f, wiki);
        expect(await fs.readFile(f, 'utf-8')).toMatch(/^type: state$/m);
    });
    it('does NOT flag a generated project MOC sharing a slug with a real page as duplicate_slug (#3)', async () => {
        const dir = await fs.mkdtemp(join(tmpdir(), 'kv-collide-'));
        const wiki = join(dir, 'wiki');
        await fs.mkdir(join(wiki, 'decisions'), { recursive: true });
        await fs.mkdir(join(wiki, 'projects'), { recursive: true });
        // a real content page AND a project MOC, both basename "architecture-v1"
        await fs.writeFile(join(wiki, 'decisions', 'architecture-v1.md'), '---\ntitle: Arch\ntype: decisions\n---\n# Arch\n');
        await fs.writeFile(join(wiki, 'projects', 'architecture-v1.md'), '---\ntitle: architecture-v1\ntype: projects\ngenerated: true\ngraph: exclude\n---\n# moc\n');
        const res = await knowledgeValidate(dir, { autofix: false });
        expect(res.issues.find(i => i.type === 'duplicate_slug' && /architecture-v1/.test(i.message))).toBeUndefined();
    });
    it('does NOT flag a valid [[target|alias]] related link as broken (alias split)', async () => {
        const dir = await fs.mkdtemp(join(tmpdir(), 'kv-alias-'));
        const wiki = join(dir, 'wiki');
        await fs.mkdir(join(wiki, 'security'), { recursive: true });
        await fs.mkdir(join(wiki, 'decisions'), { recursive: true });
        await fs.writeFile(join(wiki, 'security', 'real-target.md'), '---\ntitle: T\ntype: security\n---\n# T\n');
        await fs.writeFile(join(wiki, 'decisions', 'src.md'), '---\ntitle: S\ntype: decisions\nrelated: [[real-target|nice display]]\n---\n# S\n');
        const res = await knowledgeValidate(dir, { autofix: false });
        expect(res.issues.find(i => i.type === 'broken_link' && /real-target/.test(i.message))).toBeUndefined();
    });
});
//# sourceMappingURL=knowledge-validate.test.js.map