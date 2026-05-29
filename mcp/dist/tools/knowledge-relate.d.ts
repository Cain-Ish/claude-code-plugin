import { EdgeRecord, EdgeType } from './graph-store.js';
export interface KnowledgeRelateArgs {
    from: string;
    to: string;
    type: EdgeType;
    valid_from?: string;
    valid_to?: string;
    invalidate?: boolean;
    reason?: string;
    knowledgeDir: string;
}
export interface KnowledgeRelateResult {
    ok: boolean;
    recorded?: EdgeRecord;
    reason?: string;
}
export declare function knowledgeRelate(args: KnowledgeRelateArgs): Promise<KnowledgeRelateResult>;
//# sourceMappingURL=knowledge-relate.d.ts.map