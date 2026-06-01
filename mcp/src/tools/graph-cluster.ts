/**
 * Deterministic in-memory community detection for the dream SUMMARIZE phase.
 * Label propagation (Graphiti's choice over Leiden, for cheap incremental updates),
 * made fully deterministic so it is unit-testable and reproducible:
 *   - synchronous rounds (every node's next label is computed from the PREVIOUS
 *     round's labels, so within-round visit order is irrelevant);
 *   - nodes iterated in lexicographic slug order;
 *   - tie-break: keep the node's own current label if it is among the tied plurality
 *     (this also breaks the 2-cycle oscillation pure synchronous label-prop suffers
 *     on bipartite-ish structure), else take the smallest slug among the tied labels;
 *   - deterministic cutoff at maxIter.
 * Labels ARE slugs; a community's id is the lexicographically-smallest slug among its
 * members. No graph DB, no dependency. Spec: docs/specs/2026-06-01-dream-consolidation-v2-design.md §B1.1.
 */

export interface ClusterPage {
  slug: string;
  related: string[];
  bodyLinks: string[];
}

export interface Cluster {
  id: string;
  members: string[];
}

/** Undirected adjacency from each page's related: + body [[links]]; self-loops and
 *  links to unknown slugs are ignored. */
export function buildAdjacency(pages: ClusterPage[]): Map<string, Set<string>> {
  const known = new Set(pages.map(p => p.slug));
  const adj = new Map<string, Set<string>>();
  const ensure = (s: string): Set<string> => {
    let x = adj.get(s);
    if (!x) { x = new Set(); adj.set(s, x); }
    return x;
  };
  for (const p of pages) {
    ensure(p.slug);
    for (const n of new Set([...(p.related ?? []), ...(p.bodyLinks ?? [])])) {
      if (n === p.slug || !known.has(n)) continue;
      ensure(p.slug).add(n);
      ensure(n).add(p.slug);
    }
  }
  return adj;
}

/** Relabel each label-group to the smallest slug among its members (community id). */
function normalize(labels: Map<string, string>): Map<string, string> {
  const groups = new Map<string, string[]>();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) { g = []; groups.set(lab, g); }
    g.push(node);
  }
  const out = new Map<string, string>();
  for (const members of groups.values()) {
    const id = [...members].sort()[0];
    for (const m of members) out.set(m, id);
  }
  return out;
}

export interface LabelOpts { maxIter?: number; }

export function labelPropagate(adj: Map<string, Set<string>>, opts: LabelOpts = {}): Map<string, string> {
  const maxIter = opts.maxIter ?? 20;
  const nodes = [...adj.keys()].sort();
  let labels = new Map<string, string>(nodes.map(n => [n, n]));

  for (let iter = 0; iter < maxIter; iter++) {
    const next = new Map<string, string>();
    let changed = false;
    for (const node of nodes) {
      const own = labels.get(node)!;
      const nbrs = adj.get(node)!;
      if (nbrs.size === 0) { next.set(node, own); continue; }
      const tally = new Map<string, number>();
      for (const nb of nbrs) {
        const l = labels.get(nb)!;
        tally.set(l, (tally.get(l) ?? 0) + 1);
      }
      const max = Math.max(...tally.values());
      const tied = [...tally.entries()].filter(([, c]) => c === max).map(([l]) => l);
      const chosen = tied.includes(own) ? own : tied.sort()[0];
      next.set(node, chosen);
      if (chosen !== own) changed = true;
    }
    labels = next;
    if (!changed) break;
  }
  return normalize(labels);
}

/** Single synchronous step: assign a new node the plurality community of its current
 *  neighbours (smallest-slug tie-break). Returns the node's own slug if it has no
 *  labelled neighbours. */
export function assignNewNode(
  adj: Map<string, Set<string>>,
  labels: Map<string, string>,
  node: string,
): string {
  const nbrs = adj.get(node);
  if (!nbrs || nbrs.size === 0) return node;
  const tally = new Map<string, number>();
  for (const nb of nbrs) {
    const l = labels.get(nb);
    if (l !== undefined) tally.set(l, (tally.get(l) ?? 0) + 1);
  }
  if (tally.size === 0) return node;
  const max = Math.max(...tally.values());
  const tied = [...tally.entries()].filter(([, c]) => c === max).map(([l]) => l).sort();
  return tied[0];
}

/** Group a label map into clusters ≥ minSize, sorted by id, members sorted. */
export function clusters(labels: Map<string, string>, opts: { minSize: number }): Cluster[] {
  const groups = new Map<string, string[]>();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) { g = []; groups.set(lab, g); }
    g.push(node);
  }
  const out: Cluster[] = [];
  for (const [id, members] of groups) {
    if (members.length >= opts.minSize) out.push({ id, members: [...members].sort() });
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** Self-contained, content-aware djb2 hash over (sorted members + their content hashes),
 *  so a same-membership member-content change still triggers a theme-page refresh.
 *  Intentionally does NOT reuse embeddings.ts simpleHash (unexported + truncated text). */
export function memberHash(sortedMembers: string[], contentHashBySlug: Record<string, string>): string {
  const basis = sortedMembers.join('|') + '::' +
    sortedMembers.map(s => contentHashBySlug[s] ?? '').join('|');
  let h = 5381;
  for (let i = 0; i < basis.length; i++) {
    h = (((h << 5) + h) ^ basis.charCodeAt(i)) >>> 0;
  }
  return h.toString(36);
}
