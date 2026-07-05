/**
 * Deterministic PageRank over the code-map import graph (P3a Task A3).
 *
 * Determinism is a TESTED contract — code_map's token-capped slice must be
 * byte-stable across runs AND platforms, so float summation order is pinned:
 *   - nodes iterate in sorted id order;
 *   - each node's in-neighbor contributions accumulate in sorted source-id
 *     order (edge list is sorted before adjacency build — never rely on Map
 *     insertion order for sums: (a+b)+c !== a+(b+c) in IEEE-754);
 *   - dangling-node mass is summed in sorted node order and redistributed
 *     uniformly (keeps ranks a probability distribution, sum == 1);
 *   - fixed default 30 iterations OR L1 convergence < 1e-6, whichever first.
 * Duplicate edges are counted as given (proportional weight); the caller
 * (build-graph.ts) dedupes for the import graph.
 */

export interface PagerankOpts {
  /** teleport damping factor, default 0.85; must be in [0,1) */
  damping?: number;
  /** fixed iteration cap, default 30 */
  iterations?: number;
  /** L1 early-stop threshold, default 1e-6 */
  epsilon?: number;
}

export function pagerank(
  nodes: string[],
  edges: Array<[string, string]>,
  opts: PagerankOpts = {},
): Map<string, number> {
  const damping = opts.damping ?? 0.85;
  const iterations = opts.iterations ?? 30;
  const epsilon = opts.epsilon ?? 1e-6;
  if (!(damping >= 0 && damping < 1)) {
    throw new Error(`pagerank: damping must be in [0,1), got ${damping}`);
  }
  if (!Number.isInteger(iterations) || iterations < 1) {
    throw new Error(`pagerank: iterations must be a positive integer, got ${iterations}`);
  }
  if (!(epsilon > 0)) {
    throw new Error(`pagerank: epsilon must be > 0, got ${epsilon}`);
  }

  const ids = [...new Set(nodes)].sort();
  const n = ids.length;
  const result = new Map<string, number>();
  if (n === 0) return result;

  const index = new Map<string, number>(ids.map((id, i) => [id, i]));
  const outDeg = new Array<number>(n).fill(0);
  // Sorting edges by (from, to) makes each target's in-neighbor list arrive in
  // sorted source order, which pins the accumulation order below.
  const sortedEdges = [...edges].sort((a, b) =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0,
  );
  const inNbrs: number[][] = Array.from({ length: n }, () => []);
  for (const [from, to] of sortedEdges) {
    const f = index.get(from);
    const t = index.get(to);
    if (f === undefined || t === undefined) {
      throw new Error(`pagerank: edge ${from} -> ${to} references a node not in the node list`);
    }
    outDeg[f]!++;
    inNbrs[t]!.push(f);
  }

  const base = (1 - damping) / n;
  let rank = new Array<number>(n).fill(1 / n);
  for (let iter = 0; iter < iterations; iter++) {
    let dangling = 0;
    for (let i = 0; i < n; i++) {
      if (outDeg[i] === 0) dangling += rank[i]!;
    }
    const danglingShare = dangling / n;
    const next = new Array<number>(n);
    let l1 = 0;
    for (let i = 0; i < n; i++) {
      let acc = 0;
      for (const src of inNbrs[i]!) acc += rank[src]! / outDeg[src]!;
      const v = base + damping * (acc + danglingShare);
      next[i] = v;
      l1 += Math.abs(v - rank[i]!);
    }
    rank = next;
    if (l1 < epsilon) break;
  }

  for (let i = 0; i < n; i++) result.set(ids[i]!, rank[i]!);
  return result;
}
