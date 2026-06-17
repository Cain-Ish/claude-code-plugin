import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeValidate } from './knowledge-validate.js';

// INDEPENDENT ORACLE = the filesystem itself (fs.access throws iff the file is
// gone). We never re-read the page through knowledgeValidate's own parser to
// 'confirm' deletion; we assert the on-disk FACT of presence/absence directly.
const exists = async (p: string) => fs.access(p).then(() => true, () => false);

// Mirror the MCP tool wrapper's default-resolution (server.ts: `autofix ?? false`).
// The library function itself takes opts verbatim, so we model the WRAPPER here.
const callAsTool = (dir: string, autofix?: boolean) =>
  knowledgeValidate(dir, { autofix: autofix ?? false });

async function fixtureWithEmptyPage() {
  const dir = await fs.mkdtemp(join(tmpdir(), 'kv-default-'));
  const wiki = join(dir, 'wiki', 'state');
  await fs.mkdir(wiki, { recursive: true });
  const empty = join(wiki, 'empty.md');
  await fs.writeFile(empty, '   \n');               // whitespace-only → empty_page (autofix: remove)
  return { dir, empty };
}

describe('knowledge_validate MCP default is non-destructive (Phase 3b)', () => {
  it('omitted autofix (tool default) does NOT delete an empty page', async () => {
    const { dir, empty } = await fixtureWithEmptyPage();
    expect(await exists(empty)).toBe(true);
    const res = await callAsTool(dir);                // no autofix arg → ?? false
    expect(res.fixed).toBe(0);
    expect(await exists(empty)).toBe(true);           // FILESYSTEM FACT: still there
    expect(res.issues.some(i => i.type === 'empty_page')).toBe(true); // still REPORTED
  });

  it('explicit autofix:true STILL deletes the empty page (opt-in path unbroken)', async () => {
    const { dir, empty } = await fixtureWithEmptyPage();
    const res = await callAsTool(dir, true);
    expect(res.fixed).toBeGreaterThanOrEqual(1);
    expect(await exists(empty)).toBe(false);          // FILESYSTEM FACT: removed
  });

  it('omitted autofix does NOT rewrite a frontmatter-less page (byte-identical)', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-default-fm-'));
    const wiki = join(dir, 'wiki', 'state');
    await fs.mkdir(wiki, { recursive: true });
    const page = join(wiki, 'nofm.md');
    const original = '# No Frontmatter\n\nbody text here\n';
    await fs.writeFile(page, original);
    const before = await fs.readFile(page, 'utf-8');
    const res = await callAsTool(dir);                // default
    const after = await fs.readFile(page, 'utf-8');
    expect(after).toBe(before);                       // ROUND-TRIP: untouched bytes
    expect(res.fixed).toBe(0);
    expect(res.issues.some(i => i.type === 'missing_frontmatter')).toBe(true);
  });

  it('explicit autofix:true STILL adds frontmatter to a frontmatter-less page', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-default-fm2-'));
    const wiki = join(dir, 'wiki', 'state');
    await fs.mkdir(wiki, { recursive: true });
    const page = join(wiki, 'nofm.md');
    await fs.writeFile(page, '# No Frontmatter\n\nbody\n');
    const res = await callAsTool(dir, true);
    const after = await fs.readFile(page, 'utf-8');
    expect(after.startsWith('---\n')).toBe(true);     // FILESYSTEM FACT: fm prepended
    expect(res.fixed).toBeGreaterThanOrEqual(1);
  });
});
