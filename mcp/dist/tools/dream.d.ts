interface DreamStatus {
    id: string;
    status: "pending" | "running" | "completed" | "failed" | "canceled";
    created_at: string;
    started_at: string | null;
    ended_at: string | null;
    archived_at: string | null;
    model: string;
    instructions: string;
    inputs: {
        transcript_count: number;
        wiki_page_count: number;
        wiki_snapshot_bytes: number;
    };
    outputs: {
        pages_added: number;
        pages_modified: number;
        pages_removed: number;
    };
    error: string | null;
}
export interface DreamCreateArgs {
    instructions?: string;
    transcript_filter?: {
        project_slug?: string;
        since?: string;
        max_count?: number;
    };
    model?: string;
}
export interface DreamCreateResult {
    ok: boolean;
    dream: DreamStatus | null;
    reason?: string;
}
export declare function dreamCreate(args: DreamCreateArgs): Promise<DreamCreateResult>;
export interface DreamStatusArgs {
    dream_id: string;
}
export interface DreamStatusResult {
    ok: boolean;
    dream: DreamStatus | null;
    diff_preview?: string;
    reason?: string;
}
export declare function dreamStatus(args: DreamStatusArgs): Promise<DreamStatusResult>;
export interface DreamListArgs {
    include_archived?: boolean;
}
export interface DreamListResult {
    ok: boolean;
    dreams: Array<{
        id: string;
        status: string;
        created_at: string;
        ended_at: string | null;
        archived_at: string | null;
        transcript_count: number;
        pages_added: number;
        pages_modified: number;
        pages_removed: number;
    }>;
}
export declare function dreamList(args: DreamListArgs): Promise<DreamListResult>;
export interface DreamAcceptArgs {
    dream_id: string;
}
export interface DreamAcceptResult {
    ok: boolean;
    summary?: string;
    reason?: string;
}
export declare function dreamAccept(args: DreamAcceptArgs): Promise<DreamAcceptResult>;
export interface DreamDiscardArgs {
    dream_id: string;
}
export interface DreamDiscardResult {
    ok: boolean;
    reason?: string;
}
export declare function dreamDiscard(args: DreamDiscardArgs): Promise<DreamDiscardResult>;
export interface DreamCancelArgs {
    dream_id: string;
}
export interface DreamCancelResult {
    ok: boolean;
    reason?: string;
}
export declare function dreamCancel(args: DreamCancelArgs): Promise<DreamCancelResult>;
export {};
//# sourceMappingURL=dream.d.ts.map