/**
 * P3a Task B2 -- code_neighbors MCP tool core: blast-radius BFS over the code
 * graph's import edges. direction 'in' = importers ("what breaks if I change
 * this"), 'out' = dependencies. Mirrors graph-store.ts::neighbors' min-hop
 * dedup shape but over CodeEdge[] -- the wiki graph tool stays untouched
 * (plan: "Separation from the wiki graph").
 *
 * Node resolution is fuzzy but never silently guesses: exact file id, then
 * exact symbol id (mapped to its file -- edges are file-level in schema v1),
 * then unique basename; an ambiguous basename returns ALL matches for the
 * caller to disambiguate. Unknown node and absent store are normal states
 * (typed results the server renders as text), not errors.
 *
 * Determinism: rows sort hops asc, then from/to by codepoint (< / >, not
 * localeCompare -- locale-dependent collation would break the byte-identical
 * contract across machines), so the cap slice is stable.
 */

import { codemapDir, readGraph } from './store.js';
import { isStale } from './drift.js';
import type { GitRunner } from './scan-sources.js';
import type { CodeEdge, CodeGraph } from './types.js';

const DEFAULT_NEIGHBORS_MAX = 50;
const MAX_DEPTH = 4;

export type Direction = 'in' | 'out' | 'both';

export interface CodeNeighborRow {
  from: string;
  to: string;
  type: 'imports';
  hops: number;
}

export interface CodeNeighborsOpts {
  brainDir: string;
  slug: string;
  node: string;
  /** default 'both' */
  direction?: Direction;
  /** default 1, max 4 (zod enforces at the MCP surface; re-checked here fail-loud) */
  depth?: number;
  /** default SB_CODEMAP_NEIGHBORS_MAX or 50 */
  max?: number;
  /** injectable git spawner for tests (drift probe) */
  runGit?: GitRunner;
}

export type CodeNeighborsResult =
  | { kind: 'missing'; notice: string }
  | { kind: 'unknown'; node: string; notice: string }
  | { kind: 'ambiguous'; node: string; matches: string[]; note: string }
  | {
      kind: 'ok';
      node: string;
      direction: Direction;
      depth: number;
      neighbors: CodeNeighborRow[];
      truncated: boolean;
      /** query-time drift flag — same isStale predicate as code_map (plan C1:
       *  "a query between regens is honest" applies to blast-radius too) */
      stale: boolean;
    };

function basename(id: string): string {
  return id.slice(id.lastIndexOf('/') + 1);
}

type Resolved = { id: string } | { matches: string[] } | null;

function resolveNode(graph: CodeGraph, arg: string): Resolved {
  if (graph.files.some((f) => f.id === arg)) return { id: arg };
  const sym = graph.symbols.find((s) => s.id === arg);
  if (sym) return { id: sym.file };
  const matches = graph.files
    .filter((f) => basename(f.id) === arg)
    .map((f) => f.id)
    .sort();
  if (matches.length === 1) return { id: matches[0] };
  if (matches.length > 1) return { matches };
  return null;
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Min-hop BFS (graph-store.ts::neighbors shape): each edge appears once at
 *  the smallest hop count it is reachable at. */
function bfs(edges: CodeEdge[], start: string, direction: Direction, depth: number): CodeNeighborRow[] {
  const best = new Map<string, CodeNeighborRow>();
  const seen = new Set<string>([start]);
  let frontier: { node: string; hop: number }[] = [{ node: start, hop: 0 }];

  while (frontier.length) {
    const next: { node: string; hop: number }[] = [];
    for (const { node, hop } of frontier) {
      if (hop >= depth) continue;
      for (const e of edges) {
        let other: string | null = null;
        if ((direction === 'out' || direction === 'both') && e.from === node) other = e.to;
        else if ((direction === 'in' || direction === 'both') && e.to === node) other = e.from;
        if (other === null) continue;
        // JSON-array key: collision-proof edge identity even for ids containing
        // spaces (a plain concatenation separator could be forged by a crafted path).
        const id = JSON.stringify([e.from, e.to]);
        const prev = best.get(id);
        if (!prev || hop + 1 < prev.hops) {
          best.set(id, { from: e.from, to: e.to, type: e.type, hops: hop + 1 });
        }
        if (!seen.has(other)) {
          seen.add(other);
          next.push({ node: other, hop: hop + 1 });
        }
      }
    }
    frontier = next;
  }
  return [...best.values()].sort((a, b) => a.hops - b.hops || cmp(a.from, b.from) || cmp(a.to, b.to));
}

export async function codeNeighbors(opts: CodeNeighborsOpts): Promise<CodeNeighborsResult> {
  const depth = opts.depth ?? 1;
  if (!Number.isInteger(depth) || depth < 1 || depth > MAX_DEPTH) {
    throw new Error(`code_neighbors: depth must be an integer in 1..${MAX_DEPTH}, got ${depth}`);
  }
  const direction = opts.direction ?? 'both';

  const graph = await readGraph(codemapDir(opts.brainDir, opts.slug));
  if (graph === null) {
    return {
      kind: 'missing',
      notice: `Code map for '${opts.slug}' not generated yet -- it regenerates automatically out-of-band (drainer tick); retry later or run the code-map CLI manually.`,
    };
  }

  const resolved = resolveNode(graph, opts.node);
  if (resolved === null) {
    return {
      kind: 'unknown',
      node: opts.node,
      notice: `No code node matching '${opts.node}' in the '${opts.slug}' code map (0 neighbors).`,
    };
  }
  // Garbage/negative env falls back to the default (adversarial-review fix:
  // `Number(env)||default` let a negative through, and .slice(0, -N) CORRUPTS
  // the result instead of capping it). Explicit opts.max is the caller's
  // contract (the MCP schema floors it); env is the operator boundary.
  const envMax = Number(process.env.SB_CODEMAP_NEIGHBORS_MAX);
  const cap = opts.max ?? (Number.isFinite(envMax) && envMax > 0 ? Math.floor(envMax) : DEFAULT_NEIGHBORS_MAX);

  if ('matches' in resolved) {
    // Same cap as every other list this tool emits — an adversarial basename
    // ('index' in a huge repo) must not blow the egress budget via the
    // disambiguation list itself.
    const capped = resolved.matches.slice(0, cap);
    const more = resolved.matches.length - capped.length;
    return {
      kind: 'ambiguous',
      node: opts.node,
      matches: capped,
      note: `Basename '${opts.node}' is ambiguous -- ${resolved.matches.length} files match${more > 0 ? ` (showing ${capped.length})` : ''}; re-query with one full id.`,
    };
  }

  const rows = bfs(graph.edges, resolved.id, direction, depth);
  return {
    kind: 'ok',
    node: resolved.id,
    direction,
    depth,
    neighbors: rows.slice(0, cap),
    truncated: rows.length > cap,
    stale: await isStale(graph, graph.repo_root, opts.runGit),
  };
}
