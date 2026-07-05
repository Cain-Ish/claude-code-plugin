/**
 * Code-graph assembly (P3a Task A3): scanned files + per-file extraction ->
 * CodeGraph with deterministic PageRank ranks.
 *
 * v1 ranks the FILE import graph only; symbol nodes inherit their file's rank
 * (plan-sanctioned — symbol-reference weighting is the Tier-1 upgrade).
 *
 * Imports pointing outside the scanned set are dropped, NOT an error: the
 * scan's size caps (SB_CODEMAP_MAX_FILES / SB_CODEMAP_MAX_FILE_BYTES) may have
 * truncated the target file, and extraction resolves specifiers without seeing
 * those caps. Self-imports are dropped too (regex extraction can misfire; a
 * self-loop adds no orientation signal). A scanned file MISSING from
 * `extracted` is a caller bug and throws (fail loud).
 *
 * Byte-identical output for identical input regardless of array/Map ordering:
 * collections are re-sorted internally; the timestamp comes from meta (no
 * Date.now() here — the CLI boundary owns wall-clock).
 */

import type {
  CodeEdge,
  CodeGraph,
  ExtractResult,
  FileNode,
  ScannedFile,
  SymbolNode,
} from './types.js';
import { pagerank } from './pagerank.js';

export interface GraphMeta {
  slug: string;
  repoRoot: string;
  gitRev: string;
  dirty: boolean;
  generatedAt: string;
  truncated: boolean;
}

/** rank desc, id asc — the stable tie-break code_map's token-capped slice relies on. */
function byRankDescIdAsc(rankA: number, idA: string, rankB: number, idB: string): number {
  return rankB - rankA || (idA < idB ? -1 : idA > idB ? 1 : 0);
}

/** Extraction-order symbol names with duplicates removed (first kind wins) so
 *  `<file>#<name>` symbol ids stay unique. */
function dedupeSymbols(ex: ExtractResult): { name: string; kind: SymbolNode['kind'] }[] {
  const seen = new Set<string>();
  const out: { name: string; kind: SymbolNode['kind'] }[] = [];
  for (const s of ex.symbols) {
    if (seen.has(s.name)) continue;
    seen.add(s.name);
    out.push({ name: s.name, kind: s.kind });
  }
  return out;
}

export function buildGraph(
  scanned: ScannedFile[],
  extracted: Map<string, ExtractResult>,
  meta: GraphMeta,
): CodeGraph {
  const sortedScanned = [...scanned].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const known = new Set<string>();
  for (const f of sortedScanned) {
    if (known.has(f.id)) {
      throw new Error(`buildGraph: duplicate scanned id "${f.id}" (scan must emit unique ids)`);
    }
    known.add(f.id);
  }

  const edges: CodeEdge[] = [];
  const edgeKeys = new Set<string>();
  for (const f of sortedScanned) {
    const ex = extracted.get(f.id);
    if (!ex) {
      throw new Error(`buildGraph: no extraction result for "${f.id}" (extract every scanned file)`);
    }
    for (const imp of ex.imports) {
      if (imp === f.id || !known.has(imp)) continue;
      const key = f.id + '\u0000' + imp; // NUL can't occur in a path id
      if (edgeKeys.has(key)) continue;
      edgeKeys.add(key);
      edges.push({ from: f.id, to: imp, type: 'imports' });
    }
  }
  edges.sort((a, b) =>
    a.from < b.from ? -1 : a.from > b.from ? 1 : a.to < b.to ? -1 : a.to > b.to ? 1 : 0,
  );

  const ranks = pagerank(
    [...known],
    edges.map((e) => [e.from, e.to] as [string, string]),
  );

  const files: FileNode[] = sortedScanned.map((f) => ({
    id: f.id,
    lang: f.lang,
    rank: ranks.get(f.id)!,
    symbols: dedupeSymbols(extracted.get(f.id)!).map((s) => s.name),
  }));
  files.sort((a, b) => byRankDescIdAsc(a.rank, a.id, b.rank, b.id));

  const symbols: SymbolNode[] = [];
  for (const f of sortedScanned) {
    const rank = ranks.get(f.id)!;
    for (const s of dedupeSymbols(extracted.get(f.id)!)) {
      symbols.push({ id: `${f.id}#${s.name}`, kind: s.kind, file: f.id, rank });
    }
  }
  symbols.sort((a, b) => byRankDescIdAsc(a.rank, a.id, b.rank, b.id));

  return {
    schema: 1,
    slug: meta.slug,
    repo_root: meta.repoRoot,
    git_rev: meta.gitRev,
    dirty: meta.dirty,
    generated_at: meta.generatedAt,
    generator: 'regex-v1',
    truncated: meta.truncated,
    files,
    symbols,
    edges,
  };
}
