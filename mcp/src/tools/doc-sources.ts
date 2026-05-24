import { createHash } from 'crypto';
import { promises as fs } from 'fs';
import { join, relative, resolve, sep } from 'path';
import { spawnSync } from 'child_process';
import { glob } from 'glob';

export function hashContent(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}

/** Gist = first H1 / frontmatter title / first non-empty line. Deterministic, no LLM. */
export function extractGist(content: string): string {
  const fm = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  const body = fm ? content.slice(fm[0].length) : content;
  const h1 = body.match(/^#\s+(.+)$/m);
  if (h1) return h1[1].trim();
  if (fm) {
    const t = fm[1].match(/^title:\s*["']?(.+?)["']?\s*$/m);
    if (t) return t[1].trim();
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

function assertSafeSlug(slug: string): void {
  if (!slug || /[\\/]|\.\./.test(slug)) {
    throw new Error(`unsafe slug: ${JSON.stringify(slug)}`);
  }
}

export async function readConfig(brainDir: string, slug: string): Promise<DocSourceConfig> {
  try {
    const j = JSON.parse(await fs.readFile(join(brainDir, 'projects', slug, 'doc-sources.config.json'), 'utf-8'));
    return { locations: Array.isArray(j.locations) ? j.locations : [] };
  } catch { return { locations: [] }; }
}

/** Drop junk dirs always; then drop git-ignored paths via `git check-ignore` when in a repo. */
function filterIgnored(projectRoot: string, absPaths: string[]): string[] {
  const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split('/').some((seg) => JUNK_DIRS.has(seg)));
  if (nonJunk.length === 0) return [];
  const rels = nonJunk.map((p) => relative(projectRoot, p));
  const res = spawnSync('git', ['-C', projectRoot, 'check-ignore', '--stdin'], { input: rels.join('\n'), encoding: 'utf-8' });
  // status 0 = some ignored (listed on stdout); 1 = none ignored; other (128/ENOENT) = not a repo / no git → junk-skip only
  if (res.status === 0 || res.status === 1) {
    const ignored = new Set((res.stdout || '').split('\n').filter(Boolean).map((r) => join(projectRoot, r)));
    return nonJunk.filter((p) => !ignored.has(p));
  }
  return nonJunk;
}

export async function scanLocations(projectRoot: string, locations: string[]): Promise<DocEntry[]> {
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
        id: hash.slice(0, 12), path: p, rel: relative(projectRoot, p),
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
