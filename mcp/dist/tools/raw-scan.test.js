import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { scanCandidates, runScan, scanCap } from './raw-scan.js';
import { listItems } from './raw-inbox.js';
/** Build a temp repo with a known file set; returns its root. NOT a git repo (junk-filter only). */
async function repo() {
    const root = await fs.mkdtemp(join(tmpdir(), 'scan-'));
    // Distinct body per file — captureItem dedups by content hash, so identical bodies
    // would collapse to one captured item and break the capture-count assertion.
    const w = async (rel, body = `# ${rel}\nunique content for ${rel}`) => {
        await fs.mkdir(join(root, rel, '..'), { recursive: true });
        await fs.writeFile(join(root, rel), body);
    };
    await w('README.md'); // rule 1 (root)
    await w('docs/guide.md'); // rule 2 (docs dir)
    await w('docs/adr/ADR-001.md'); // rule 2 (adr dir)
    await w('src/DESIGN.md'); // rule 3 (basename)
    await w('src/components/notes.md'); // EXCLUDED: file named notes, not a notes/ dir
    await w('CHANGELOG.md'); // EXCLUDED: low-signal denylist
    await w('docs/credentials.md'); // EXCLUDED: secret denylist
    await w('node_modules/pkg/README.md'); // EXCLUDED: junk dir
    return root;
}
async function brain() {
    const brainDir = await fs.mkdtemp(join(tmpdir(), 'scan-brain-'));
    const slug = 'demo';
    await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
    return { brainDir, slug };
}
function rels(root, paths) {
    return paths.map(p => p.slice(root.length + 1).split('\\').join('/'));
}
describe('raw-scan', () => {
    it('curates high-signal docs and excludes notes/changelog/secret/junk', async () => {
        const root = await repo();
        const got = rels(root, await scanCandidates(root)).sort();
        expect(got).toEqual(['README.md', 'docs/adr/ADR-001.md', 'docs/guide.md', 'src/DESIGN.md']);
    });
    it('scanCap reads SB_SCAN_MAX (default 50)', () => {
        delete process.env.SB_SCAN_MAX;
        expect(scanCap()).toBe(50);
        process.env.SB_SCAN_MAX = '2';
        expect(scanCap()).toBe(2);
        delete process.env.SB_SCAN_MAX;
    });
    it('dryRun previews (capped) and writes nothing', async () => {
        const root = await repo();
        const { brainDir, slug } = await brain();
        process.env.SB_SCAN_MAX = '2';
        const r = await runScan(root, brainDir, slug, { dryRun: true });
        delete process.env.SB_SCAN_MAX;
        expect(r.candidates).toHaveLength(2);
        expect(r.truncated).toBe(2); // 4 high-signal, cap 2
        expect(r.captured).toBe(0);
        expect(await listItems(brainDir, slug)).toHaveLength(0); // nothing written
    });
    it('captures survivors stamped captured_by: setup-scan, and dedups on re-run', async () => {
        const root = await repo();
        const { brainDir, slug } = await brain();
        const r1 = await runScan(root, brainDir, slug, {});
        expect(r1.captured).toBe(4);
        const items = await listItems(brainDir, slug);
        expect(items).toHaveLength(4);
        expect(items.every(i => i.captured_by === 'setup-scan')).toBe(true);
        const r2 = await runScan(root, brainDir, slug, {}); // re-run: unchanged → all skipped
        expect(r2.captured).toBe(0);
        expect(r2.skipped).toBe(4);
        expect(await listItems(brainDir, slug)).toHaveLength(4);
    });
});
//# sourceMappingURL=raw-scan.test.js.map