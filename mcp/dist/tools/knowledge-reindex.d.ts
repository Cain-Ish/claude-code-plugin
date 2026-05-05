import { ValidationIssue } from './knowledge-validate.js';
export interface ReindexResult {
    pagesIndexed: number;
    categories: string[];
    indexPath: string;
    validation?: {
        issues: ValidationIssue[];
        fixed: number;
    };
}
export declare function knowledgeReindex(knowledgeDir: string): Promise<ReindexResult>;
//# sourceMappingURL=knowledge-reindex.d.ts.map