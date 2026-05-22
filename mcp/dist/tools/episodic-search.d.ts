export interface EpisodicSearchArgs {
    query: string | string[];
    mode?: 'vector' | 'text' | 'both';
    limit?: number;
    project?: string;
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
export declare function episodicRead(filePath: string, startLine?: number, endLine?: number): Promise<EpisodicReadResult>;
//# sourceMappingURL=episodic-search.d.ts.map