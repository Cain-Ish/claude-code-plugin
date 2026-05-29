import { join } from 'path';
import { appendEdge, loadEdges, foldToCurrent, EdgeRecord, EdgeType, EDGE_TYPES } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}([T ].*)?$/;

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

  // Dates feed the lexicographic interval math (cmpTime/validAt) — reject a
  // non-ISO date rather than persist a value that sorts wrong and silently makes
  // the edge always- or never-valid.
  for (const [k, v] of [['valid_from', args.valid_from], ['valid_to', args.valid_to]] as const) {
    if (v !== undefined && !ISO_DATE_RE.test(v)) return { ok: false, reason: `invalid ${k} (want YYYY-MM-DD): ${v}` };
  }

  const logPath = join(args.knowledgeDir, 'graph', 'edges.jsonl');

  // Invalidate must target an actually-open edge — otherwise foldToCurrent
  // silently ignores it and the caller would get a misleading ok:true while the
  // relationship stays live. Check before writing.
  if (args.invalidate) {
    const current = foldToCurrent(await loadEdges(logPath));
    const open = current.find(e =>
      e.from === args.from && e.to === args.to && e.type === args.type && e.valid_to === null);
    if (!open) {
      return { ok: false, reason: `no open ${args.type} edge ${args.from}->${args.to} to invalidate` };
    }
  }

  const rec: EdgeRecord = {
    op: args.invalidate ? 'invalidate' : 'assert',
    from: args.from, to: args.to, type: args.type,
    recorded_at: new Date().toISOString(),
    source: 'manual', confidence: 'high',
  };
  if (args.valid_from) rec.valid_from = args.valid_from;
  if (args.valid_to) rec.valid_to = args.valid_to;
  if (args.reason) rec.reason = args.reason;

  await appendEdge(logPath, rec);
  return { ok: true, recorded: rec };
}
