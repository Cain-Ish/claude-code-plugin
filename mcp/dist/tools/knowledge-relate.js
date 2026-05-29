import { join } from 'path';
import { appendEdge, EDGE_TYPES } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';
export async function knowledgeRelate(args) {
    try {
        validateSlug(args.from);
        validateSlug(args.to);
    }
    catch (e) {
        if (e instanceof PathGuardError)
            return { ok: false, reason: `invalid slug: ${e.message}` };
        throw e;
    }
    if (!EDGE_TYPES.includes(args.type))
        return { ok: false, reason: `invalid type: ${args.type}` };
    const rec = {
        op: args.invalidate ? 'invalidate' : 'assert',
        from: args.from, to: args.to, type: args.type,
        recorded_at: new Date().toISOString(),
        source: 'manual', confidence: 'high',
    };
    if (args.valid_from)
        rec.valid_from = args.valid_from;
    if (args.valid_to)
        rec.valid_to = args.valid_to;
    if (args.reason)
        rec.reason = args.reason;
    const logPath = join(args.knowledgeDir, 'graph', 'edges.jsonl');
    await appendEdge(logPath, rec);
    return { ok: true, recorded: rec };
}
//# sourceMappingURL=knowledge-relate.js.map