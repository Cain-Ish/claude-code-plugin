import { NeighborEdge, EdgeType } from './graph-store.js';
export interface KnowledgeNeighborsArgs {
    slug: string;
    depth?: number;
    direction?: 'out' | 'in' | 'both';
    edge_types?: EdgeType[];
    as_of?: string;
    knowledgeDir: string;
}
export interface KnowledgeNeighborsResult {
    slug: string;
    edges: NeighborEdge[];
}
export declare function knowledgeNeighbors(args: KnowledgeNeighborsArgs): Promise<KnowledgeNeighborsResult>;
//# sourceMappingURL=knowledge-neighbors.d.ts.map