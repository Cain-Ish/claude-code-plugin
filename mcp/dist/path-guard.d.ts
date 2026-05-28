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
export declare class PathGuardError extends Error {
    readonly baseDir: string;
    readonly candidate: string;
    constructor(message: string, baseDir: string, candidate: string);
}
export declare function assertWithin(baseDir: string, ...parts: string[]): string;
/**
 * Validate a single slug-shaped string. Slugs are used as both filenames and
 * URL-safe identifiers; we constrain them to a strict character set to make
 * path-traversal impossible at the syntactic layer (defense in depth — the
 * realpath check in assertWithin catches anything we miss).
 *
 * Allowed: [a-zA-Z0-9._-], length 1–128, no leading dot.
 */
export declare function validateSlug(slug: string): void;
//# sourceMappingURL=path-guard.d.ts.map