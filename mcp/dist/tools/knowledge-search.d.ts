export interface KnowledgeSearchArgs {
    query: string;
    scope?: string;
    knowledgeDir?: string;
    brainDir?: string;
    projectSlug?: string;
}
export interface KnowledgeSearchResult {
    candidates: {
        path: string;
        score: number;
        description: string;
        tokens: number;
        source: string;
    }[];
}
export interface ParsedDoc {
    title: string;
    description: string;
    type: string;
    tags: string[];
    related: string[];
    body: string;
    path: string;
    updated: string;
    created: string;
}
export declare function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult>;
export declare function parseDoc(content: string, filePath: string): ParsedDoc;
//# sourceMappingURL=knowledge-search.d.ts.map