import { promises as fs } from "fs";
import { existsSync } from "fs";
import { atomicWriteJson } from './atomic-write.js';
import { cleanEnvPath } from '../path-guard.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';
import { resolveActiveSlug } from './project-dir.js';
import { projectFamily } from './project-registry.js';
import { join, basename } from "path";
import { execFile } from "child_process";
import { promisify } from "util";

const exec = promisify(execFile);

export function brainDir(): string {
  return resolveBrainDir();
}

function dreamsDir(): string {
  return join(brainDir(), "dreams");
}

function scriptsDir(): string {
  return join(
    cleanEnvPath(process.env.CLAUDE_PLUGIN_ROOT) || join(__dirname, "..", ".."),
    "scripts"
  );
}

/** Convert a path to a form `bash` accepts as an argv script path. On Windows, Node's
 *  `path.join` yields a backslash path (`C:\Users\x\...\dream-snapshot.sh`); passing that to
 *  `bash` eats the `\` escapes (`C:Usersx...`) → "No such file or directory". Git Bash / MSYS
 *  bash opens `/c/Users/x/...`, so map backslashes→slashes and `C:/`→`/c/`. No-op on POSIX
 *  (no backslashes, no drive letter). Exported for tests. */
export function toBashPath(p: string): string {
  // cleanEnvPath strips any CR/LF FIRST: a CRLF-tainted CLAUDE_PLUGIN_ROOT leaves a `\r`
  // in the joined path, and bash rejects "dream-snapshot.sh\r" with "No such file or
  // directory" on a script that exists (the confirmed Windows dream_create failure).
  let s = cleanEnvPath(p).replace(/\\/g, "/");
  const drive = s.match(/^([A-Za-z]):\//);
  if (drive) s = "/" + drive[1].toLowerCase() + s.slice(2);
  return s;
}

/** Pure probe function — testable without touching the real filesystem.
 *  Returns the first candidate path for which `exists(p)` is true, or "bash" as fallback.
 *  `env` should be `process.env` in production; pass a stub in tests. */
export function resolveBashExePure(
  platform: string,
  exists: (p: string) => boolean,
  env: Record<string, string | undefined>,
): string {
  if (platform !== "win32") return "bash";
  const pf = env["PROGRAMFILES"] ?? "C:\\Program Files";
  const localAppData = env["LOCALAPPDATA"] ?? "";
  const candidates = [
    `${pf}\\Git\\bin\\bash.exe`,
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    ...(localAppData ? [`${localAppData}\\Programs\\Git\\bin\\bash.exe`] : []),
  ];
  for (const c of candidates) {
    if (exists(c)) return c;
  }
  return "bash"; // fallback — don't make machines without git-bash worse
}

/** Resolve the git-bash executable on Windows to avoid exec("bash") picking up the
 *  WSL launcher (System32\bash.exe) from Machine-PATH before git-bash in User-PATH.
 *  WSL bash mounts drives at /mnt/c, not /c, so toBashPath() MSYS paths break.
 *  On POSIX, returns "bash" unchanged. */
export function resolveBashExe(): string {
  return resolveBashExePure(process.platform, existsSync, process.env as Record<string, string | undefined>);
}

interface DreamStatus {
  id: string;
  status: "pending" | "running" | "completed" | "failed" | "canceled";
  created_at: string;
  started_at: string | null;
  ended_at: string | null;
  archived_at: string | null;
  model: string;
  instructions: string;
  inputs: {
    transcript_count: number;
    wiki_page_count: number;
    wiki_snapshot_bytes: number;
    project_slug?: string;
  };
  outputs: {
    pages_added: number;
    pages_modified: number;
    pages_removed: number;
  };
  error: string | null;
}

async function readStatus(dreamId: string): Promise<DreamStatus | null> {
  const statusPath = join(dreamsDir(), dreamId, "status.json");
  try {
    const raw = await fs.readFile(statusPath, "utf-8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function writeStatus(
  dreamId: string,
  status: DreamStatus
): Promise<void> {
  const statusPath = join(dreamsDir(), dreamId, "status.json");
  await atomicWriteJson(statusPath, status);
}

async function listDreamIds(): Promise<string[]> {
  const dir = dreamsDir();
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    return entries
      .filter((e) => e.isDirectory() && e.name.startsWith("drm_"))
      .map((e) => e.name)
      .sort()
      .reverse();
  } catch {
    return [];
  }
}

// --- Tool implementations ---

export interface DreamCreateArgs {
  instructions?: string;
  transcript_filter?: {
    project_slug?: string;
    since?: string;
    max_count?: number;
    family?: boolean;        // mine the whole monorepo family (Phase B)
  };
  model?: string;
}

export interface DreamCreateResult {
  ok: boolean;
  dream: DreamStatus | null;
  reason?: string;
}

/** Build the dream-snapshot.sh argv. Scope: project_slug:"all" → no --slug (every transcript);
 *  transcript_filter.family → one --slug per family member (sorted); else the single active project
 *  (leaf) or an explicit project_slug. (Assumes instructions length already validated.) */
export function buildSnapshotArgs(
  args: DreamCreateArgs, activeSlug: string | undefined, family?: Set<string>,
): string[] {
  const out: string[] = [];
  if (args.instructions) out.push('--instructions', args.instructions);
  const requested = args.transcript_filter?.project_slug;
  if (requested === 'all') {
    // explicit cross-project opt-out → no --slug
  } else if (args.transcript_filter?.family && family && family.size) {
    for (const s of [...family].sort()) out.push('--slug', s);
  } else {
    const scope = requested ?? activeSlug;
    if (scope) out.push('--slug', scope);
  }
  if (args.transcript_filter?.since) out.push('--since', args.transcript_filter.since);
  const maxCount = Math.min(args.transcript_filter?.max_count ?? 50, 100);
  out.push('--max-count', String(maxCount));
  if (args.model) out.push('--model', args.model);
  return out;
}

export async function dreamCreate(
  args: DreamCreateArgs
): Promise<DreamCreateResult> {
  if (args.instructions && args.instructions.length > 4096) {
    return { ok: false, dream: null, reason: "instructions exceed 4096 char limit" };
  }
  const activeSlug = resolveActiveSlug(brainDir());
  const family = activeSlug ? projectFamily(brainDir(), activeSlug) : undefined;
  const scriptArgs = buildSnapshotArgs(args, activeSlug, family);

  try {
    const { stdout, stderr } = await exec(
      resolveBashExe(), // win32: probe Git\bin\bash.exe to avoid WSL bash via System32
      [toBashPath(join(scriptsDir(), "dream-snapshot.sh")), ...scriptArgs],
      { timeout: 30_000, env: { ...process.env, BRAIN_DIR: brainDir(), KNOWLEDGE_DIR: resolveKnowledgeDir() } }
    );
    const dreamId = stdout.trim();
    if (!dreamId.startsWith("drm_")) {
      return { ok: false, dream: null, reason: stderr.trim() || "dream-snapshot.sh failed" };
    }
    const status = await readStatus(dreamId);
    return { ok: true, dream: status };
  } catch (err: any) {
    return {
      ok: false,
      dream: null,
      reason: err.stderr?.trim() || err.message || String(err),
    };
  }
}

export interface DreamStatusArgs {
  dream_id: string;
}

export interface DreamStatusResult {
  ok: boolean;
  dream: DreamStatus | null;
  diff_preview?: string;
  reason?: string;
}

export async function dreamStatus(
  args: DreamStatusArgs
): Promise<DreamStatusResult> {
  const status = await readStatus(args.dream_id);
  if (!status) {
    return { ok: false, dream: null, reason: `dream ${args.dream_id} not found` };
  }

  let diffPreview: string | undefined;
  if (status.status === "completed") {
    const diffPath = join(dreamsDir(), args.dream_id, "diff.md");
    try {
      const content = await fs.readFile(diffPath, "utf-8");
      const lines = content.split("\n");
      diffPreview = lines.slice(0, 50).join("\n");
      if (lines.length > 50) diffPreview += "\n... (truncated)";
    } catch {}
  }

  return { ok: true, dream: status, diff_preview: diffPreview };
}

export interface DreamListArgs {
  include_archived?: boolean;
}

export interface DreamListResult {
  ok: boolean;
  dreams: Array<{
    id: string;
    status: string;
    created_at: string;
    ended_at: string | null;
    archived_at: string | null;
    transcript_count: number;
    pages_added: number;
    pages_modified: number;
    pages_removed: number;
  }>;
}

export async function dreamList(args: DreamListArgs): Promise<DreamListResult> {
  const ids = await listDreamIds();
  const dreams: DreamListResult["dreams"] = [];

  for (const id of ids) {
    const status = await readStatus(id);
    if (!status) continue;
    if (!args.include_archived && status.archived_at) continue;
    dreams.push({
      id: status.id,
      status: status.status,
      created_at: status.created_at,
      ended_at: status.ended_at,
      archived_at: status.archived_at,
      transcript_count: status.inputs.transcript_count,
      pages_added: status.outputs.pages_added,
      pages_modified: status.outputs.pages_modified,
      pages_removed: status.outputs.pages_removed,
    });
  }

  return { ok: true, dreams };
}

export interface DreamAcceptArgs {
  dream_id: string;
}

export interface DreamAcceptResult {
  ok: boolean;
  summary?: string;
  reason?: string;
}

/** Wall-clock for dream-accept.sh. Default 10 min: the post-apply steps (FORGET re-score,
 *  reindex, history snapshot) scale with wiki size and run after live is already mutated, so a
 *  premature kill is worse than a slow accept. Env override: SB_DREAM_ACCEPT_TIMEOUT_MS. */
function acceptTimeoutMs(): number {
  const raw = Number(cleanEnvPath(process.env.SB_DREAM_ACCEPT_TIMEOUT_MS));
  return Number.isFinite(raw) && raw >= 30_000 ? raw : 600_000;
}

export async function dreamAccept(
  args: DreamAcceptArgs
): Promise<DreamAcceptResult> {
  try {
    const { stdout, stderr } = await exec(
      resolveBashExe(), // win32: probe Git\bin\bash.exe to avoid WSL bash via System32
      [toBashPath(join(scriptsDir(), "dream-accept.sh")), args.dream_id],
      // ACCEPT_TIMEOUT_MS, not 30s: the accept now runs wiki-size-unbounded work AFTER it has
      // already mutated the live wiki — the FORGET re-score (wiki-forget-score.sh measured at
      // ~105s on a 237-page wiki), the reindex, and the history snapshot. A 30s kill therefore
      // reported ok:false on an accept that had partially applied, with the forget manifest
      // half-consumed and no snapshot recorded. Overridable for slow/huge wikis.
      { timeout: acceptTimeoutMs(), env: { ...process.env, BRAIN_DIR: brainDir(), KNOWLEDGE_DIR: resolveKnowledgeDir() } }
    );
    const output = stdout.trim();
    if (output) return { ok: true, summary: output };
    return { ok: false, reason: stderr.trim() || "dream-accept.sh failed" };
  } catch (err: any) {
    return {
      ok: false,
      reason: err.stderr?.trim() || err.message || String(err),
    };
  }
}

export interface DreamDiscardArgs {
  dream_id: string;
}

export interface DreamDiscardResult {
  ok: boolean;
  reason?: string;
}

export async function dreamDiscard(
  args: DreamDiscardArgs
): Promise<DreamDiscardResult> {
  const status = await readStatus(args.dream_id);
  if (!status) {
    return { ok: false, reason: `dream ${args.dream_id} not found` };
  }
  if (!["completed", "failed", "canceled"].includes(status.status)) {
    return {
      ok: false,
      reason: `dream is ${status.status}, must be completed/failed/canceled`,
    };
  }
  if (status.archived_at) {
    return { ok: false, reason: `dream ${args.dream_id} already archived` };
  }

  const dreamDir = join(dreamsDir(), args.dream_id);
  try {
    await fs.rm(join(dreamDir, "staging"), { recursive: true, force: true });
    await fs.rm(join(dreamDir, "transcripts"), {
      recursive: true,
      force: true,
    });
  } catch {}

  status.archived_at = new Date().toISOString();
  await writeStatus(args.dream_id, status);
  return { ok: true };
}

export interface DreamCancelArgs {
  dream_id: string;
}

export interface DreamCancelResult {
  ok: boolean;
  reason?: string;
}

export async function dreamCancel(
  args: DreamCancelArgs
): Promise<DreamCancelResult> {
  const status = await readStatus(args.dream_id);
  if (!status) {
    return { ok: false, reason: `dream ${args.dream_id} not found` };
  }
  if (!["pending", "running"].includes(status.status)) {
    return {
      ok: false,
      reason: `dream is ${status.status}, can only cancel pending/running`,
    };
  }

  status.status = "canceled";
  status.ended_at = new Date().toISOString();
  await writeStatus(args.dream_id, status);
  return { ok: true };
}
