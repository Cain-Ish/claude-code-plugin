import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { personaThink, readBudget, recordSpend, readOpusLedger, recordOpusLedger, type PersonaThinkDeps } from '../src/tools/persona-think.js';

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

// === Contract A: shared Opus ledger (Task 9) ===

describe('shared Opus ledger (Contract A)', () => {
  let brainDir: string;
  beforeEach(() => { brainDir = mkdtempSync(join(tmpdir(), 'pt-ledger-')); });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('readOpusLedger returns zero spend on missing ledger file', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    const l = await readOpusLedger(ledgerPath);
    expect(l.opus_cost_usd).toBe(0);
    expect(l.opus_calls).toBe(0);
    expect(l.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('recordOpusLedger increases opus_cost_usd after a call', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    // inputTokens=200000, outputTokens=4000 => cost = 200000/1e6*5 + 4000/1e6*25 = 1.0 + 0.1 = 1.1
    await recordOpusLedger(ledgerPath, 200000, 4000);
    const after = await readOpusLedger(ledgerPath);
    expect(after.opus_cost_usd).toBeCloseTo(1.1, 4);
    expect(after.opus_calls).toBe(1);
  });

  it('recordOpusLedger accumulates across two calls', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    await recordOpusLedger(ledgerPath, 100000, 2000); // 0.5 + 0.05 = 0.55
    await recordOpusLedger(ledgerPath, 100000, 2000); // +0.55
    const after = await readOpusLedger(ledgerPath);
    expect(after.opus_cost_usd).toBeCloseTo(1.1, 4);
    expect(after.opus_calls).toBe(2);
  });

  it('recordOpusLedger resets when ledger has stale date', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    // Write a stale ledger with yesterday
    writeFileSync(ledgerPath, JSON.stringify({
      date: '2000-01-01',
      opus_cost_usd: 99.0,
      opus_calls: 100,
      cap_usd: 5.0,
    }));
    await recordOpusLedger(ledgerPath, 10000, 500); // should reset first, then add this cost
    const after = await readOpusLedger(ledgerPath);
    // cost = 10000/1e6*5 + 500/1e6*25 = 0.05 + 0.0125 = 0.0625
    expect(after.opus_cost_usd).toBeCloseTo(0.0625, 4);
    expect(after.opus_calls).toBe(1); // reset + one new call
  });

  it('personaThink records cost to Opus ledger via COST_ROUTER_LEDGER env', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({
      intent_read: 'test',
      prompt_enrichment: '',
      clarifying_questions: [],
      relevant_specialists: [],
      risk_flags: [],
    }));
    // We pass inputTokens/outputTokens via the runner result — for test purposes
    // the runner must return usage info; we inject it via tokenUsage override
    await personaThink(
      { prompt: 'x' },
      { runner: fakeRunner, ledgerPath, inputTokens: 200000, outputTokens: 4000 },
    );
    const after = await readOpusLedger(ledgerPath);
    expect(after.opus_cost_usd).toBeGreaterThan(0);
    expect(after.opus_calls).toBe(1);
  });

  it('personaThink returns opus_budget_exhausted result when daily cap exceeded', async () => {
    const ledgerPath = join(brainDir, 'opus-budget.json');
    // Write a ledger that is already at/above cap
    writeFileSync(ledgerPath, JSON.stringify({
      date: new Date().toISOString().slice(0, 10),
      opus_cost_usd: 10.0,
      opus_calls: 50,
      cap_usd: 5.0,
    }));
    const fakeRunner = vi.fn();
    const r = await personaThink(
      { prompt: 'over-cap test' },
      { runner: fakeRunner, ledgerPath, opusCap: 5.0 },
    );
    expect(fakeRunner).not.toHaveBeenCalled();
    expect(r.budget_skipped).toBe(true);
    expect(r.error).toMatch(/budget|cap/i);
  });

  it('personaThink is a no-op (does not fail) when ledger dir is not writable', async () => {
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({
      intent_read: 'x', prompt_enrichment: '', clarifying_questions: [], relevant_specialists: [], risk_flags: [],
    }));
    // Pass a ledger path under a non-existent dir that cannot be created
    const result = await personaThink(
      { prompt: 'x' },
      { runner: fakeRunner, ledgerPath: '/nonexistent_dir_abc123/opus-budget.json' },
    );
    // Should succeed normally — recording failed but that's a graceful no-op
    expect(result.error).toBeUndefined();
    expect(result.intent_read).toBe('x');
  });
});
