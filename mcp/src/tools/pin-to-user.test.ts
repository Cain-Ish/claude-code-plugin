import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pinToUser } from './pin-to-user.js';

describe('pin_to_user', () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'pin-test-')); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it('appends a line to USER.md', async () => {
    writeFileSync(join(dir, 'USER.md'), '# USER\n## Preferences\n', 'utf-8');
    const res = await pinToUser({ text: 'prefer terse responses', brainDir: dir });
    expect(res.ok).toBe(true);
    expect(res.line_added).toMatch(/prefer terse responses/);
    expect(readFileSync(join(dir, 'USER.md'), 'utf-8')).toContain('prefer terse responses');
  });

  it('creates USER.md with header if it does not exist', async () => {
    const res = await pinToUser({ text: 'first pin', brainDir: dir });
    expect(res.ok).toBe(true);
    expect(readFileSync(join(dir, 'USER.md'), 'utf-8')).toMatch(/^# USER/m);
  });

  // INVERTED 2026-08-23 (LC-07). The old oracle seeded 15 lines of PROSE and expected a refusal —
  // i.e. it locked in the defect: a real operator's USER.md (About / Intent sections, 23 non-blank
  // lines, ZERO pins) refused every pin_to_user call and every auto-graduated persona signal,
  // silently, for months. The cap counts PIN LINES only.
  it('a hand-written USER.md with many prose lines but no pins ACCEPTS a pin (the live-file case)', async () => {
    const prose = ['# USER', '', '## About me', 'senior engineer, maintains this plugin.', 'builds a sibling app.',
      '## Communication style', 'terse, evidence first.', '## Working preferences', 'a', 'b', 'c', 'd', 'e', 'f',
      '## How to engage me', 'push back with measurements.', '## Intent', 'make the plugin state of the art.'].join('\n') + '\n';
    expect(prose.split('\n').filter(Boolean).length).toBeGreaterThan(15);   // the old cap would refuse this
    writeFileSync(join(dir, 'USER.md'), prose, 'utf-8');
    const res = await pinToUser({ text: 'prefers tabs over spaces', brainDir: dir });
    expect(res.ok).toBe(true);
    const out = readFileSync(join(dir, 'USER.md'), 'utf-8');
    expect(out).toContain('## Pinned');
    expect(out).toMatch(/## Pinned\n- \[\d{4}-\d{2}-\d{2}\] prefers tabs over spaces/);
    expect(out).toContain('make the plugin state of the art.');   // hand-written sections untouched
  });

  it('rejects the 16th PIN line, counting only "- [date] …" lines', async () => {
    const pins = Array.from({ length: 15 }, (_, i) => `- [2026-01-0${(i % 9) + 1}] pin ${i}`).join('\n');
    writeFileSync(join(dir, 'USER.md'), `# USER\n\n## Pinned\n${pins}\n`, 'utf-8');
    const res = await pinToUser({ text: 'one too many', brainDir: dir });
    expect(res.ok).toBe(false);
    expect(res.reason).toMatch(/15 pinned lines/);
  });

  it('inserts new pins under ## Pinned after the last existing pin, not at EOF', async () => {
    writeFileSync(join(dir, 'USER.md'), '# USER\n\n## Pinned\n- [2026-01-01] first\n\n## Intent\nship it.\n', 'utf-8');
    await pinToUser({ text: 'second', brainDir: dir });
    const out = readFileSync(join(dir, 'USER.md'), 'utf-8');
    expect(out.indexOf('second')).toBeGreaterThan(out.indexOf('first'));
    expect(out.indexOf('second')).toBeLessThan(out.indexOf('## Intent'));
  });

  it('dedupes: writing the same text twice keeps only one line', async () => {
    writeFileSync(join(dir, 'USER.md'), '# USER\n## Preferences\n', 'utf-8');
    const r1 = await pinToUser({ text: 'prefer terse responses', brainDir: dir });
    expect(r1.ok).toBe(true);
    expect(r1.reason).toBeUndefined();
    const r2 = await pinToUser({ text: 'prefer terse responses', brainDir: dir });
    expect(r2.ok).toBe(true);
    expect(r2.reason).toBe('already present');
    const content = readFileSync(join(dir, 'USER.md'), 'utf-8');
    const occurrences = content.split('\n').filter(l => l.includes('prefer terse responses'));
    expect(occurrences.length).toBe(1);
    // The line returned on the duplicate call must match the surviving file line.
    expect(r2.line_added).toBe(occurrences[0]);
  });
});
