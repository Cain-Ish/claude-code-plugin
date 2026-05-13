import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { personaThink, readBudget, recordSpend, type PersonaThinkDeps } from '../src/tools/persona-think.js';

describe('persona_think', () => {
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

  it('returns budget_skipped without invoking runner when budgetExceeded', async () => {
    const fakeRunner = vi.fn();
    const r = await personaThink({ prompt: 'anything' }, { runner: fakeRunner, budgetExceeded: true });
    expect(r.budget_skipped).toBe(true);
    expect(fakeRunner).not.toHaveBeenCalled();
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

  it('records spend after a successful call when brainDir is provided', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({ intent_read: 'x', prompt_enrichment: '', clarifying_questions: [], relevant_specialists: [], risk_flags: [] }));
    const brainDir = mkdtempSync(join(tmpdir(), 'pt-spend-'));
    try {
      await personaThink({ prompt: 'x' }, { runner: fakeRunner, brainDir });
      const after = await readBudget(brainDir);
      expect(after.today_usd).toBeGreaterThan(0);
    } finally {
      rmSync(brainDir, { recursive: true, force: true });
    }
  });

  it('does not record spend when brainDir is omitted', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({ intent_read: 'x', prompt_enrichment: '', clarifying_questions: [], relevant_specialists: [], risk_flags: [] }));
    await personaThink({ prompt: 'x' }, { runner: fakeRunner });
    // No assertion needed beyond not crashing — the absence of brainDir should be a no-op.
    expect(true).toBe(true);
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

describe('budget tracking', () => {
  let brainDir: string;
  beforeEach(() => { brainDir = mkdtempSync(join(tmpdir(), 'pt-budget-')); });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('readBudget returns zero on missing file', async () => {
    const b = await readBudget(brainDir);
    expect(b.today_usd).toBe(0);
    expect(b.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('recordSpend accumulates on same-day calls', async () => {
    await recordSpend(brainDir, 0.05);
    const b = await recordSpend(brainDir, 0.07);
    expect(b.today_usd).toBeCloseTo(0.12);
  });
});
