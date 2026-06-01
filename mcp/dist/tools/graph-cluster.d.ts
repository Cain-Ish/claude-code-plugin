/**
 * Deterministic in-memory community detection for the dream SUMMARIZE phase.
 * Label propagation (Graphiti's choice over Leiden, for cheap incremental updates),
 * made fully deterministic so it is unit-testable and reproducible:
 *   - synchronous rounds (every node's next label is computed from the PREVIOUS
 *     round's labels, so within-round visit order is irrelevant);
 *   - nodes iterated in lexicographic slug order;
 *   - tie-break: keep the node's own current label if it is among the tied plurality
 *     (this also breaks the 2-cycle oscillation pure synchronous label-prop suffers
 *     on bipartite-ish structure), else take the smallest slug among the tied labels;
 *   - deterministic cutoff at maxIter.
 * Labels ARE slugs; a community's id is the lexicographically-smallest slug among its
 * members. No graph DB, no dependency. Spec: docs/specs/2026-06-01-dream-consolidation-v2-design.md §B1.1.
 */
export interface ClusterPage {
    slug: string;
    related: string[];
    bodyLinks: string[];
}
export interface Cluster {
    id: string;
    members: string[];
}
/** Undirected adjacency from each page's related: + body [[links]]; self-loops and
 *  links to unknown slugs are ignored. */
export declare function buildAdjacency(pages: ClusterPage[]): Map<string, Set<string>>;
export interface LabelOpts {
    maxIter?: number;
}
export declare function labelPropagate(adj: Map<string, Set<string>>, opts?: LabelOpts): Map<string, string>;
/** Single synchronous step: assign a new node the plurality community of its current
 *  neighbours (smallest-slug tie-break). Returns the node's own slug if it has no
 *  labelled neighbours. */
export declare function assignNewNode(adj: Map<string, Set<string>>, labels: Map<string, string>, node: string): string;
/** Group a label map into clusters ≥ minSize, sorted by id, members sorted. */
export declare function clusters(labels: Map<string, string>, opts: {
    minSize: number;
}): Cluster[];
/** Self-contained, content-aware djb2 hash over (sorted members + their content hashes),
 *  so a same-membership member-content change still triggers a theme-page refresh.
 *  Intentionally does NOT reuse embeddings.ts simpleHash (unexported + truncated text). */
export declare function memberHash(sortedMembers: string[], contentHashBySlug: Record<string, string>): string;
//# sourceMappingURL=graph-cluster.d.ts.map