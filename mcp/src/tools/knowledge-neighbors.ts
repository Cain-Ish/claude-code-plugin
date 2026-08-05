import { promises as fs } from 'fs';
import { join } from 'path';
import { loadEdges, foldToCurrent, neighbors, NeighborEdge, EdgeType } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';

export interface KnowledgeNeighborsArgs {
  slug: string; depth?: number;
  direction?: 'out' | 'in' | 'both';
  edge_types?: EdgeType[]; as_of?: string;
  knowledgeDir: string;
}
export interface KnowledgeNeighborsResult {
  slug: string;
  /** Present when `slug` is not a graph node itself but the project registry maps it
   *  (as a project key) to an anchor entity — edges below are the ANCHOR's. */
  resolved_anchor?: string;
  /** Present when anchor resolution was attempted (slug is no graph node, no as_of)
   *  and found nothing usable — the visible form of "the registry has no mapping for
   *  this project", which would otherwise be indistinguishable from a node with no
   *  dependencies. */
  anchor_miss?: boolean;
  edges: NeighborEdge[];
}

/** One row of graph/project-registry.jsonl — the project-key → anchor-entity mapping.
 *  NOT the same file as projects.jsonl (read by project-registry.ts); that registry
 *  records project metadata, this one records graph anchors. */
interface ProjectRegistryRow { project: string; anchor: string }

/** A project key (e.g. "claude-code-plugin") is usually not a graph node — its edges
 *  hang off an anchor entity page (e.g. "second-brain-plugin"). graph/project-registry.jsonl
 *  records that mapping; resolve through it so "start from the project" traversal works. */
async function resolveProjectAnchor(knowledgeDir: string, slug: string): Promise<string | undefined> {
  let text: string;
  try { text = await fs.readFile(join(knowledgeDir, 'graph', 'project-registry.jsonl'), 'utf-8'); }
  catch (e) {
    // ENOENT = no registry yet, a normal state. Anything else (EACCES, EISDIR, disk
    // I/O) is a real failure and must surface as a tool error, not an empty result.
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw e;
  }
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s) as Partial<ProjectRegistryRow>;
      if (r && r.project === slug && typeof r.anchor === 'string' && r.anchor) return r.anchor;
    } catch { /* skip malformed line */ }
  }
  return undefined;
}

export async function knowledgeNeighbors(args: KnowledgeNeighborsArgs): Promise<KnowledgeNeighborsResult> {
  try { validateSlug(args.slug); }
  catch (e) { if (e instanceof PathGuardError) return { slug: args.slug, edges: [] }; throw e; }
  const records = await loadEdges(join(args.knowledgeDir, 'graph', 'edges.jsonl'));
  if (records.length === 0) return { slug: args.slug, edges: [] };
  const current = foldToCurrent(records);
  const opts = {
    depth: args.depth, direction: args.direction,
    edgeTypes: args.edge_types, asOf: args.as_of,
  };
  const edges = neighbors(current, args.slug, opts);
  if (edges.length > 0) return { slug: args.slug, edges };
  // Anchor fallback ONLY when the slug is no graph node AT ALL — checked against the
  // raw folded edge set, never the direction/type/as_of-filtered result. A real node
  // whose edges are merely filtered out (e.g. only outbound edges queried with
  // direction:'in') must return its honest empty answer, not another entity's edges.
  const isGraphNode = current.some(e => e.from === args.slug || e.to === args.slug);
  if (isGraphNode) return { slug: args.slug, edges };
  // Never under as_of: the registry reflects CURRENT structure only — substituting the
  // anchor's history would present a different entity's past under the queried name.
  if (args.as_of) return { slug: args.slug, edges };
  const anchor = await resolveProjectAnchor(args.knowledgeDir, args.slug);
  if (!anchor || anchor === args.slug) return { slug: args.slug, edges, anchor_miss: true };
  try { validateSlug(anchor); } catch { return { slug: args.slug, edges, anchor_miss: true }; }
  const anchorEdges = neighbors(current, anchor, opts);
  if (anchorEdges.length === 0) return { slug: args.slug, edges, anchor_miss: true };
  return { slug: args.slug, resolved_anchor: anchor, edges: anchorEdges };
}
