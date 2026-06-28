import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { episodicRead, buildEpisodicIndex } from './episodic-search.js';

const TAGS = String.fromCodePoint(0xE0041, 0xE0042); // invisible, decodes to "AB" for the model
const ZWSP = String.fromCodePoint(0x200B);
const INVIS = /[\u{E0000}-\u{E007F}\u{200B}]/u;

async function seedTranscript(): Promise<{ brainDir: string; file: string }> {
  const brainDir = await fs.mkdtemp(join(tmpdir(), 'epi-'));
  const dir = join(brainDir, 'transcripts');
  await fs.mkdir(dir, { recursive: true });
  const file = join(dir, 'sess1_alpha_2026-06-28.txt');
  const content = [
    '--- session-meta ---', 'session_id: sess1', 'project_slug: alpha', 'date: 2026-06-28', '---', '',
    'USER:', `please rate${TAGS}-limit${ZWSP} the api`, '',
  ].join('\n');
  await fs.writeFile(file, content);
  return { brainDir, file };
}

describe('episodic read path sanitization (P6b)', () => {
  it('episodicRead strips invisible/Tags-block chars from returned content', async () => {
    const { file } = await seedTranscript();
    const r = await episodicRead(file);
    expect(r.content).not.toMatch(INVIS);
    expect(r.content).toContain('rate-limit the api');
  });

  it('buildEpisodicIndex persists sanitized snippets', async () => {
    const { brainDir } = await seedTranscript();
    await buildEpisodicIndex(brainDir);
    const idx = await fs.readFile(join(brainDir, 'episodic-index.json'), 'utf-8');
    expect(idx).not.toMatch(INVIS);
    expect(idx).toContain('rate-limit'); // indexed, just cleaned
  });
});
