export interface EpisodicSearchArgs {
    query: string | string[];
    mode?: 'vector' | 'text' | 'both';
    limit?: number;
    /** Hard filter — return only this project's exchanges. Wins over activeProject. */
    project?: string;
    /**
     * Soft default scope (SP-1 parity for the episodic tier): prefer same-project
     * exchanges and suppress other-project noise, broadening only when the active
     * project has no in-scope hit. Callers (MCP handler, per-prompt CLI) populate
     * this from the resolved active slug so episodic recall stops leaking across
     * projects. An explicit `project` (incl. "all"→omit) overrides it.
     */
    activeProject?: string;
    after?: string;
    before?: string;
}
export interface EpisodicSearchResult {
    results: {
        sessionId: string;
        project: string;
        date: string;
        userSnippet: string;
        assistantSnippet: string;
        similarity: number;
        archivePath: string;
        lineStart: number;
        lineEnd: number;
    }[];
}
export interface EpisodicReadResult {
    content: string;
    sessionId: string;
    project: string;
    date: string;
}
export declare function buildEpisodicIndex(brainDir: string): Promise<{
    indexed: number;
    total: number;
    repaired: number;
    pending: number;
}>;
export declare function episodicSearch(args: EpisodicSearchArgs, brainDir: string): Promise<EpisodicSearchResult>;
/**
 * Default the episodic search to the active project (MCP handler + CLI use this).
 * Mirrors how knowledge_search auto-passes the active slug, closing the
 * cross-project episodic leak. Precedence: an explicit `project` is a hard
 * filter and wins; the sentinel `project: "all"` is a deliberate broaden (drop
 * the filter, no scope); otherwise default the soft `activeProject` scope to the
 * resolved slug.
 */
export declare function withActiveScope(args: EpisodicSearchArgs, activeSlug: string | undefined): EpisodicSearchArgs;
export declare function scopeAndBroaden<T extends {
    project: string;
}>(ranked: T[], args: EpisodicSearchArgs): T[];
export declare function episodicRead(filePath: string, startLine?: number, endLine?: number): Promise<EpisodicReadResult>;
//# sourceMappingURL=episodic-search.d.ts.map