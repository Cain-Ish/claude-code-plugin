import { describe, it, expect } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync, promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { scanCandidates, runScan, scanCap, isHighSignal, originGuard } from './raw-scan.js';
import { listItems } from './raw-inbox.js';

/** Build a temp repo with a known file set; returns its root. NOT a git repo (junk-filter only). */
async function repo(): Promise<string> {
  const root = await fs.mkdtemp(join(tmpdir(), 'scan-'));
  // Distinct body per file — captureItem dedups by content hash, so identical bodies
  // would collapse to one captured item and break the capture-count assertion.
  const w = async (rel: string, body = `# ${rel}\nunique content for ${rel}`) => {
    await fs.mkdir(join(root, rel, '..'), { recursive: true });
    await fs.writeFile(join(root, rel), body);
  };
  await w('README.md');                       // rule 1 (root)
  await w('docs/guide.md');                    // rule 2 (docs dir)
  await w('docs/adr/ADR-001.md');              // rule 2 (adr dir)
  await w('src/DESIGN.md');                    // rule 3 (basename)
  await w('src/components/notes.md');          // EXCLUDED: file named notes, not a notes/ dir
  await w('CHANGELOG.md');                      // EXCLUDED: low-signal denylist
  await w('docs/credentials.md');              // EXCLUDED: secret denylist
  await w('node_modules/pkg/README.md');       // EXCLUDED: junk dir
  return root;
}

async function brain(): Promise<{ brainDir: string; slug: string }> {
  const brainDir = await fs.mkdtemp(join(tmpdir(), 'scan-brain-'));
  const slug = 'demo';
  await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
  return { brainDir, slug };
}

function rels(root: string, paths: string[]): string[] {
  return paths.map(p => p.slice(root.length + 1).split('\\').join('/'));
}

describe('raw-scan', () => {
  it('curates high-signal docs and excludes notes/changelog/secret/junk', async () => {
    const root = await repo();
    const got = rels(root, await scanCandidates(root)).sort();
    expect(got).toEqual(['README.md', 'docs/adr/ADR-001.md', 'docs/guide.md', 'src/DESIGN.md']);
  });

  it('isHighSignal handles Windows backslash paths (cross-OS) — path.relative emits native sep', () => {
    expect(isHighSignal('docs\\adr\\ADR-001.md')).toBe(true);    // rule 2 (adr dir), backslashes
    expect(isHighSignal('src\\components\\notes.md')).toBe(false); // NOT root, NOT a notes/ dir
    expect(isHighSignal('config\\.env.md')).toBe(false);          // secret denylist (.env) must still fire
    expect(isHighSignal('README.md')).toBe(true);                 // root-level
  });

  it('excludes secret-named markdown docs whose secret token is not the final extension (.pem.md / .key.md)', () => {
    // A private key wrapped in markdown: `server.key.md` / `my.pem.md`. The denylist anchored
    // .pem$/.key$ to the FULL path, but every candidate already ends in .md — so the secret
    // token is never the final extension and the branch was structurally unreachable (leak).
    expect(isHighSignal('docs/my.pem.md')).toBe(false);           // .pem as an extension component
    expect(isHighSignal('docs/server.key.md')).toBe(false);       // .key as an extension component
    expect(isHighSignal('private.pem.markdown')).toBe(false);
    // controls — must NOT over-exclude legitimate docs that merely contain the substring key/pem:
    expect(isHighSignal('docs/api-keys.md')).toBe(true);          // "keys", not a ".key" extension
    expect(isHighSignal('docs/api-keys.markdown')).toBe(true);    // .markdown keep-side
    expect(isHighSignal('docs/keyboard-shortcuts.md')).toBe(true);
    expect(isHighSignal('docs/monkey.md')).toBe(true);            // contains "key" but not ".key"
    expect(isHighSignal('docs/keyx.md')).toBe(true);              // token must be dot-delimited (boundary)
    expect(isHighSignal('docs/pemx.md')).toBe(true);
  });

  it('excludes .env markdown docs (leading-dotfile and mid-path component) without over-matching "env" words', () => {
    expect(isHighSignal('docs/.envrc.md')).toBe(false);           // leading-dotfile family (.envrc) still caught
    expect(isHighSignal('docs/.env.local.md')).toBe(false);
    expect(isHighSignal('docs/config.env.md')).toBe(false);       // .env as a mid-path extension component (parity)
    expect(isHighSignal('docs/environment.md')).toBe(true);       // "env" but NOT a .env token — keep
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
    expect(r.overflow).toHaveLength(2);   // the over-cap paths are surfaced (not hidden) for preview
    expect(r.truncated).toBe(2);          // 4 high-signal, cap 2
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
    const r2 = await runScan(root, brainDir, slug, {});   // re-run: unchanged → all skipped
    expect(r2.captured).toBe(0);
    expect(r2.skipped).toBe(4);
    expect(await listItems(brainDir, slug)).toHaveLength(4);
  });
});

describe('originGuard', () => {
  it('passes when the resource slug cannot be derived', () => {
    expect(originGuard(undefined, 'b', false).ok).toBe(true);
  });
  it('passes when origin matches destination', () => {
    expect(originGuard('a', 'a', false).ok).toBe(true);
  });
  it('FAILS LOUD when origin and destination disagree and no override is set', () => {
    const r = originGuard('a', 'b', false);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain('a');
    expect(r.reason).toContain('b');
  });
  it('passes a mismatch when SB_ACTIVE_SLUG override is set', () => {
    expect(originGuard('a', 'b', true).ok).toBe(true);
  });
});

describe('runScan stamps origin', () => {
  it('writes the supplied origin onto captured items', async () => {
    const repo = mkdtempSync(join(tmpdir(), 'sb-scan-repo-'));
    writeFileSync(join(repo, 'README.md'), '# Title\n\nbody\n');
    const brain = mkdtempSync(join(tmpdir(), 'sb-scan-brain-'));
    await runScan(repo, brain, 'dest', { origin: 'resource' });
    const items = await listItems(brain, 'dest');
    expect(items.length).toBeGreaterThan(0);
    expect(items[0].origin).toBe('resource');
    rmSync(repo, { recursive: true, force: true });
    rmSync(brain, { recursive: true, force: true });
  });
});
