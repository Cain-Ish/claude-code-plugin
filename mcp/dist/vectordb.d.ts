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
    private db;
    private dbPath;
    private dbDir;
    private initPromise;
    constructor(knowledgeDir: string);
    private init;
    private migrate;
    private persist;
    private getDb;
    ready(): Promise<void>;
    isIndexed(filePath: string, lastModified: number): boolean;
    upsertPage(page: WikiPage, embedding: Float32Array): void;
    search(queryEmbedding: Float32Array, limit?: number, category?: string, minCosineSimilarity?: number, queryText?: string): SearchResult[];
    recordAccess(paths: string[]): void;
    updateAccessCount(filePath: string, delta: number): boolean;
    flush(): void;
    getStats(): {
        totalPages: number;
        categories: Record<string, number>;
        lastIndexed: string | null;
    };
    removeStale(existingPaths: Set<string>): number;
    close(): void;
}
//# sourceMappingURL=vectordb.d.ts.map