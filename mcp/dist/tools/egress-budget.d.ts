/**
 * Deterministic egress budget guard for second-brain → Claude responses.
 * Pure, LLM-free, offline. This is the GUARD move of POINT/SERVE/GUARD:
 * cap how much any single retrieval dumps into Claude's context, never expand,
 * and always leave a drill-down affordance.
 * Spec: docs/superpowers/specs/2026-05-24-context-aware-memory-egress-design.md
 */
export declare const DEFAULT_EGRESS_BUDGET_TOKENS = 2000;
/** Estimate token count with the chars/4 heuristic used across the plugin. */
export declare function estimateTokens(text: string): number;
/** Configured egress budget (env override), falling back to the default. */
export declare function egressBudgetTokens(): number;
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
export declare function capText(text: string, maxTokens: number, pointer?: string): CapTextResult;
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
export declare function capList<T>(items: T[], render: (item: T) => string, maxTokens: number, moreHint: string, separator?: string): CapListResult<T>;
//# sourceMappingURL=egress-budget.d.ts.map