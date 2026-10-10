import { describe, it, expect, vi } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// Audit M9: a pipe() throw (OOM, corrupt model) was swallowed by a bare catch, so hybrid
// search silently degraded to BM25 for ever. The fallback stays; the cause is now logged once.
vi.mock('@huggingface/transformers', () => ({
  pipeline: async () => async () => { throw new Error('boom-onnx-run-failed'); },
}));

import { knowledgeSearch } from './knowledge-search.js';

describe('embedding failure', () => {
  it('falls back to BM25 and logs the cause once', async () => {
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
    process.env.BRAIN_DIR = mkdtempSync(join(tmpdir(), 'sb-ef-brain-'));
    const kd = mkdtempSync(join(tmpdir(), 'sb-ef-'));
    mkdirSync(join(kd, 'wiki', 'concepts'), { recursive: true });
    writeFileSync(join(kd, 'wiki', 'concepts', 'a.md'),
      `---\ntitle: "quartz gearbox"\ndescription: "quartz gearbox"\ntype: concepts\n---\n\n# quartz gearbox\n\n${'quartz gearbox calibration. '.repeat(6)}\n`);
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const r1 = await knowledgeSearch({ query: 'quartz gearbox', knowledgeDir: kd });
      await knowledgeSearch({ query: 'quartz gearbox', knowledgeDir: kd });
      expect(r1.candidates.length).toBeGreaterThan(0);
      const hits = err.mock.calls.filter(c => String(c[0]).includes('boom-onnx-run-failed'));
      expect(hits).toHaveLength(1);
    } finally {
      err.mockRestore();
      rmSync(kd, { recursive: true, force: true });
    }
  });
});
