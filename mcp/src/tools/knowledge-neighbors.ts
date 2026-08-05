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
  /** Present when `slug` had no edges of its own but the project registry maps it
   *  (as a project key) to an anchor entity — edges below are the ANCHOR's. */
  resolved_anchor?: string;
  edges: NeighborEdge[];
}

/** A project key (e.g. "claude-code-plugin") is usually not a graph node — its edges
 *  hang off an anchor entity page (e.g. "second-brain-plugin"). graph/project-registry.jsonl
 *  records that mapping; resolve through it so "start from the project" traversal works. */
async function resolveProjectAnchor(knowledgeDir: string, slug: string): Promise<string | undefined> {
  let text: string;
  try { text = await fs.readFile(join(knowledgeDir, 'graph', 'project-registry.jsonl'), 'utf-8'); }
  catch { return undefined; }
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s);
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
  // Zero own edges: try the project-registry anchor (only-when-empty keeps existing
  // slugs' behavior byte-identical; a project key node normally has no edges at all).
  // Never under as_of: the registry reflects CURRENT structure only — substituting the
  // anchor's history for a slug whose own edges merely post-date as_of would present a
  // different entity's past under the queried name (review 0.43.0 #5).
  if (args.as_of) return { slug: args.slug, edges };
  const anchor = await resolveProjectAnchor(args.knowledgeDir, args.slug);
  if (!anchor || anchor === args.slug) return { slug: args.slug, edges };
  try { validateSlug(anchor); } catch { return { slug: args.slug, edges }; }
  const anchorEdges = neighbors(current, anchor, opts);
  if (anchorEdges.length === 0) return { slug: args.slug, edges };
  return { slug: args.slug, resolved_anchor: anchor, edges: anchorEdges };
}
