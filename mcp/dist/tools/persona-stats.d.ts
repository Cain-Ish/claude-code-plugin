export interface PersonaStatsArgs {
    brainDir?: string;
}
export interface PersonaStatsResult {
    identity_summary: string;
    persona_card_bytes: number;
    ungraduated_signals: number;
    graduated_signals: number;
    installed_plugins: number;
    installed_agents: number;
    installed_skills: number;
    dismissals_7d: number;
    today_spend_usd: number;
    daily_budget_usd: number;
}
export declare function personaStats(args?: PersonaStatsArgs): Promise<PersonaStatsResult>;
//# sourceMappingURL=persona-stats.d.ts.map