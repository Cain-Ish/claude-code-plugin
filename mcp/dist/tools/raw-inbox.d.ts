export type RawStatus = 'unprocessed' | 'processed' | 'discarded';
export type CapturedBy = 'user' | 'setup-scan' | 'dream';
export interface RawItem {
    id: string;
    source: string;
    captured_at: string;
    captured_by: CapturedBy;
    content_type: string;
    status: RawStatus;
    target_node?: string;
    blob?: string;
    hash: string;
    gist: string;
    body: string;
    malformed?: boolean;
}
export interface CaptureInput {
    brainDir: string;
    slug: string;
    source: string;
    kind: 'file' | 'url' | 'paste';
    content?: string;
    targetNode?: string;
    capturedBy?: CapturedBy;
    now?: string;
}
export declare function rawDir(brainDir: string, slug: string): string;
export declare function listItems(brainDir: string, slug: string): Promise<RawItem[]>;
export declare function unprocessedCount(brainDir: string, slug: string): Promise<number>;
export declare function setStatus(brainDir: string, slug: string, id: string, status: RawStatus): Promise<boolean>;
export declare function captureItem(input: CaptureInput): Promise<{
    id: string;
    duplicate: boolean;
    unprocessed: number;
}>;
//# sourceMappingURL=raw-inbox.d.ts.map