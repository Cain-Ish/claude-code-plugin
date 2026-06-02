import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeFetch } from './knowledge-fetch.js';

async function wiki(): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'kf-'));
  await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
  return dir;
}

describe("knowledge_fetch block tier (Phase 2)", () => {
  it("tier 'block' returns the ai-block shared intermediate, not the prose", async () => {
    const dir = await wiki();
    const block = ['<!-- ai:begin -->', 'claim: the claim', 'action: do it', '<!-- ai:end -->'].join('\n');
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'b.md'), `---\ntitle: B\ntype: learnings\n---\n${block}\n\n# B\nprose body here.`);
    const r = await knowledgeFetch({ slug: 'b', tier: 'block', knowledgeDir: dir });
    expect(r.tier).toBe('block');
    expect(r.text).toContain('claim: the claim');
    expect(r.text).not.toContain('prose body'); // block only, not the prose
  });
  it("tier 'block' falls back gracefully when the page has no block", async () => {
    const dir = await wiki();
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'n.md'), `---\ntitle: N\ntype: learnings\n---\n# N\n## Summary\nthe summary line.`);
    const r = await knowledgeFetch({ slug: 'n', tier: 'block', knowledgeDir: dir });
    expect(r.text).toBeTruthy(); // graceful — not empty
  });
});
