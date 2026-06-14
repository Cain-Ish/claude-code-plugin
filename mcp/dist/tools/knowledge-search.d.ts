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
        /** Raw engine score — BM25(+capped boosts) or RRF scale depending on mode. Filterable via KNOWLEDGE_MIN_SCORE (contract preserved). */
        score: number;
        /** Rank-normalized to (0,1] on ONE scale regardless of mode (R2.3). The
         *  highest-scored RETURNED candidate is exactly 1; under project scoping
         *  (tier-major ordering) that anchor may not be the first listed. */
        score_norm: number;
        /** SP-1 project-scope tier (1=active project … 4=other project). Present only when scoping is active. */
        tier?: number;
        description: string;
        tokens: number;
        source: string;
    }[];
    /** Present when ONNX embeddings were unavailable — ranking fell back to BM25(+graph) only (R2.3). */
    degraded?: 'bm25-only';
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
    project: string;
    area: string;
    aiBlock?: Record<string, string>;
}
export declare function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult>;
export declare function parseDoc(content: string, filePath: string): ParsedDoc;
export declare function extractYamlValue(yaml: string, key: string): string;
export declare function extractYamlList(yaml: string, key: string): string[];
//# sourceMappingURL=knowledge-search.d.ts.map