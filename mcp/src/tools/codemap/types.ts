/**
 * P3a orientation code-map — shared type contract (spec layer 4).
 * Plan: docs/superpowers/plans/2026-06-30-p3a-orientation-code-map.md.
 *
 * Node ids are POSIX-relative paths ('/' separators on every OS) so a graph
 * generated on Windows compares/queries identically on Linux CI. Symbol ids
 * are `<file-id>#<symbol-name>`.
 *
 * Store location (Task A4): BRAIN_DIR/projects/<slug>/codemap/ — the CODE
 * graph is deliberately separate from the wiki graph (KNOWLEDGE_DIR/graph);
 * see the plan's "Separation from the wiki graph" table.
 */

export type Lang = 'ts' | 'js' | 'py';

export interface ScannedFile {
  /** POSIX-relative id, e.g. "src/tools/foo.ts" */
  id: string;
  /** absolute path on this machine (never persisted into graph.json nodes) */
  abs: string;
  lang: Lang;
}

export type SymbolKind = 'function' | 'class' | 'const' | 'default' | 'method';

export interface ExtractedSymbol {
  name: string;
  kind: SymbolKind;
}

export interface ExtractResult {
  symbols: ExtractedSymbol[];
  /** RESOLVED internal ids only (relative specifiers mapped to a ScannedFile id). */
  imports: string[];
  /** count of bare/package specifiers (external — not graph edges, kept for fan-out weight) */
  externalImports: number;
}

export interface FileNode {
  id: string;
  lang: Lang;
  rank: number;
  /** exported/top-level symbol names, rank-ordered with the file */
  symbols: string[];
}

export interface SymbolNode {
  /** `<file-id>#<name>` */
  id: string;
  kind: SymbolKind;
  file: string;
  rank: number;
}

export interface CodeEdge {
  from: string;
  to: string;
  type: 'imports';
}

export interface CodeGraph {
  schema: 1;
  slug: string;
  repo_root: string;
  /** git HEAD sha at generation, or 'nogit' (drift key, Phase 3) */
  git_rev: string;
  /** working tree had uncommitted changes at generation */
  dirty: boolean;
  generated_at: string;
  generator: 'regex-v1';
  /** set when SB_CODEMAP_MAX_FILES / SB_CODEMAP_MAX_FILE_BYTES dropped files */
  truncated: boolean;
  files: FileNode[];
  symbols: SymbolNode[];
  edges: CodeEdge[];
}
