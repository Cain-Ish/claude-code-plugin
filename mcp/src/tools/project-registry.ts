import { readFileSync } from 'fs';
import { join } from 'path';
import { cleanEnvPath } from '../path-guard.js';

export interface ProjectRecord {
  slug: string;
  name?: string;
  last_session_iso?: string;
  hot_byte_count?: number;
  parent?: string;     // monorepo root slug; absent = standalone/root (Phase B, M3)
  root_path?: string;  // absolute project dir; absent = legacy record (Phase B, M3)
}

/** Read projects.jsonl tolerantly: one JSON object per line, blank/malformed lines skipped.
 *  Returns [] when the file is absent or unreadable. A hand-pretty-printed file is repaired by
 *  the Phase C migration, not silently mis-parsed here. */
export function loadRegistry(brainDir: string): ProjectRecord[] {
  let text: string;
  try { text = readFileSync(join(brainDir, 'projects.jsonl'), 'utf-8'); } catch { return []; }
  const out: ProjectRecord[] = [];
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s);
      if (r && typeof r.slug === 'string' && r.slug) out.push(r as ProjectRecord);
    } catch { /* skip malformed line */ }
  }
  return out;
}

/** The family of a project = its monorepo root + every project sharing that root + itself.
 *  root(X) = X.parent ?? X.slug. A standalone (no parent, no children) is its own singleton.
 *  An unregistered slug is its own singleton (degenerate — today's behavior). */
export function projectFamily(brainDir: string, slug: string): Set<string> {
  const recs = loadRegistry(brainDir);
  const self = recs.find(r => r.slug === slug);
  const root = self?.parent ?? slug;
  const fam = new Set<string>([slug, root]);
  for (const r of recs) if ((r.parent ?? r.slug) === root) fam.add(r.slug);
  return fam;
}

/** Resolve which registered project owns `dir` by LONGEST-PREFIX match of `dir` against each
 *  record's root_path. Path-segment aware: /repos/acme matches /repos/acme/x but NOT
 *  /repos/acme-other. Returns the slug of the deepest matching root_path, or undefined. */
export function resolveSlugByPath(brainDir: string, dir: string): string | undefined {
  const norm = (p: string) => cleanEnvPath(p).replace(/\\/g, '/').replace(/\/+$/, '');
  const target = norm(dir);
  let best: { slug: string; len: number } | undefined;
  for (const r of loadRegistry(brainDir)) {
    if (!r.root_path) continue;
    const rp = norm(r.root_path);
    if (target === rp || target.startsWith(rp + '/')) {
      if (!best || rp.length > best.len) best = { slug: r.slug, len: rp.length };
    }
  }
  return best?.slug;
}
