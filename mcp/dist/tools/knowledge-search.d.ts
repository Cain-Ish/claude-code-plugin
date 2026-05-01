export type Scope = 'concepts' | 'issues' | 'entities' | 'learnings' | 'decisions';
export interface KnowledgeSearchArgs {
    query: string;
    scope?: Scope;
    knowledgeDir?: string;
}
export interface KnowledgeSearchResult {
    candidates: {
        path: string;
        score: number;
        first_lines: string;
    }[];
}
export declare function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult>;
//# sourceMappingURL=knowledge-search.d.ts.map