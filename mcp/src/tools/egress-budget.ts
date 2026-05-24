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

export interface CapTextResult {
  text: string;
  truncated: boolean;
  omittedTokens: number;
}

/**
 * Truncate text to a token budget on a grapheme boundary (never splits an
 * emoji/CJK cluster), appending a drill-down marker. Never expands: text that
 * already fits is returned unchanged with truncated=false.
 */
export function capText(
  text: string,
  maxTokens: number,
  pointer?: string,
): CapTextResult {
  const total = estimateTokens(text);
  if (total <= maxTokens) {
    return { text, truncated: false, omittedTokens: 0 };
  }
  const marker = pointer ? `\n… truncated — full text via ${pointer}` : `\n… truncated`;
  const keepChars = Math.max(0, (maxTokens - estimateTokens(marker))) * CHARS_PER_TOKEN;
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  let out = '';
  for (const { segment } of segmenter.segment(text)) {
    if (out.length + segment.length > keepChars) break;
    out += segment;
  }
  return { text: out + marker, truncated: true, omittedTokens: total - estimateTokens(out) };
}

export interface CapListResult<T> {
  kept: T[];
  text: string;
  omitted: number;
}

/**
 * Render a ranked list under a token budget. Keeps items in order until the
 * next would exceed the budget, then appends a drill-down affordance
 * ("N more — <hint>"). Always keeps at least the top item. Never expands.
 */
export function capList<T>(
  items: T[],
  render: (item: T) => string,
  maxTokens: number,
  moreHint: string,
  separator = '\n\n',
): CapListResult<T> {
  const kept: T[] = [];
  const parts: string[] = [];
  let used = 0;
  for (const item of items) {
    const piece = render(item);
    const cost = estimateTokens(piece) + estimateTokens(separator);
    if (kept.length > 0 && used + cost > maxTokens) break;
    kept.push(item);
    parts.push(piece);
    used += cost;
  }
  const omitted = items.length - kept.length;
  let text = parts.join(separator);
  if (omitted > 0) text += `${separator}… ${omitted} more — ${moreHint}`;
  return { kept, text, omitted };
}
