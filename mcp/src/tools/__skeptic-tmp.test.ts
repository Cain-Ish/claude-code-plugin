import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { applyCandidates } from './consolidate-writer.js';

describe('skeptic probe: concepts/ endpoint', () => {
  let root = '';
  beforeEach(async () => { root = await fs.mkdtemp(join(tmpdir(), 'skeptic-')); });
  afterEach(async () => { await fs.rm(root, { recursive: true, force: true }); });

  it('exact slug in concepts/ resolves?', async () => {
    const staging = join(root, 'staging');
    await fs.mkdir(join(staging, 'wiki', 'concepts'), { recursive: true });
    await fs.mkdir(join(staging, 'wiki', 'entities'), { recursive: true });
    await fs.writeFile(join(staging, 'wiki', 'entities', 'widget.md'),
      '---\ntitle: widget\ntype: entities\nrelated: []\n---\n\n# widget\n');
    await fs.writeFile(join(staging, 'wiki', 'concepts', 'lethal-trifecta.md'),
      '---\ntitle: lethal trifecta\ntype: concepts\nrelated: []\n---\n\n# lethal trifecta\n');
    const r = await applyCandidates(staging, [
      { kind: 'relation', claim: 'x', from_hint: 'widget', to_hint: 'lethal-trifecta', rel: 'relates' },
      { kind: 'relation', claim: 'y', from_hint: 'widget', to_hint: 'lethal trifecta', rel: 'relates' },
    ], { dreamId: 'drm_x', date: '2026-01-01' });
    console.log('EDGES=', JSON.stringify(r.edges));
    console.log('SKIPPED=', JSON.stringify(r.skipped));
    expect({ edges: r.edges, skipped: r.skipped }).toBe('SHOW ME');
  });
});
