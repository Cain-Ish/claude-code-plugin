import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { addFrontmatter } from './knowledge-validate.js';
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
});
//# sourceMappingURL=knowledge-validate.test.js.map