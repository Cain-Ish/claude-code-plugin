export declare function hashContent(content: string): string;
/** Gist = first H1 / frontmatter title / first non-empty line. Deterministic, no LLM. */
export declare function extractGist(content: string): string;
/** H2/H3 headings, in order (excludes the H1 title). */
export declare function extractHeadings(content: string): string[];
export interface DocSourceConfig {
    locations: string[];
}
export interface DocEntry {
    id: string;
    path: string;
    rel: string;
    gist: string;
    headings: string[];
    hash: string;
    mtime: string;
    size: number;
}
export declare function assertSafeSlug(slug: string): void;
export declare function readConfig(brainDir: string, slug: string): Promise<DocSourceConfig>;
export declare function scanLocations(projectRoot: string, locations: string[]): Promise<DocEntry[]>;
export interface DocRegistry {
    generated_at: string;
    project: string;
    entries: DocEntry[];
}
export declare function loadRegistry(brainDir: string, slug: string): Promise<DocRegistry | null>;
/** Scan the live FS (config-declared locations) and write the registry. The fresh
 *  scan IS the reconciled state: content-hash ids are stable across moves, removed
 *  files are simply absent, edits get a new hash. */
export declare function buildRegistry(projectRoot: string, brainDir: string, slug: string): Promise<DocRegistry>;
export declare function listLocations(brainDir: string, slug: string): Promise<string[]>;
export declare function addLocation(brainDir: string, slug: string, location: string): Promise<{
    locations: string[];
    added: boolean;
}>;
export declare function removeLocation(brainDir: string, slug: string, location: string): Promise<{
    locations: string[];
    removed: boolean;
}>;
//# sourceMappingURL=doc-sources.d.ts.map