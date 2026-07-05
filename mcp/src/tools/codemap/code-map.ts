/**
 * P3a Task B1 -- code_map MCP tool core: read the per-project codemap store,
 * return the token-capped map + provenance + a query-time stale flag.
 *
 * Read-only. The map is re-serialized from graph.json (the machine tier)
 * instead of reading map.md so a caller-supplied token_budget takes effect at
 * query time; serialize owns the cap invariant.
 *
 * stale probes HEAD of graph.repo_root -- the store's own provenance, not the
 * querying process cwd -- so the comparison is always against the repo that
 * was actually mapped. 'nogit' from the probe (repo gone, git absent, no
 * commits) is tolerated as NOT stale: with no rev there is nothing honest to
 * compare, and a false 'stale' would teach the model to distrust a good map.
 * A 'nogit' STORE facing a real current rev IS stale (the repo gained
 * history since generation). Full drift semantics (dirty-tree, mtime) land in
 * Phase 3 drift.ts; this is the cheap query-time subset the plan asks for.
 */

import { execFile } from 'child_process';
import { promisify } from 'util';
import { codemapDir, readGraph } from './store.js';
import { serialize } from './serialize.js';

const execFileAsync = promisify(execFile);

/** HEAD sha of repoRoot, or 'nogit' on any git failure. Exported so
 *  code_neighbors (Phase 3) and tests share one probe shape. */
export async function currentRev(repoRoot: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync('git', ['rev-parse', 'HEAD'], {
      cwd: repoRoot,
      windowsHide: true,
    });
    return stdout.trim() || 'nogit';
  } catch {
    return 'nogit';
  }
}

export interface CodeMapOpts {
  brainDir: string;
  slug: string;
  tokenBudget?: number;
  /** injectable for tests (offline, deterministic); default shells `git rev-parse HEAD` */
  revProbe?: (repoRoot: string) => Promise<string>;
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
  const current = await (opts.revProbe ?? currentRev)(graph.repo_root);
  return {
    kind: 'ok',
    map: opts.tokenBudget === undefined ? serialize(graph) : serialize(graph, opts.tokenBudget),
    generated_at: graph.generated_at,
    git_rev: graph.git_rev,
    generator: graph.generator,
    stale: current !== 'nogit' && current !== graph.git_rev,
    truncated: graph.truncated,
  };
}
