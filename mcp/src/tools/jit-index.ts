// jit-index.ts — Just-In-Time repo memory index (Slice 2, docs/plans/2026-09-24-repo-brain.md §8).
// Pure builder (buildJitIndex) + one impure orchestrator (rebuildJitIndex) that loads wiki pages
// the same way knowledge-reindex.ts does (parseDoc + walkWiki), reads PROJECT.md's ## Conventions
// bullets, shells out to `git ls-files` for the repo file list, and writes the result atomically to
// $BRAIN_DIR/projects/<slug>/jit-index.json. protocol-guard.sh's pg_jit reads that file at the
// PreToolUse hot path (Read/Edit/Write/MultiEdit) to deliver path-triggered memory.
//
// Security: only ai-block FIELDS and PROJECT.md ## Conventions bullet TEXT are read — never page
// bodies (held-untrusted/ material is outside the wiki by construction, but a body can still carry
// attacker-influenced prose). Every line is sanitized (stripInvisible + control/backtick/CR/LF/
// backslash stripped, whitespace collapsed, capped at 160 chars) before it can reach the hot path's
// DATA banner.
import { promises as fs } from 'fs';
import { basename, join } from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { assertWithin, validateSlug } from '../path-guard.js';
import { resolveBrainDir } from '../brain-paths.js';
import { parseDoc } from './frontmatter.js';
import { walkWiki } from './walk-wiki.js';
import { stripInvisible } from './sanitize.js';
import { atomicWriteJson } from './atomic-write.js';

export type JitKind = 'lesson' | 'convention' | 'decision' | 'intent';

export interface JitItem {
  /** Wiki slug for lesson/decision/intent kinds; `conv:<1-based n>` for conventions. */
  id: string;
  kind: JitKind;
  /** bash `case` glob patterns: files exact, directories `dir/*`. 1-8 entries. */
  globs: string[];
  /** Sanitized, ≤160-char display line. */
  line: string;
}

/** Deterministic core the pure builder produces — no timestamps, so two calls with the
 *  same input are byte-identical (acceptance: determinism). */
export interface JitIndexCore {
  schema: 1;
  slug: string;
  items: JitItem[];
}

/** The full on-disk shape (JitIndexCore + the two fields only rebuildJitIndex can supply). */
export interface JitIndex extends JitIndexCore {
  generated_at: string;
  git_rev: string;
}

/** One wiki page's fields relevant to the JIT index — never the raw page body. */
export interface JitSourcePage {
  slug: string;
  /** Wiki sub-directory name (issues/learnings/decisions/concepts/...). */
  type: string;
  /** frontmatter `project:` facet. */
  project: string;
  aiBlock: Record<string, string>;
  /** decisions: an explicit status override (falls back to aiBlock.status). */
  status?: string;
}

export interface BuildJitIndexInput {
  slug: string;
  pages: JitSourcePage[];
  /** Raw PROJECT.md `## Conventions` bullet text (leading "- " already stripped). */
  conventions: string[];
  /** `git ls-files` output — POSIX-relative paths. Empty when the repo is unresolvable. */
  repoFiles: string[];
}

const MAX_ITEMS = 200;
const MAX_GLOBS_PER_ITEM = 8;
const LINE_CAP = 160;

// Control chars (incl. tab/CR/LF), C1 controls, and backtick — collapsed to a space. Backslash is
// stripped separately below: it survives this Unicode range but must never reach the bash side,
// where jq's `@tsv` escapes it and a literal `\\` in a delivered line is exactly what protocol-
// guard.sh's builder-must-reject-it contract (docs/plans/2026-09-24-repo-brain.md §D) forbids.
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f`\r\n]/g;

/** stripInvisible (Tags-block/zero-width) + control/backtick/CR/LF/backslash → space, collapse
 *  whitespace, trim. No length cap here — the cap applies to the ASSEMBLED line (see buildLine),
 *  not each field, so path-token extraction still sees the full sanitized text. */
function sanitizeRaw(s: string | undefined): string {
  if (!s) return '';
  let out = stripInvisible(s);
  out = out.replace(CONTROL_RE, ' ');
  out = out.replace(/\\/g, ' ');
  out = out.replace(/\s+/g, ' ').trim();
  return out;
}

/** Combine two sanitized fields as "A → B" (both present), or whichever one is present alone.
 *  Returns null when neither field has content — the page contributes no item. */
function buildLine(a: string | undefined, b: string | undefined): string | null {
  const A = sanitizeRaw(a);
  const B = sanitizeRaw(b);
  if (A && B) return `${A} → ${B}`;
  if (A) return A;
  if (B) return B;
  return null;
}

// Path-token grammar (docs/plans/2026-09-24-repo-brain.md §8), verbatim.
const PATH_TOKEN_RE =
  /(?:^|[\s("'`,;:])([A-Za-z0-9_][A-Za-z0-9_./-]*(?:\.[A-Za-z0-9]{1,8}|\/))(?=$|[\s)"'`,;:.])/g;

function extractPathTokens(text: string): string[] {
  const out: string[] = [];
  const re = new RegExp(PATH_TOKEN_RE.source, 'g');
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    out.push(m[1]);
    if (m[0].length === 0) re.lastIndex++; // defensive: never spin on a zero-length match
  }
  return out;
}

