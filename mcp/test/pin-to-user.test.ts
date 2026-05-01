import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pinToUser } from '../src/tools/pin-to-user.js';

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

  it('rejects writes that would push USER.md over 15 lines', async () => {
    const lines = Array.from({ length: 15 }, (_, i) => `line ${i}`).join('\n');
    writeFileSync(join(dir, 'USER.md'), `# USER\n${lines}`, 'utf-8');
    const res = await pinToUser({ text: 'one too many', brainDir: dir });
    expect(res.ok).toBe(false);
  });
});
