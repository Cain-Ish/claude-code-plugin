import { describe, it, expect, afterEach } from 'vitest';
import {
  estimateTokens,
  egressBudgetTokens,
  DEFAULT_EGRESS_BUDGET_TOKENS,
  capText,
  capList,
} from '../src/tools/egress-budget.js';

describe('estimateTokens', () => {
  it('uses the chars/4 heuristic, rounding up', () => {
    expect(estimateTokens('')).toBe(0);
    expect(estimateTokens('abcd')).toBe(1);
    expect(estimateTokens('abcde')).toBe(2);
  });
});

describe('egressBudgetTokens', () => {
  afterEach(() => { delete process.env.SB_EGRESS_BUDGET_TOKENS; });

  it('falls back to the default when env is unset', () => {
    delete process.env.SB_EGRESS_BUDGET_TOKENS;
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
  });

  it('reads a positive integer from env', () => {
    process.env.SB_EGRESS_BUDGET_TOKENS = '500';
    expect(egressBudgetTokens()).toBe(500);
  });

  it('ignores non-positive / non-numeric env values', () => {
    process.env.SB_EGRESS_BUDGET_TOKENS = 'nope';
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
    process.env.SB_EGRESS_BUDGET_TOKENS = '0';
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
  });
});

describe('capText', () => {
  it('returns text unchanged when within budget (never expands)', () => {
    const r = capText('short text', 100);
    expect(r.truncated).toBe(false);
    expect(r.text).toBe('short text');
    expect(r.omittedTokens).toBe(0);
  });

  it('truncates oversized text and stays within budget', () => {
    const text = 'x'.repeat(1000); // ~250 tokens
    const r = capText(text, 50);
    expect(r.truncated).toBe(true);
    expect(estimateTokens(r.text)).toBeLessThanOrEqual(50);
    expect(r.text).toContain('truncated');
    expect(r.omittedTokens).toBeGreaterThan(0);
  });

  it('includes the pointer in the marker when provided', () => {
    const r = capText('y'.repeat(1000), 50, 'knowledge_fetch(foo, full)');
    expect(r.text).toContain('knowledge_fetch(foo, full)');
  });

  it('never splits a multi-byte grapheme cluster', () => {
    const text = '👨‍👩‍👧‍👦'.repeat(100); // ZWJ family emoji
    const r = capText(text, 8);
    const seg = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
    const kept = r.text.split('\n')[0];
    expect(kept.length).toBeGreaterThan(0);
    expect([...seg.segment(kept)].every(s => s.segment === '👨‍👩‍👧‍👦' || s.segment === '')).toBe(true);
  });

  it('honors the ceiling even when the budget is smaller than the marker', () => {
    const r1 = capText('x'.repeat(1000), 1);
    expect(r1.truncated).toBe(true);
    expect(estimateTokens(r1.text)).toBeLessThanOrEqual(1);
    const r2 = capText('x'.repeat(1000), 2);
    expect(estimateTokens(r2.text)).toBeLessThanOrEqual(2);
  });
});

describe('capList', () => {
  const render = (s: string) => s;

  it('keeps all items when within budget', () => {
    const r = capList(['a', 'b', 'c'], render, 1000, 'drill down');
    expect(r.kept).toEqual(['a', 'b', 'c']);
    expect(r.omitted).toBe(0);
    expect(r.text).not.toContain('more');
  });

  it('drops items past the budget and appends a drill-down affordance', () => {
    const big = 'z'.repeat(400); // ~100 tokens each
    const r = capList([big, big, big, big], render, 150, 'knowledge_fetch');
    expect(r.kept.length).toBeLessThan(4);
    expect(r.omitted).toBeGreaterThan(0);
    expect(r.text).toContain(`${r.omitted} more`);
    expect(r.text).toContain('knowledge_fetch');
  });

  it('always keeps at least the top item even if it exceeds budget', () => {
    const huge = 'q'.repeat(10000);
    const r = capList([huge, 'b'], render, 10, 'more');
    expect(r.kept.length).toBe(1);
    expect(r.kept[0]).toBe(huge);
  });

  it('keeps the total (including the drill-down line) within budget', () => {
    const item = 'z'.repeat(36); // ~9 tokens each
    const r = capList([item, item, item], (s) => s, 20, 'knowledge_fetch');
    expect(r.omitted).toBeGreaterThan(0);
    expect(estimateTokens(r.text)).toBeLessThanOrEqual(20);
  });
});
