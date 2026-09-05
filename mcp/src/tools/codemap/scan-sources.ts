/**
 * Source enumeration (repo scoping + ignore rules).
 * Plan: archive/docs branch, docs/superpowers/plans/2026-06-30-p3a-orientation-code-map.md.
 *
 * Pure: dir in, file list out — no store access, no timestamps. Output is
 * id-sorted so identical trees yield byte-identical downstream graphs (the
 * determinism contract build-graph.ts and store.ts build on).
 */
import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync, statSync } from 'fs';
import { readFile, stat } from 'fs/promises';
import { homedir, tmpdir } from 'os';
import * as path from 'path';
import { glob } from 'glob';
import type { Lang, ScannedFile } from './types.js';
import type { TsPathConfig } from './extract.js';

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
  /** cheap staleness proxy (D039): count + newest mtime over the FINAL kept
   *  list, captured for free from the stat() calls already made for the size
   *  cap below — lets drift.ts skip a redundant second full stat pass on
   *  every nogit staleness probe (measured 61s+ before the fix). */
  fingerprint: { fileCount: number; maxMtimeMs: number };
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
  let maxMtimeMs = 0;
  for (const k of kept) if (k.mtimeMs > maxMtimeMs) maxMtimeMs = k.mtimeMs;
  return { files, truncated, fingerprint: { fileCount: kept.length, maxMtimeMs } };
}

// --- D039: refuse to walk roots that are not a recognizable project --------

const WORKSPACE_MANIFESTS = ['package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', '.sb-monorepo.json'];

export type ProjectRootCheck = { ok: true } | { ok: false; reason: string };

/** Injectable so unit tests never depend on the REAL machine's HOME/temp dir
 *  (which would make tests host-dependent) — and so this repo's own e2e
 *  fixtures, which build tiny throwaway git repos under tmpdir(), keep
 *  working: those pass because they have a real .git, not because they
 *  dodge the temp check. */
export interface RootCheckEnv {
  home?: string;
  temp?: string;
}

function isUnderOrEqual(candidate: string, base: string): boolean {
  const c = path.resolve(candidate);
  const b = path.resolve(base);
  return c === b || c.startsWith(b + path.sep);
}

/**
 * Guards codemap generation against roots that are not a project (D039):
 * evidence showed a registered $HOME and a registered OS temp dir each
 * produced a junk map (thousands of unrelated files) via the nogit glob
 * fallback, and re-walked the whole tree on every staleness probe. $HOME is
 * always refused. A temp root (os.tmpdir(), or the Windows
 * AppData/Local/Temp segment specifically — some launchers register that
 * path directly without going through tmpdir()) is refused UNLESS it holds a
 * real git repo or a workspace manifest. Any other root with neither .git
 * nor a workspace manifest is refused too. Pure existsSync probes only —
 * never scanSources — so calling this can never itself be the slow walk.
 */
export function checkProjectRoot(repoRoot: string, env: RootCheckEnv = {}): ProjectRootCheck {
  const resolved = path.resolve(repoRoot);
  if (!existsSync(resolved)) {
    return { ok: false, reason: `repoRoot does not exist: ${repoRoot}` };
  }
  const home = env.home ?? homedir();
  if (resolved === path.resolve(home)) {
    return {
      ok: false,
      reason: `repoRoot is $HOME (${repoRoot}) -- refusing to map the user's whole profile`,
    };
  }
  const temp = env.temp ?? tmpdir();
  const underTemp =
    isUnderOrEqual(resolved, temp) || /[\\/]AppData[\\/]Local[\\/]Temp(?:[\\/]|$)/i.test(resolved);
  const hasGit = existsSync(path.join(resolved, '.git'));
  const hasManifest = WORKSPACE_MANIFESTS.some((m) => existsSync(path.join(resolved, m)));
  if (underTemp && !hasGit && !hasManifest) {
    return {
      ok: false,
      reason: `repoRoot is under a temp dir (${temp}) with no .git or workspace manifest -- refusing to map scratch space`,
    };
  }
  if (!hasGit && !hasManifest) {
    return {
      ok: false,
      reason: `repoRoot has neither .git nor a workspace manifest (${WORKSPACE_MANIFESTS.join(', ')}) -- not a recognizable project`,
    };
  }
  return { ok: true };
}

// --- D037: tsconfig/jsconfig path-alias config (read once per scan) --------

/**
 * Best-effort tsconfig.json/jsconfig.json reader for extract.ts's alias
 * resolution (D037). A missing or unparseable file yields {} (no aliases)
 * rather than failing the scan — same "degrade, don't crash" posture as
 * extract.ts's other unresolvable-stays-external fallbacks. Real-world
 * tsconfig files sometimes carry comments/trailing commas; a parse failure
 * there is treated the same as absent, not a fail-loud error.
 */
export async function readTsPathConfig(repoRoot: string): Promise<TsPathConfig> {
  for (const name of ['tsconfig.json', 'jsconfig.json']) {
    let raw: string;
    try {
      raw = await readFile(path.join(repoRoot, name), 'utf-8');
    } catch {
      continue;
    }
    try {
      const parsed = JSON.parse(raw) as {
        compilerOptions?: { baseUrl?: string; paths?: Record<string, string[]> };
      };
      const co = parsed.compilerOptions ?? {};
      return { baseUrl: co.baseUrl, paths: co.paths };
    } catch {
      return {};
    }
  }
  return {};
}
