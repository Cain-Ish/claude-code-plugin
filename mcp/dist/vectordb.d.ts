export interface WikiPage {
    path: string;
    title: string;
    content: string;
    category: string;
    lastModified: number;
}
export interface SearchResult {
    path: string;
    title: string;
    excerpt: string;
    category: string;
    score: number;
}
export declare class VectorDB {
    private storePath;
    private store;
    private dirty;
    constructor(knowledgeDir: string);
    private load;
    private writeStore;
    /** Persist any pending writes. Call after a batch of upsertPage(). */
    flush(): void;
    isIndexed(filePath: string, lastModified: number): boolean;
    upsertPage(page: WikiPage, embedding: Float32Array): void;
    search(queryEmbedding: Float32Array, limit?: number, category?: string): SearchResult[];
    getStats(): {
        totalPages: number;
        categories: Record<string, number>;
        lastIndexed: string | null;
    };
    removeStale(existingPaths: Set<string>): number;
}
//# sourceMappingURL=vectordb.d.ts.map