import { describe, it, expect, afterEach } from 'vitest';
import {
  estimateTokens,
  egressBudgetTokens,
  DEFAULT_EGRESS_BUDGET_TOKENS,
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