/** Resolve path tokens found in `text` to globs, keeping only tokens the repo actually has
 *  (files exact; `dir/` tokens kept when some repo file starts with that prefix). Deduped,
 *  capped at MAX_GLOBS_PER_ITEM, insertion order preserved. */
function extractGlobs(text: string, repoSet: Set<string>, repoFiles: string[]): string[] {
  const tokens = extractPathTokens(text);
  const globs: string[] = [];
  const seen = new Set<string>();
  for (const tok of tokens) {
    let g: string | null = null;
    if (tok.endsWith('/')) {
      if (repoFiles.some(f => f.startsWith(tok))) g = `${tok}*`;
    } else if (repoSet.has(tok)) {
      g = tok;
    }
    if (g && !seen.has(g)) {
      seen.add(g);
      globs.push(g);
      if (globs.length >= MAX_GLOBS_PER_ITEM) break;
    }
  }
  return globs;
}

const KIND_PRIORITY: Record<JitKind, number> = { lesson: 0, convention: 1, decision: 2, intent: 3 };

/** Pure builder: page facts + convention bullets + the repo's file list → a deterministic,
 *  path-triggered index. No I/O, no timestamps — same input always yields the same output. */
export function buildJitIndex(input: BuildJitIndexInput): JitIndexCore {
  const repoSet = new Set(input.repoFiles);
  const items: JitItem[] = [];

  for (const page of input.pages) {
    if (page.project !== input.slug) continue;
    const ab = page.aiBlock || {};
    let kind: JitKind;
    let line: string | null;
    switch (page.type) {
      case 'issues':
        kind = 'lesson';
        line = buildLine(ab.symptom, ab.fix);
        break;
      case 'learnings':
        kind = 'lesson';
        line = buildLine(ab.claim, ab.action);
        break;
      case 'decisions': {
        const status = (page.status ?? ab.status ?? '').trim();
        if (/^(superseded|rejected)\b/i.test(status)) continue;
        kind = 'decision';
        line = buildLine(ab.choice, undefined);
        break;
      }
      case 'concepts':
        kind = 'intent';
        line = buildLine(ab.problem, undefined);
        break;
      default:
        continue; // entities/security/state/sources/etc — not part of the JIT vocabulary
    }
    if (!line) continue;
    const globs = extractGlobs(line, repoSet, input.repoFiles);
    if (globs.length === 0) continue;
    items.push({ id: page.slug, kind, globs, line: line.slice(0, LINE_CAP) });
  }

  input.conventions.forEach((raw, i) => {
    const text = sanitizeRaw(raw);
    if (!text) return;
    const globs = extractGlobs(text, repoSet, input.repoFiles);
    if (globs.length === 0) return;
    items.push({ id: `conv:${i + 1}`, kind: 'convention', globs, line: text.slice(0, LINE_CAP) });
  });

  items.sort((a, b) => {
    const pa = KIND_PRIORITY[a.kind], pb = KIND_PRIORITY[b.kind];
    if (pa !== pb) return pa - pb;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  return { schema: 1, slug: input.slug, items: items.slice(0, MAX_ITEMS) };
}

async function readConventions(projectFile: string): Promise<string[]> {
  let content: string;
  try {
    content = await fs.readFile(projectFile, 'utf-8');
  } catch {
    return [];
  }
  const lines = content.split('\n');
  const idx = lines.findIndex(l => l.trim() === '## Conventions');
  if (idx < 0) return [];
  const out: string[] = [];
  for (let i = idx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith('## ')) break;
    const t = l.replace(/\r$/, '').trim();
    if (t.startsWith('- ')) out.push(t.slice(2));
  }
  return out;
}

/** Wiki pages whose frontmatter carries a `project:` facet — same loader knowledge-reindex.ts
 *  uses (parseDoc + walkWiki), so the JIT builder and reindex never see two different parses of
 *  the same page. Unreadable pages are skipped (best-effort — a torn/hand-edited page must not
 *  abort the whole rebuild). */
async function loadProjectPages(knowledgeDir: string): Promise<JitSourcePage[]> {
  const wikiRoot = join(knowledgeDir, 'wiki');
  const pages: JitSourcePage[] = [];
  let entries;
  try {
    entries = await fs.readdir(wikiRoot, { withFileTypes: true });
  } catch {
    return pages; // no wiki yet
  }
  const dirs = entries.filter(d => d.isDirectory() && d.name !== 'projects').map(d => d.name);
  for (const dir of dirs) {
    let files: string[];
    try {
      files = await walkWiki(join(wikiRoot, dir));
    } catch {
      continue;
    }
    for (const filePath of files) {
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const doc = parseDoc(content, filePath);
        pages.push({
          slug: basename(filePath).replace(/\.md$/, ''),
          type: dir,
          project: doc.project,
          aiBlock: doc.aiBlock ?? {},
        });
      } catch {
        // unreadable/unparseable page — skip, never abort the whole rebuild
      }
    }
  }
  return pages;
}

