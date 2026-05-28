import { resolve, sep, isAbsolute } from 'path';
import { realpathSync } from 'fs';

/**
 * Resolve `parts` against `baseDir`, then assert the resulting path stays
 * inside baseDir after symlink resolution. Throws on escape.
 *
 * Closes G-MCP-1 (wiki/security/plugin-hardening-gap-analysis-2026-05-28.md):
 * MCP tools take user-controlled string args (slug, category) that flowed
 * straight into `path.join` with no validation. The MCP Git server CVE
 * family (CVE-2025-68143/4/5) is the canonical anti-pattern: unsanitized
 * args becoming filesystem path / shell arg.
 *
 * Anthropic doctrine (engineering/how-we-contain-claude):
 *   "Symlink resolution has to happen before path validation, not after."
 *
 * Behavior:
 *  - Joins baseDir + parts via path.resolve (handles `..` collapsing).
 *  - For each ancestor directory that exists, realpath-resolves it so
 *    intermediate symlinks are followed. The leaf may not exist yet
 *    (write-targets), so missing-component tolerance is required.
 *  - Asserts the resolved leaf path starts with the resolved baseDir
 *    plus a path separator (or equals it exactly).
 *
 * Throws PathGuardError on:
 *  - resolved path outside baseDir
 *  - any `part` containing a NUL byte
 *  - any `part` that is itself absolute (would override baseDir)
 */
export class PathGuardError extends Error {
  constructor(message: string, public readonly baseDir: string, public readonly candidate: string) {
    super(message);
    this.name = 'PathGuardError';
  }
}

function realResolve(p: string): string {
  // Resolve as much of p as exists on disk; for the unresolvable tail (e.g.
  // a file we are about to write), keep the lexical form. We walk from the
  // root toward the leaf, taking realpath of each prefix that exists.
  let current = '';
  const segments = p.split(sep);
  // First segment may be '' (Unix absolute path starting with /).
  for (let i = 0; i < segments.length; i++) {
    const next = current === '' && segments[i] === '' ? sep : current === sep ? sep + segments[i] : current === '' ? segments[i] : current + sep + segments[i];
    try {
      current = realpathSync(next);
    } catch {
      // First missing component — append the rest of the segments lexically.
      const rest = segments.slice(i + 1).join(sep);
      return rest ? current + sep + segments[i] + sep + rest : current + sep + segments[i];
    }
  }
  return current;
}

export function assertWithin(baseDir: string, ...parts: string[]): string {
  for (const part of parts) {
    if (part.indexOf('\0') !== -1) {
      throw new PathGuardError(`path component contains NUL byte`, baseDir, parts.join('/'));
    }
    // Absolute parts would override baseDir in path.resolve — reject.
    if (isAbsolute(part)) {
      throw new PathGuardError(`absolute path component not allowed: ${JSON.stringify(part)}`, baseDir, parts.join('/'));
    }
  }
  const baseResolved = realResolve(resolve(baseDir));
  const candidate = resolve(baseDir, ...parts);
  const candidateResolved = realResolve(candidate);
  if (candidateResolved !== baseResolved && !candidateResolved.startsWith(baseResolved + sep)) {
    throw new PathGuardError(
      `path escapes base directory: ${candidateResolved} not within ${baseResolved}`,
      baseDir,
      parts.join('/')
    );
  }
  return candidateResolved;
}

/**
 * Validate a single slug-shaped string. Slugs are used as both filenames and
 * URL-safe identifiers; we constrain them to a strict character set to make
 * path-traversal impossible at the syntactic layer (defense in depth — the
 * realpath check in assertWithin catches anything we miss).
 *
 * Allowed: [a-zA-Z0-9._-], length 1–128, no leading dot.
 */
export function validateSlug(slug: string): void {
  if (typeof slug !== 'string') {
    throw new PathGuardError('slug must be a string', '', String(slug));
  }
  if (slug.length === 0 || slug.length > 128) {
    throw new PathGuardError(`slug length must be 1..128, got ${slug.length}`, '', slug);
  }
  if (slug.startsWith('.')) {
    throw new PathGuardError(`slug must not start with '.': ${JSON.stringify(slug)}`, '', slug);
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(slug)) {
    throw new PathGuardError(`slug contains disallowed characters: ${JSON.stringify(slug)}`, '', slug);
  }
}
