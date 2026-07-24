/**
 * Source enumeration (repo scoping + ignore rules).
 * Plan: docs/superpowers/plans/2026-06-30-p3a-orientation-code-map.md.
 *
 * Pure: dir in, file list out — no store access, no timestamps. Output is
 * id-sorted so identical trees yield byte-identical downstream graphs (the
 * determinism contract build-graph.ts and store.ts build on).
 */
import { execFile } from 'child_process';
import { promisify } from 'util';
import { statSync } from 'fs';
import { stat } from 'fs/promises';
import * as path from 'path';
import { glob } from 'glob';
import type { Lang, ScannedFile } from './types.js';

const execFileAsync = promisify(execFile);

/** Injectable so unit tests exercise the git path without a real repo. */
export type GitRunner = (args: string[], cwd: string) => Promise<string>;

export interface ScanOptions {
  runGit?: GitRunner;
}

/**
 * The plan's Task A1 signature returns ScannedFile[] alone, but the cap
 * contract requires A4 to record `graph.json.truncated` — truncation must be
 * observable, so the result wraps the list instead of losing that bit.
 */
export interface ScanResult {
  files: ScannedFile[];
  truncated: boolean;
}

const DEFAULT_MAX_FILE_BYTES = 524288; // 512 KiB — generated/minified blobs poison a rank heuristic
const DEFAULT_MAX_FILES = 4000;

// Ignore-dirs apply to BOTH enumeration paths (adversarial-review must-fix):
// the git path trusts ls-files, but repos that COMMIT build artifacts — this
// one ships mcp/dist bundles by design — would feed them straight into the
// rank/map. Measured here pre-fix: 42% of the default map budget went to
// bundle noise (the rank-desc/id-asc tie-break sorts dist/ BEFORE src/ at the
// shared no-inbound rank) and one >cap committed bundle pinned truncated:true
// permanently. Same rationale as the *.min.js filter below. Dot-dirs (.git,
// .next) are also unreachable via glob's default dot:false, but stay listed
// as the contract.
const IGNORE_DIRS = ['node_modules', 'dist', 'build', '.git', 'coverage', 'vendor', '.next', 'out'];
const GLOB_IGNORE = IGNORE_DIRS.map((d) => `**/${d}/**`);
// Path-segment form for the POSIX-relative ids the git path emits ('.' escaped).
const IGNORE_DIR_RE = new RegExp(`(^|/)(${IGNORE_DIRS.map((d) => d.replace(/\./g, '\\.')).join('|')})/`);

const EXT_LANG: Record<string, Lang | undefined> = {
  '.ts': 'ts',
  '.tsx': 'ts',
  '.js': 'js',
  '.jsx': 'js',
  '.mjs': 'js',
  '.cjs': 'js',
  '.py': 'py',
};

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw.trim(), 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/** Exported for drift.ts — one git-spawner shape for the whole codemap layer. */
export async function defaultRunGit(args: string[], cwd: string): Promise<string> {
  // execFile's default maxBuffer (1 MiB) truncates ls-files mid-record on
  // large monorepos; 64 MiB is headroom, not a target.
  const { stdout } = await execFileAsync('git', args, {
    cwd,
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  return stdout;
}

/** Locale-independent codepoint order — localeCompare varies by platform ICU. */
function byId(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export async function scanSources(
  repoRoot: string,
  opts: ScanOptions = {}
): Promise<ScanResult> {
  let rootStat;
  try {
    rootStat = statSync(repoRoot);
  } catch {
    throw new Error(`scanSources: repoRoot does not exist: ${repoRoot}`);
  }
  if (!rootStat.isDirectory()) {
    throw new Error(`scanSources: repoRoot is not a directory: ${repoRoot}`);
  }

  const runGit = opts.runGit ?? defaultRunGit;

  // git ls-files -z: tracked files only, so .gitignore is respected for free.
  // -z (NUL separators) because core.quotepath C-escapes non-ASCII paths in
  // newline mode. Any git failure (not a repo, git absent) falls to the glob
  // path — the plan's documented fail-soft boundary, NOT a silent error swallow.
  let candidates: Array<{ id: string; abs: string }>;
  try {
    const stdout = await runGit(['ls-files', '-z'], repoRoot);
    candidates = stdout
      .split('\0')
      .filter((rel) => rel.length > 0)
      .map((rel) => ({ id: rel, abs: path.resolve(repoRoot, rel) }));
  } catch {
    const absList = await glob('**/*', {
      cwd: repoRoot,
      nodir: true,
      absolute: true,
      ignore: GLOB_IGNORE,
    });
    candidates = absList.map((abs) => ({
      // glob emits platform separators on Windows; ids must be POSIX so a
      // graph generated on Windows queries identically on Linux CI.
      id: path.relative(repoRoot, abs).split(path.sep).join('/'),
      abs,
    }));
  }

  const maxBytes = envInt('SB_CODEMAP_MAX_FILE_BYTES', DEFAULT_MAX_FILE_BYTES);
  const maxFiles = envInt('SB_CODEMAP_MAX_FILES', DEFAULT_MAX_FILES);

  let truncated = false;
  const kept: Array<ScannedFile & { mtimeMs: number }> = [];
  for (const { id, abs } of candidates) {
    // Both paths: the glob fallback already excluded these via GLOB_IGNORE;
    // the git path needs the same cut for TRACKED artifact dirs (see the
    // IGNORE_DIRS comment — the map is materially wrong without it).
    if (IGNORE_DIR_RE.test(id)) continue;
    const lang = EXT_LANG[path.extname(id).toLowerCase()];
    if (lang === undefined) continue;
    // Plan lists *.min.js under the glob ignore set; applied to the git path
    // too — a TRACKED minified bundle is the same extractor noise.
    if (/\.min\.js$/i.test(id)) continue;
    let st;
    try {
      st = await stat(abs);
    } catch {
      // git's index lists files deleted from the worktree (staged rm); a
      // vanished candidate is a non-event for a ranking map, not an error.
      continue;
    }
    if (!st.isFile()) continue;
    if (st.size > maxBytes) {
      truncated = true;
      continue;
    }
    kept.push({ id, abs, lang, mtimeMs: st.mtimeMs });
  }

  if (kept.length > maxFiles) {
    truncated = true;
    // Most-recently-modified survive the cap (active code outranks stale code
    // in a blown-up repo); id tie-break keeps the slice deterministic.
    kept.sort((a, b) => b.mtimeMs - a.mtimeMs || byId(a.id, b.id));
    kept.length = maxFiles;
  }

  const files: ScannedFile[] = kept
    .map(({ id, abs, lang }) => ({ id, abs, lang }))
    .sort((a, b) => byId(a.id, b.id));
  return { files, truncated };
}
