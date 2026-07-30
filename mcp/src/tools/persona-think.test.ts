import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { personaThink } from './persona-think.js';

describe('persona_think', () => {
  // advisorModel() now resolves per call and reads $BRAIN_DIR/model-availability.json.
  // Without pinning BRAIN_DIR, these tests would read the developer's real cache file and
  // become environment-dependent — point it at a fresh, empty temp dir instead.
  let dir: string;
  const saved = { ...process.env };
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'sb-persona-think-'));
    process.env.BRAIN_DIR = dir;
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    process.env = { ...saved };
  });

  it('returns structured brief on a substantive prompt', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({
      intent_read: 'user wants to build login',
      prompt_enrichment: 'consider adding rate limiting and password complexity rules',
      clarifying_questions: ['OAuth or password-based?'],
      relevant_specialists: ['frontend-developer'],
      risk_flags: ['no rate limiting in current draft'],
    }));
    const r = await personaThink({ prompt: 'build a login form' }, { runner: fakeRunner });
    expect(r.intent_read).toContain('login');
    expect(r.clarifying_questions.length).toBe(1);
    expect(r.relevant_specialists).toContain('frontend-developer');
    expect(r.error).toBeUndefined();
  });

  it('returns error field on runner failure', async () => {
    const fakeRunner = vi.fn().mockRejectedValue(new Error('claude -p failed'));
    const r = await personaThink({ prompt: 'x' }, { runner: fakeRunner });
    expect(r.error).toBeDefined();
    expect(r.intent_read).toBe('');
  });

  it('returns error when runner output is not parseable JSON', async () => {
    const fakeRunner = vi.fn().mockResolvedValue('this is not JSON at all');
    const r = await personaThink({ prompt: 'x' }, { runner: fakeRunner });
    expect(r.error).toBe('no JSON in response');
  });

  it('caps clarifying_questions at 2 even when runner emits more', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({
      intent_read: 'x',
      prompt_enrichment: '',
      clarifying_questions: ['q1', 'q2', 'q3', 'q4'],
      relevant_specialists: [],
      risk_flags: [],
    }));
    const r = await personaThink({ prompt: 'x' }, { runner: fakeRunner });
    expect(r.clarifying_questions).toEqual(['q1', 'q2']);
  });

  it('passes context_hints to the runner', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({ ...{ intent_read: 'x', prompt_enrichment: '', clarifying_questions: [], relevant_specialists: [], risk_flags: [] } }));
    await personaThink({ prompt: 'build it', context_hints: ['stack: react', 'project: foo'] }, { runner: fakeRunner });
    const [, userArg] = fakeRunner.mock.calls[0];
    expect(userArg).toContain('Context hints');
    expect(userArg).toContain('stack: react');
    expect(userArg).toContain('build it');
  });
});
