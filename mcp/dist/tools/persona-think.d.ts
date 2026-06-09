export interface PersonaThinkArgs {
    prompt: string;
    context_hints?: string[];
}
export interface PersonaBrief {
    intent_read: string;
    prompt_enrichment: string;
    clarifying_questions: string[];
    relevant_specialists: string[];
    risk_flags: string[];
    budget_skipped?: boolean;
    error?: string;
    cached?: boolean;
}
export interface PersonaThinkDeps {
    runner?: (system: string, user: string, model: string) => Promise<string>;
    budgetExceeded?: boolean;
    model?: string;
    brainDir?: string;
    /** Path to the Contract A Opus ledger (opus-budget.json). Defaults to brainDir/opus-budget.json
     *  then ${COST_ROUTER_LEDGER}. Graceful no-op when absent/unwritable. */
    ledgerPath?: string;
    /** Override token counts for testing (avoids actual call to claude for cost estimation). */
    inputTokens?: number;
    outputTokens?: number;
    /** Override the daily Opus cap (USD). Defaults to COST_ROUTER_OPUS_CAP_USD or 5.0. */
    opusCap?: number;
}
export interface OpusLedger {
    date: string;
    opus_cost_usd: number;
    opus_calls: number;
    cap_usd: number;
}
/** Return the path for the shared Opus ledger, given an optional brainDir. */
export declare function opusLedgerPath(brainDir?: string): string;
/** Read the shared Opus ledger. Returns zeros on missing/stale file. Never throws. */
export declare function readOpusLedger(ledgerPath: string): Promise<OpusLedger>;
/** Record an Opus call's cost (in tokens) to the shared ledger. Graceful no-op on write failure. */
export declare function recordOpusLedger(ledgerPath: string, inputTokens: number, outputTokens: number): Promise<void>;
export declare function personaThink(args: PersonaThinkArgs, deps?: PersonaThinkDeps): Promise<PersonaBrief>;
export interface BudgetState {
    date: string;
    today_usd: number;
}
export declare function readBudget(brainDir: string): Promise<BudgetState>;
export declare function recordSpend(brainDir: string, usd: number): Promise<BudgetState>;
//# sourceMappingURL=persona-think.d.ts.map