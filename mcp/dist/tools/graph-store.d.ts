export type EdgeOp = 'assert' | 'invalidate';
export type EdgeType = 'requires' | 'affects' | 'relates' | 'part_of' | 'supersedes';
export declare const EDGE_TYPES: EdgeType[];
/** One line in edges.jsonl — the source-of-truth record. */
export interface EdgeRecord {
    op: EdgeOp;
    from: string;
    to: string;
    type: EdgeType;
    valid_from?: string | null;
    valid_to?: string | null;
    recorded_at: string;
    source?: string;
    confidence?: 'high' | 'medium';
    reason?: string;
}
/** Folded current state of an edge identity (from,type,to). */
export interface CurrentEdge {
    from: string;
    to: string;
    type: EdgeType;
    valid_from: string;
    valid_to: string | null;
    source?: string;
    confidence?: 'high' | 'medium';
}
/** Lexicographic ISO comparison. ISO-8601 date ('2026-05-29') and Z-timestamp
 *  ('2026-05-29T12:00:00Z') both sort correctly as strings. A date-only string
 *  sorts BEFORE any same-day timestamp (shorter, and the next char in the longer
 *  string is 'T'), which is exactly what the half-open [from,to) interval needs. */
export declare function cmpTime(a: string, b: string): number;
/** First 10 chars of an ISO string = YYYY-MM-DD. */
export declare function dateOf(iso: string): string;
/** Read edges.jsonl line-by-line. A missing file yields [] (graph absent =
 *  current behaviour preserved). Each line is parsed independently; any
 *  unparseable or invalid line (incl. a torn final line) is skipped, never fatal. */
export declare function loadEdges(path: string): Promise<EdgeRecord[]>;
/** Fold the append-only log into current edge state, keyed by (from,type,to).
 *  Records are applied in recorded_at order (stable). assert opens/updates an
 *  interval; invalidate closes it. An assert after a close re-opens a fresh
 *  interval. invalidate with no prior assert is ignored. */
export declare function foldToCurrent(records: EdgeRecord[]): CurrentEdge[];
/** True iff the edge is valid at time T: valid_from <= T AND (valid_to null OR valid_to > T).
 *  Half-open interval — an edge invalidated on date D is NOT valid at D. */
export declare function validAt(e: {
    valid_from: string;
    valid_to: string | null;
}, t: string): boolean;
export interface NeighborEdge {
    from: string;
    to: string;
    type: EdgeType;
    hops: number;
    score: number;
    valid_from: string;
    valid_to: string | null;
}
export interface NeighborOpts {
    depth?: number;
    direction?: 'out' | 'in' | 'both';
    edgeTypes?: EdgeType[];
    asOf?: string;
}
/** BFS over current-valid edges from `slug`, up to `depth` hops. Score per
 *  reached node = TYPE_WEIGHT * GRAPH_DECAY^hop, keeping the min-hop path. */
export declare function neighbors(edges: CurrentEdge[], slug: string, opts?: NeighborOpts): NeighborEdge[];
/** Append one validated edge record as a single JSONL line. Used by the
 *  knowledge_relate MCP tool. (The hook write path appends from bash directly;
 *  the JSONL line format is the shared contract.) */
export declare function appendEdge(path: string, rec: EdgeRecord): Promise<void>;
//# sourceMappingURL=graph-store.d.ts.map