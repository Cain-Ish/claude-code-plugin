import { join } from 'path';
import { loadEdges, foldToCurrent, neighbors } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';
export async function knowledgeNeighbors(args) {
    try {
        validateSlug(args.slug);
    }
    catch (e) {
        if (e instanceof PathGuardError)
            return { slug: args.slug, edges: [] };
        throw e;
    }
    const records = await loadEdges(join(args.knowledgeDir, 'graph', 'edges.jsonl'));
    if (records.length === 0)
        return { slug: args.slug, edges: [] };
    const current = foldToCurrent(records);
    const edges = neighbors(current, args.slug, {
        depth: args.depth, direction: args.direction,
        edgeTypes: args.edge_types, asOf: args.as_of,
    });
    return { slug: args.slug, edges };
}
//# sourceMappingURL=knowledge-neighbors.js.map