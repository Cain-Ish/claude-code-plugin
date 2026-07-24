import { readFileSync } from 'fs';
import { join } from 'path';
import { cleanEnvPath } from '../path-guard.js';
import { normalizeRemote } from '../brain-paths.js';

export interface ProjectRecord {
  slug: string;
  name?: string;
  last_session_iso?: string;
  hot_byte_count?: number;
  parent?: string;     // monorepo root slug; absent = standalone/root (Phase B, M3)
  root_path?: string;  // absolute project dir; absent = legacy record (Phase B, M3)
  git_remote?: string; // origin remote URL — the project's identity; absent = remote-less/legacy
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
 *  /repos/acme-other. Returns the slug of the deepest matching root_path, or undefined.
 *
 *  norm() canonicalizes both sides to MSYS form so Windows paths (C:\x, C:/x) and MSYS paths
 *  (/c/x) compare equal. This is necessary because bash session-load.sh writes root_path via
 *  `pwd` in Git Bash (MSYS form: /c/...) while the Node MCP server receives CLAUDE_PROJECT_DIR
 *  or process.cwd() in Windows form (C:\... or C:/...). Mirrors toBashPath() in dream.ts. */
export function resolveSlugByPath(brainDir: string, dir: string): string | undefined {
  const norm = (p: string) => {
    let s = cleanEnvPath(p).replace(/\\/g, '/');
    // Canonicalize Windows drive letter to MSYS form: C:/x → /c/x
    const drive = s.match(/^([A-Za-z]):\//);
    if (drive) s = '/' + drive[1].toLowerCase() + s.slice(2);
    return s.replace(/\/+$/, '');
  };
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

/** Resolve a registered slug by git-remote identity: the record whose normalized
 *  git_remote equals the normalized input owns the remote. The origin remote is the
 *  project identity, so a re-clone under a new folder name maps back to its existing
 *  project. When several slugs share one remote (pre-dedupe registries), the slug
 *  equal to the remote's repo basename wins, else the newest last_session_iso —
 *  the same selection sb_slug_from_remote's jq (rkeep) applies on the bash side.
 *  Returns undefined for an empty/unmatched remote (callers fall back to basename). */
export function resolveSlugByRemote(brainDir: string, rawRemote: string): string | undefined {
  const want = normalizeRemote(rawRemote);
  if (!want) return undefined;
  const matches = loadRegistry(brainDir).filter(
    r => typeof r.git_remote === 'string' && r.git_remote !== '' && normalizeRemote(r.git_remote) === want
  );
  if (matches.length === 0) return undefined;
  const base = want.replace(/.*\//, '');
  const byBase = matches.find(r => r.slug === base);
  if (byBase) return byBase.slug;
  return matches.reduce((a, b) => ((b.last_session_iso ?? '') > (a.last_session_iso ?? '') ? b : a)).slug;
}
