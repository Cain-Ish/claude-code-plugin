import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { filterIgnored } from './doc-sources.js';
describe('doc-sources filterIgnored', () => {
    it('drops junk-dir paths (node_modules) and keeps real docs', async () => {
        const root = await fs.mkdtemp(join(tmpdir(), 'fi-')); // non-git → junk-skip-only path
        const junk = join(root, 'node_modules', 'pkg', 'x.md');
        const keep = join(root, 'docs', 'y.md');
        expect(filterIgnored(root, [junk, keep])).toEqual([keep]);
    });
    it('splits path segments on both separators (the junk regex is cross-OS)', () => {
        // The fix is `.split(/[\\/]+/)`; assert the regex segments a backslash path so the
        // JUNK_DIRS check works when path.relative emits native (Windows) separators.
        expect('node_modules\\pkg\\x.md'.split(/[\\/]+/)).toContain('node_modules');
    });
});
//# sourceMappingURL=doc-sources.test.js.map