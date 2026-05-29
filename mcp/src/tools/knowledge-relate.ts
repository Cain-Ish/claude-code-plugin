import { join } from 'path';
import { appendEdge, EdgeRecord, EdgeType, EDGE_TYPES } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';

export interface KnowledgeRelateArgs {
  from: string; to: string; type: EdgeType;
  valid_from?: string; valid_to?: string;
  invalidate?: boolean; reason?: string;
  knowledgeDir: string;
}
export interface KnowledgeRelateResult { ok: boolean; recorded?: EdgeRecord; reason?: string; }

export async function knowledgeRelate(args: KnowledgeRelateArgs): Promise<KnowledgeRelateResult> {
  try { validateSlug(args.from); validateSlug(args.to); }
  catch (e) {
    if (e instanceof PathGuardError) return { ok: false, reason: `invalid slug: ${e.message}` };
    throw e;
  }
  if (!(EDGE_TYPES as string[]).includes(args.type)) return { ok: false, reason: `invalid type: ${args.type}` };

  const rec: EdgeRecord = {
    op: args.invalidate ? 'invalidate' : 'assert',
    from: args.from, to: args.to, type: args.type,
    recorded_at: new Date().toISOString(),
    source: 'manual', confidence: 'high',
  };
  if (args.valid_from) rec.valid_from = args.valid_from;
  if (args.valid_to) rec.valid_to = args.valid_to;
  if (args.reason) rec.reason = args.reason;

  const logPath = join(args.knowledgeDir, 'graph', 'edges.jsonl');
  await appendEdge(logPath, rec);
  return { ok: true, recorded: rec };
}
