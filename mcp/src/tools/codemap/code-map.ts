/**
 * code_map MCP tool core: read the per-project codemap store,
 * return the token-capped map + provenance + a query-time stale flag.
 *
 * Read-only. The map is re-serialized from graph.json (the machine tier)
 * instead of reading map.md so a caller-supplied token_budget takes effect at
 * query time; serialize owns the cap invariant.
 *
 * stale comes from drift.ts::isStale (the SINGLE drift source -- the
 * CLI's --check gate runs the identical predicate), probed against HEAD of
 * graph.repo_root -- the store's own provenance, not the querying process cwd
 * -- so the comparison is always against the repo that was actually mapped.
 * That single-sourcing means a probe returning 'nogit' against a sha store IS
 * stale (repo vanished or lost git -- the map's provenance can no longer be
 * verified), a 'nogit' store facing a real rev IS stale (the repo gained
 * history), and a graph generated from a dirty tree is ALWAYS stale.
 */

import { codemapDir, readGraph } from './store.js';
import { serialize } from './serialize.js';
import { isStale } from './drift.js';
import type { GitRunner } from './scan-sources.js';

export interface CodeMapOpts {
  brainDir: string;
  slug: string;
  tokenBudget?: number;
  /** injectable for tests (offline, deterministic); default shells out to git */
  runGit?: GitRunner;
}

export type CodeMapResult =
  | { kind: 'missing'; notice: string }
  | {
      kind: 'ok';
      map: string;
      generated_at: string;
      git_rev: string;
      generator: string;
      stale: boolean;
      truncated: boolean;
    };

export async function codeMap(opts: CodeMapOpts): Promise<CodeMapResult> {
  // Corrupt/foreign-schema stores THROW out of readGraph (fail loud) -- only
  // the absent-store first-run state is a normal notice.
  const graph = await readGraph(codemapDir(opts.brainDir, opts.slug));
  if (graph === null) {
    return {
      kind: 'missing',
      notice: `Code map for '${opts.slug}' not generated yet -- it regenerates automatically out-of-band (drainer tick); retry later or run the code-map CLI manually.`,
    };
  }
  return {
    kind: 'ok',
    map: opts.tokenBudget === undefined ? serialize(graph) : serialize(graph, opts.tokenBudget),
    generated_at: graph.generated_at,
    git_rev: graph.git_rev,
    generator: graph.generator,
    stale: await isStale(graph, graph.repo_root, opts.runGit),
    truncated: graph.truncated,
  };
}
