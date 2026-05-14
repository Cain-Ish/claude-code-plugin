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
}
export declare function personaThink(args: PersonaThinkArgs, deps?: PersonaThinkDeps): Promise<PersonaBrief>;
export interface BudgetState {
    date: string;
    today_usd: number;
}
export declare function readBudget(brainDir: string): Promise<BudgetState>;
export declare function recordSpend(brainDir: string, usd: number): Promise<BudgetState>;
//# sourceMappingURL=persona-think.d.ts.map