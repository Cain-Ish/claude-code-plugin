export interface ValidationIssue {
    type: 'orphan_file' | 'broken_link' | 'missing_frontmatter' | 'duplicate_slug' | 'stale_page' | 'empty_page' | 'root_orphan' | 'ai_block_incomplete' | 'ai_block_missing';
    severity: 'error' | 'warning';
    path: string;
    message: string;
    autofix?: string;
}
export interface ValidationResult {
    issues: ValidationIssue[];
    fixed: number;
    pagesScanned: number;
}
export declare function knowledgeValidate(knowledgeDir: string, opts?: {
    autofix?: boolean;
}): Promise<ValidationResult>;
export declare function addFrontmatter(filePath: string, wikiDir: string): Promise<void>;
//# sourceMappingURL=knowledge-validate.d.ts.map