export type Tier = 'gist' | 'skeleton' | 'summary' | 'full';
export interface KnowledgeFetchArgs {
    slug: string;
    tier?: Tier;
    knowledgeDir?: string;
}
export interface KnowledgeFetchResult {
    slug: string;
    path: string | null;
    tier: Tier;
    text: string;
    tokens: number;
    truncated: boolean;
    pointer: string;
}
export declare function knowledgeFetch(args: KnowledgeFetchArgs): Promise<KnowledgeFetchResult>;
//# sourceMappingURL=knowledge-fetch.d.ts.map