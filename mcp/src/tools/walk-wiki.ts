// Shared recursive wiki walker — replaces five hand-rolled readdir walkers and
// two glob('**/*.md') calls whose skip rules (index.md, dot-dirs, generated MOC
// dirs) and path separators had quietly diverged. Dependency-free (fs + path
// only) so CLI bundles can import it without the glob tree.
import { promises as fs } from 'fs';
import { join } from 'path';

export interface WalkWikiOpts {
  /** Include index.md files (default false — index.md is a generated catalog, not content). */
  includeIndex?: boolean;
  /** Skip dot-entries: dot-dirs are pruned, dot-files dropped (glob's default semantics). */
  skipHidden?: boolean;
  /** Directory basenames pruned entirely (e.g. the generated MOC dirs ['projects', 'themes']). */
  skipDirs?: readonly string[];
  /** Normalize returned paths to forward slashes (the search-result path contract). */
  posix?: boolean;
}

/** All .md files under `dir`, recursively. Tolerant: an unreadable/missing
 *  directory contributes nothing instead of discarding the rest of the walk. */
export async function walkWiki(dir: string, opts: WalkWikiOpts = {}, acc: string[] = []): Promise<string[]> {
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of entries) {
    if (opts.skipHidden && e.name.startsWith('.')) continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (opts.skipDirs?.includes(e.name)) continue;
      await walkWiki(p, opts, acc);
    } else if (e.isFile() && e.name.endsWith('.md') && (opts.includeIndex || e.name !== 'index.md')) {
      acc.push(opts.posix ? p.replace(/\\/g, '/') : p);
    }
  }
  return acc;
}