export type GitRunner = (args: string[], cwd: string) => Promise<string>;

const execFileAsync = promisify(execFile);

/** Default git runner: async (never blocks the MCP server's event loop — the earlier
 *  `execFileSync` did), 64 MiB maxBuffer (the 1 MiB default throws ENOBUFS on a real repo's
 *  `ls-files -z` output well before it's unusually large — same trap scan-sources.ts's
 *  defaultRunGit documents for the identical command), a 5s timeout, windowsHide so no console
 *  flashes on Windows. */
async function defaultGitRunner(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync('git', args, {
    cwd, maxBuffer: 64 * 1024 * 1024, windowsHide: true, timeout: 5000,
  });
  return stdout;
}

/** True when git is simply absent/unresolvable here — the existing fail-soft "nogit" path
 *  (empty repoFiles, git_rev:"nogit"). Anything else (ENOBUFS, ETIMEDOUT, killed by signal, a
 *  permissions error, …) is a REAL failure that must never be swallowed into an empty index. */
function isNoGitError(e: unknown): boolean {
  const err = e as { code?: string | number; stderr?: string | Buffer; message?: string } | undefined;
  if (!err) return false;
  if (err.code === 'ENOENT' || err.code === 128 || err.code === '128') return true;
  const stderrText = typeof err.stderr === 'string' ? err.stderr : err.stderr?.toString('utf-8') ?? '';
  const msg = err.message ?? '';
  return /not a git repository/i.test(stderrText) || /not a git repository/i.test(msg);
}

export interface RebuildJitIndexOpts {
  brainDir: string;
  knowledgeDir: string;
  slug: string;
  repoRoot: string;
  /** Injectable git runner (tests only need this — production always gets the default). */
  runGit?: GitRunner;
}

/** Impure orchestrator: loads pages + conventions + the repo file list, runs the pure builder,
 *  and writes the result atomically to $BRAIN_DIR/projects/<slug>/jit-index.json. Fails soft
 *  (git_rev "nogit", empty items) ONLY when git itself is genuinely unresolvable here (missing,
 *  or repoRoot isn't a git repo) — any OTHER git failure (ENOBUFS, timeout, killed) REJECTS
 *  before anything is written, so an existing good index is never clobbered with an empty one
 *  and the CLI reports a non-zero exit. Also throws on an invalid slug or a write failure. */
export async function rebuildJitIndex(opts: RebuildJitIndexOpts): Promise<JitIndex> {
  validateSlug(opts.slug);
  const dir = resolveBrainDir(opts.brainDir);
  const projectFile = assertWithin(dir, 'projects', opts.slug, 'PROJECT.md');

  const [pages, conventions] = await Promise.all([
    loadProjectPages(opts.knowledgeDir),
    readConventions(projectFile),
  ]);

  const runGit = opts.runGit ?? defaultGitRunner;
  let repoFiles: string[] = [];
  let gitRev = 'nogit';
  let lsFilesOk = false;
  try {
    const out = await runGit(['ls-files', '-z'], opts.repoRoot);
    repoFiles = out.split('\0').filter(Boolean);
    lsFilesOk = true;
  } catch (e) {
    if (!isNoGitError(e)) {
      const code = (e as { code?: string | number } | undefined)?.code ?? 'unknown';
      throw new Error(`jit-index: git ls-files failed (${code}) — index NOT rewritten`);
    }
    console.error(JSON.stringify({
      event: 'jit-index-no-git', repoRoot: opts.repoRoot,
      err: e instanceof Error ? e.message : String(e),
    }));
  }
  if (lsFilesOk) {
    try {
      const out = await runGit(['rev-parse', 'HEAD'], opts.repoRoot);
      gitRev = out.trim() || 'nogit';
    } catch {
      gitRev = 'nogit';
    }
  }

  const core = buildJitIndex({ slug: opts.slug, pages, conventions, repoFiles });
  const index: JitIndex = { ...core, generated_at: new Date().toISOString(), git_rev: gitRev };

  const outPath = assertWithin(dir, 'projects', opts.slug, 'jit-index.json');
  await fs.mkdir(join(dir, 'projects', opts.slug), { recursive: true });
  await atomicWriteJson(outPath, index);
  return index;
}

/** server.ts's pin_to_project handler calls this to decide whether a successful pin should
 *  trigger a background rebuildJitIndex — ONLY when the pinned slug IS the caller's active
 *  project. server.ts always rebuilds against `activeProjectDir()` (this process's own repo
 *  root), so pinning a DIFFERENT project's slug (multi-project workflows, or a stale/explicit
 *  `slug` argument) must never rebuild that project's index against the active repo's file
 *  list — it would drop every item whose glob names a path the active repo doesn't have. */
export function shouldRebuildAfterPin(pinOk: boolean, slug: string, activeSlug: string | undefined): boolean {
  return pinOk && activeSlug !== undefined && slug === activeSlug;
}
