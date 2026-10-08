import { promises as fs, realpathSync } from 'fs';
import { join, relative, resolve, sep, isAbsolute } from 'path';
import { spawnSync } from 'child_process';
import { glob } from 'glob';
import { assertSafeSlug, cleanEnvPath } from '../path-guard.js';
import { hashContent } from './content-hash.js';
import { matchFrontmatter, extractYamlValue } from './frontmatter.js';

/** Gist = first H1 / frontmatter title / first non-empty line. Deterministic, no LLM. */
export function extractGist(content: string): string {
  const fm = matchFrontmatter(content);
  const body = fm ? fm.body : content;
  const h1 = body.match(/^#\s+(.+)$/m);
  if (h1) return h1[1].trim();
  if (fm) {
    const t = extractYamlValue(fm.fm, 'title');
    if (t) return t;
  }
  const first = body.split('\n').map((l) => l.trim()).find((l) => l.length > 0);
  return first ?? '';
}

/** H2/H3 headings, in order (excludes the H1 title). */
export function extractHeadings(content: string): string[] {
  return content.split('\n').map((l) => l.trim()).filter((l) => /^#{2,3}\s+\S/.test(l));
}

export interface DocSourceConfig { locations: string[]; }
export interface DocEntry {
  id: string; path: string; rel: string; gist: string;
  headings: string[]; hash: string; mtime: string; size: number;
}

const JUNK_DIRS = new Set(['node_modules', '.git', '.venv', 'venv', '.next', 'dist', 'build']);

export async function readConfig(brainDir: string, slug: string): Promise<DocSourceConfig> {
  try {
    const j = JSON.parse(await fs.readFile(join(brainDir, 'projects', slug, 'doc-sources.config.json'), 'utf-8'));
    return { locations: Array.isArray(j.locations) ? j.locations : [] };
  } catch { return { locations: [] }; }
}

/** Drop junk dirs always; then drop git-ignored paths via `git check-ignore` when in a repo. */
export function filterIgnored(projectRoot: string, absPaths: string[]): string[] {
  projectRoot = cleanEnvPath(projectRoot);   // CR-tainted root → `git -C <root>\r` fails → all files mis-classified
  const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split(/[\\/]+/).some((seg) => JUNK_DIRS.has(seg)));
  if (nonJunk.length === 0) return [];
  // git check-ignore reasons over POSIX paths; backslash rels make git C-quote its
  // stdout (e.g. "docs\\secret.md"), which then never matches a real abs path below.
  const rels = nonJunk.map((p) => relative(projectRoot, p).split(/[\\/]+/).join('/'));
  const res = spawnSync('git', ['-C', projectRoot, 'check-ignore', '--stdin'], { input: rels.join('\n'), encoding: 'utf-8' });
  // status 0 = some ignored (listed on stdout); 1 = none ignored; other (128/ENOENT) = not a repo / no git → junk-skip only
  if (res.status === 0 || res.status === 1) {
    const ignored = new Set((res.stdout || '').split('\n').filter(Boolean).map((r) => join(projectRoot, r)));
    return nonJunk.filter((p) => !ignored.has(p));
  }
  return nonJunk;
}

export async function scanLocations(projectRoot: string, locations: string[]): Promise<DocEntry[]> {
  projectRoot = cleanEnvPath(projectRoot);   // CR-tainted root → glob cwd ENOENT → empty scan
  const seen = new Set<string>();
  const absPaths: string[] = [];
  const rootResolved = resolve(projectRoot);
  const within = (p: string): boolean => {
    const r = resolve(p);
    return r === rootResolved || r.startsWith(rootResolved + sep);
  };
  for (const loc of locations) {
    const pattern = /[*?[\]{}]/.test(loc) ? loc : `${loc.replace(/\/+$/, '')}/**/*.md`;
    const matches = await glob(pattern, { cwd: projectRoot, absolute: true, nodir: true }).catch(() => [] as string[]);
    for (const m of matches) if (within(m) && !seen.has(m)) { seen.add(m); absPaths.push(m); }
  }
  const kept = filterIgnored(projectRoot, absPaths);
  const entries: DocEntry[] = [];
  for (const p of kept) {
    try {
      const content = await fs.readFile(p, 'utf-8');
      const st = await fs.stat(p);
      const hash = hashContent(content);
      entries.push({
        id: hash.slice(0, 12), path: p, rel: relative(projectRoot, p).split(/[\\/]+/).join('/'),
        gist: extractGist(content), headings: extractHeadings(content),
        hash, mtime: st.mtime.toISOString(), size: st.size,
      });
    } catch { /* unreadable — skip */ }
  }
  entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0)); // byte-stable, locale-independent
  return entries;
}

