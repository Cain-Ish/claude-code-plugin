import { promises as fs, realpathSync, existsSync } from 'fs';
import { homedir } from 'os';
import { join, resolve, sep, isAbsolute, parse, win32 } from 'path';
import { assertSafeSlug, cleanEnvPath } from '../path-guard.js';
import type { DocEntry } from './doc-sources.js';

// Split out of doc-sources.ts (audit N3, re-audit A2): the registry reader and the serve-time filter
// must not pull in `glob` (scanLocations' dependency): knowledge-search.ts runs in per-prompt CLIs.
export interface DocRegistry { generated_at: string; project: string; entries: DocEntry[]; }

export function registryPath(brainDir: string, slug: string): string {
  return join(brainDir, 'projects', slug, 'doc-sources.json');
}

export async function loadRegistry(brainDir: string, slug: string): Promise<DocRegistry | null> {
  try { assertSafeSlug(slug); return JSON.parse(await fs.readFile(registryPath(brainDir, slug), 'utf-8')); }
  catch { return null; }
}

/** The registry entries a search may offer the model, and why the rest were refused. */
export interface ServableEntries {
  kept: DocEntry[];
  /** Absolute, existing, but its realpath is not inside the project root's realpath (a forged
   *  entry, a link out of the project), or no usable root. */
  outside: number;
  /** Outside the root, but the entry's path ends in its own `rel` and that `rel` names a file under
   *  the root: the registry was built in another checkout of the project (a worktree sharing the
   *  slug). Counted apart from `outside` for the audit row (review 2, P-F5); never served. */
  otherCheckout: number;
  /** Not a plain absolute path (isPlainAbsolutePath): relative, drive-relative, or with a `.`/`..` segment. */
  relative: number;
  /** Absolute but realpath failed: the file is gone (a stale registry) or unreadable. */
  missing: number;
  /** Not a DocEntry (wrong field types): a hand-edited or forged registry. */
  malformed: number;
  rootUsable: boolean;
  /** Why the root serves or not: ok; unusable (none given, or its realpath failed); home (the home
   *  directory or a directory that contains it); fs-root (a filesystem or drive root). A root that
   *  holds the home directory would make ~/.bash_history or ~/.env servable (review 2, P-S7). */
  rootStatus: 'ok' | 'unusable' | 'home' | 'fs-root';
}

function isDocEntry(e: unknown): e is DocEntry {
  if (!e || typeof e !== 'object') return false;
  const o = e as Record<string, unknown>;
  return typeof o.path === 'string' && typeof o.gist === 'string' && typeof o.mtime === 'string'
    && typeof o.size === 'number' && Array.isArray(o.headings) && o.headings.every((h) => typeof h === 'string');
}

/** A path a local-doc "Read <path>" line may print on `platform`: absolute in that platform's own
 *  form (Windows: a drive path `C:\…`/`C:/…` or a UNC path `\\server\share\…`; elsewhere `/…`) and
 *  with no `.` or `..` segment. servableEntries checks the REALPATH but the line prints the path as
 *  registered, so `/proj/link/../../../home/u/.ssh/id_rsa` (an in-project link to a deep directory)
 *  passed the realpath check while naming a file outside the project once read lexically (review 2,
 *  P-T1). On Windows `\proj\x.md` is drive-relative and node reads `/c/…` as `C:\c\…` (P-T6). */
export function isPlainAbsolutePath(p: string, platform: NodeJS.Platform = process.platform): boolean {
  const absolute = platform === 'win32' ? /^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])/.test(p) : p.startsWith('/');
  return absolute && !p.split(/[\\/]/).some((seg) => seg === '.' || seg === '..');
}

/** realpath with the platform's canonical spelling; compared case-insensitively on Windows. */
function canonicalReal(p: string): string {
  const r = realpathSync.native(p);
  return process.platform === 'win32' ? r.toLowerCase() : r;
}

/** `root` (canonical) is a filesystem/drive root, the home directory or one of its ancestors. A
 *  home directory whose realpath fails is compared by its lexical spelling. */
function rootStatusOf(root: string, home: string): ServableEntries['rootStatus'] {
  if (parse(root).root === root) return 'fs-root';
  if (!home) return 'ok';
  let h: string;
  try { h = canonicalReal(home); } catch {
    h = resolve(home);
    if (process.platform === 'win32') h = h.toLowerCase();
  }
  return h === root || h.startsWith(root.endsWith(sep) ? root : root + sep) ? 'home' : 'ok';
}

/** An entry outside `root` (canonical) that the registry scan of another checkout would have
 *  written: its path ends in /<rel> and <root>/<rel> exists. One stat, only for outside entries. */
function fromOtherCheckout(e: DocEntry, root: string): boolean {
  const rel = typeof e.rel === 'string' ? e.rel : '';
  if (!rel || isAbsolute(rel) || win32.isAbsolute(rel) || rel.split(/[\\/]/).some((s) => s === '' || s === '.' || s === '..')) return false;
  let path = e.path.replace(/\\/g, '/'), tail = `/${rel.replace(/\\/g, '/')}`;
  if (process.platform === 'win32') { path = path.toLowerCase(); tail = tail.toLowerCase(); }
  return path.endsWith(tail) && existsSync(join(root, rel));
}

/** X2 (R3 review): doc-sources.json is plain JSON under BRAIN_DIR with no guard, and its paths
 *  reach every prompt as "Read <path>" lines. An entry is served only when it is a well-formed
 *  DocEntry whose path is plain and absolute (isPlainAbsolutePath) and whose realpath lies inside the
 *  realpath of `projectRoot`, so neither a forged entry (path: ~/.netrc) nor a link inside the
 *  project that leads out of it is offered. No usable root -> nothing is served (fails closed); a
 *  root that is a filesystem root or holds `home` is not usable (rootStatus says which). */
export function servableEntries(entries: unknown, projectRoot: string | undefined, home: string = homedir()): ServableEntries {
  const r: ServableEntries = {
    kept: [], outside: 0, otherCheckout: 0, relative: 0, missing: 0, malformed: 0, rootUsable: false, rootStatus: 'unusable',
  };
  let root = '';
  try {
    if (projectRoot) { root = canonicalReal(cleanEnvPath(projectRoot)); r.rootStatus = rootStatusOf(root, home); }
  } catch { /* no usable root: every entry counts as outside */ }
  r.rootUsable = r.rootStatus === 'ok';
  const prefix = root.endsWith(sep) ? root : root + sep;
  for (const e of Array.isArray(entries) ? entries : []) {
    if (!isDocEntry(e)) { r.malformed++; continue; }
    if (!isPlainAbsolutePath(e.path)) { r.relative++; continue; }
    let real: string;
    try { real = canonicalReal(e.path); } catch { r.missing++; continue; }
    if (!r.rootUsable || !real.startsWith(prefix)) {
      if (r.rootUsable && fromOtherCheckout(e, root)) r.otherCheckout++; else r.outside++;
      continue;
    }
    r.kept.push(e);
  }
  return r;
}
