/**
 * Deterministic egress budget guard for second-brain → Claude responses.
 * Pure, LLM-free, offline. This is the GUARD move of POINT/SERVE/GUARD:
 * cap how much any single retrieval dumps into Claude's context, never expand,
 * and always leave a drill-down affordance.
 * Spec: docs/superpowers/specs/2026-05-24-context-aware-memory-egress-design.md
 */

const CHARS_PER_TOKEN = 4;

export const DEFAULT_EGRESS_BUDGET_TOKENS = 2000;

/** Estimate token count with the chars/4 heuristic used across the plugin. */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

/** Configured egress budget (env override), falling back to the default. */
export function egressBudgetTokens(): number {
  const raw = process.env.SB_EGRESS_BUDGET_TOKENS;
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_EGRESS_BUDGET_TOKENS;
}