export interface DocRegistry { generated_at: string; project: string; entries: DocEntry[]; }

function registryPath(brainDir: string, slug: string): string {
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
   *  entry, a link out of the project, a registry built from another checkout), or no usable root. */
  outside: number;
  /** Not a plain absolute path (isPlainAbsolutePath): relative, drive-relative, or with a `.`/`..` segment. */
  relative: number;
  /** Absolute but realpath failed: the file is gone (a stale registry) or unreadable. */
  missing: number;
  /** Not a DocEntry (wrong field types): a hand-edited or forged registry. */
  malformed: number;
  rootUsable: boolean;
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

/** X2 (R3 review): doc-sources.json is plain JSON under BRAIN_DIR with no guard, and its paths
 *  reach every prompt as "Read <path>" lines. An entry is served only when it is a well-formed
 *  DocEntry whose path is plain and absolute (isPlainAbsolutePath) and whose realpath lies inside the
 *  realpath of `projectRoot`, so neither a forged entry (path: ~/.netrc) nor a link inside the
 *  project that leads out of it is offered. No usable root -> nothing is served (fails closed). */
export function servableEntries(entries: unknown, projectRoot: string | undefined): ServableEntries {
  const r: ServableEntries = { kept: [], outside: 0, relative: 0, missing: 0, malformed: 0, rootUsable: false };
  let root = '';
  try {
    if (projectRoot) { root = canonicalReal(cleanEnvPath(projectRoot)); r.rootUsable = true; }
  } catch { /* no usable root: every entry counts as outside */ }
  const prefix = root.endsWith(sep) ? root : root + sep;
  for (const e of Array.isArray(entries) ? entries : []) {
    if (!isDocEntry(e)) { r.malformed++; continue; }
    if (!isPlainAbsolutePath(e.path)) { r.relative++; continue; }
    let real: string;
    try { real = canonicalReal(e.path); } catch { r.missing++; continue; }
    if (!r.rootUsable || !real.startsWith(prefix)) { r.outside++; continue; }
    r.kept.push(e);
  }
  return r;
}

/** Scan the live FS (config-declared locations) and write the registry. The fresh
 *  scan IS the reconciled state: content-hash ids are stable across moves, removed
 *  files are simply absent, edits get a new hash. */
export async function buildRegistry(projectRoot: string, brainDir: string, slug: string): Promise<DocRegistry> {
  assertSafeSlug(slug);
  const { locations } = await readConfig(brainDir, slug);
  const entries = await scanLocations(projectRoot, locations);
  const reg: DocRegistry = { generated_at: new Date().toISOString(), project: slug, entries };
  await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
  const out = registryPath(brainDir, slug);
  const tmp = `${out}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(reg, null, 2));
  await fs.rename(tmp, out); // atomic
  return reg;
}

function normalizeLocation(location: string): string {
  return location.trim().replace(/^\.\//, '');
}

async function writeConfig(brainDir: string, slug: string, locations: string[]): Promise<void> {
  assertSafeSlug(slug);
  const dir = join(brainDir, 'projects', slug);
  const out = join(dir, 'doc-sources.config.json');
  await fs.mkdir(dir, { recursive: true });
  const tmp = `${out}.tmp`;
  await fs.writeFile(tmp, JSON.stringify({ locations }, null, 2));
  await fs.rename(tmp, out); // atomic
}

export async function listLocations(brainDir: string, slug: string): Promise<string[]> {
  assertSafeSlug(slug);
  return (await readConfig(brainDir, slug)).locations;
}

export async function addLocation(brainDir: string, slug: string, location: string): Promise<{ locations: string[]; added: boolean }> {
  assertSafeSlug(slug);
  const loc = normalizeLocation(location);
  if (!loc || isAbsolute(loc) || loc.split('/').includes('..') || loc.split('\\').includes('..')) {
    throw new Error(`invalid location: ${JSON.stringify(location)} (must be a relative path or glob within the project)`);
  }
  const cfg = await readConfig(brainDir, slug);
  if (cfg.locations.includes(loc)) return { locations: cfg.locations, added: false };
  const locations = [...cfg.locations, loc];
  await writeConfig(brainDir, slug, locations);
  return { locations, added: true };
}

export async function removeLocation(brainDir: string, slug: string, location: string): Promise<{ locations: string[]; removed: boolean }> {
  assertSafeSlug(slug);
  const loc = normalizeLocation(location);
  const cfg = await readConfig(brainDir, slug);
  const locations = cfg.locations.filter((l) => l !== loc);
  const removed = locations.length !== cfg.locations.length;
  if (removed) await writeConfig(brainDir, slug, locations);
  return { locations, removed };
}
