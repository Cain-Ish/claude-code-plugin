export interface ValidationIssue {
    type: 'orphan_file' | 'broken_link' | 'missing_frontmatter' | 'duplicate_slug' | 'stale_page' | 'empty_page' | 'root_orphan';
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
//# sourceMappingURL=knowledge-validate.d.ts.map