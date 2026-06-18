import { promises as fs } from "fs";
import { homedir } from 'os';
import { atomicWriteJson } from './atomic-write.js';
import { cleanEnvPath } from '../path-guard.js';
import { resolveActiveSlug } from './project-dir.js';
import { join, basename } from "path";
import { execFile } from "child_process";
import { promisify } from "util";

const exec = promisify(execFile);

function brainDir(): string {
  return join(cleanEnvPath(process.env.HOME), ".second-brain");
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

function resolveKnowledgeDir(): string {
  const raw = cleanEnvPath(
    process.env.KNOWLEDGE_DIR ?? process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR
  );
  const home = cleanEnvPath(process.env.HOME);
  if (raw && raw.trim() && !raw.includes("${")) {
    return raw.startsWith("~") ? join(home, raw.slice(1)) : raw;
  }
  return join(home, "knowledge");
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
  };
  model?: string;
}

export interface DreamCreateResult {
  ok: boolean;
  dream: DreamStatus | null;
  reason?: string;
}

/** Build the dream-snapshot.sh argv. Scope default: when the caller gives no project_slug, mine the
 *  ACTIVE project (leaf). project_slug:"all" is the explicit cross-project opt-out (no --slug → every
 *  transcript). An explicit slug is used verbatim. (Assumes instructions length already validated.) */
export function buildSnapshotArgs(args: DreamCreateArgs, activeSlug: string | undefined): string[] {
  const out: string[] = [];
  if (args.instructions) out.push('--instructions', args.instructions);
  const requested = args.transcript_filter?.project_slug;
  const scope = requested ?? activeSlug;            // default = active project (leaf)
  if (scope && scope !== 'all') out.push('--slug', scope);
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
  const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
  const activeSlug = resolveActiveSlug(brainDir);
  const scriptArgs = buildSnapshotArgs(args, activeSlug);

  try {
    const { stdout, stderr } = await exec(
      "bash",
      [toBashPath(join(scriptsDir(), "dream-snapshot.sh")), ...scriptArgs],
      { timeout: 30_000, env: { ...process.env } }
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

export async function dreamAccept(
  args: DreamAcceptArgs
): Promise<DreamAcceptResult> {
  try {
    const { stdout, stderr } = await exec(
      "bash",
      [toBashPath(join(scriptsDir(), "dream-accept.sh")), args.dream_id],
      { timeout: 30_000, env: { ...process.env } }
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
