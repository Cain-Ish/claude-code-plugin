/**
 * P3a Task C1 — drift detection: is the stored code graph stale relative to
 * the repo it was generated from?
 *
 * SINGLE SOURCE for staleness (plan Task C1): the CLI's --check/regen gate AND
 * the code_map MCP tool's query-time `stale` flag both call isStale — no
 * second drift implementation may exist.
 *
 * stale <=> graph.dirty                       (a graph generated from a dirty
 *           tree was never pinned by its recorded rev — ALWAYS re-check)
 *       OR  graph.git_rev !== currentRev      (HEAD moved, or the repo gained/
 *           lost history — both directions are honest mismatches)
 *       OR  both 'nogit' AND newest tracked-source mtime > graph.generated_at
 *           (no rev to compare — fall to the filesystem clock; deletions are
 *           invisible to an mtime walk, an accepted limit of the nogit tier)
 *
 * runGit is injectable (the same GitRunner shape scan-sources.ts uses) so unit
 * tests never spawn a real git.
 */
import { stat } from 'fs/promises';
import { defaultRunGit, scanSources } from './scan-sources.js';
import type { GitRunner } from './scan-sources.js';
import type { CodeGraph } from './types.js';

/** HEAD sha of repoRoot, or 'nogit' on any git failure (no repo, no git, no commits). */
export async function currentRev(
  repoRoot: string,
  runGit: GitRunner = defaultRunGit,
): Promise<string> {
  try {
    const out = await runGit(['rev-parse', 'HEAD'], repoRoot);
    return out.trim() || 'nogit';
  } catch {
    return 'nogit';
  }
}

/** Working tree has uncommitted changes; false on 'nogit' (no tree to be dirty against). */
export async function isDirty(
  repoRoot: string,
  runGit: GitRunner = defaultRunGit,
): Promise<boolean> {
  try {
    const out = await runGit(['status', '--porcelain'], repoRoot);
    return out.trim().length > 0;
  } catch {
    return false;
  }
}

export async function isStale(
  graph: CodeGraph,
  repoRoot: string,
  runGit: GitRunner = defaultRunGit,
): Promise<boolean> {
  // Checked FIRST so the always-stale dirty case costs zero git spawns.
  if (graph.dirty) return true;
  const current = await currentRev(repoRoot, runGit);
  if (graph.git_rev !== current) return true;
  if (current !== 'nogit') return false;
  // Both sides 'nogit': compare the filesystem clock over the SAME source set
  // a regen would scan (scanSources honors the ignore dirs / lang filters, so
  // a churning node_modules can never fake staleness).
  const generatedAt = Date.parse(graph.generated_at);
  if (!Number.isFinite(generatedAt)) return true; // corrupt provenance -> regen
  let files;
  try {
    files = (await scanSources(repoRoot, { runGit })).files;
  } catch {
    return true; // repoRoot unreadable/vanished — freshness is unverifiable
  }
  for (const f of files) {
    let mtimeMs: number;
    try {
      mtimeMs = (await stat(f.abs)).mtimeMs;
    } catch {
      continue; // scanned-then-vanished race: a missing file cannot postdate the map
    }
    if (mtimeMs > generatedAt) return true;
  }
  return false;
}
