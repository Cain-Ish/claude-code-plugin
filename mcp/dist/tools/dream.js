import { promises as fs } from "fs";
import { join } from "path";
import { execFile } from "child_process";
import { promisify } from "util";
const exec = promisify(execFile);
function brainDir() {
    return join(process.env.HOME ?? "", ".second-brain");
}
function dreamsDir() {
    return join(brainDir(), "dreams");
}
function scriptsDir() {
    return join(process.env.CLAUDE_PLUGIN_ROOT ?? join(__dirname, "..", ".."), "scripts");
}
function resolveKnowledgeDir() {
    const raw = process.env.KNOWLEDGE_DIR ?? process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR;
    if (raw && raw.trim() && !raw.includes("${")) {
        return raw.startsWith("~") ? join(process.env.HOME ?? "", raw.slice(1)) : raw;
    }
    return join(process.env.HOME ?? "", "knowledge");
}
async function readStatus(dreamId) {
    const statusPath = join(dreamsDir(), dreamId, "status.json");
    try {
        const raw = await fs.readFile(statusPath, "utf-8");
        return JSON.parse(raw);
    }
    catch {
        return null;
    }
}
async function writeStatus(dreamId, status) {
    const statusPath = join(dreamsDir(), dreamId, "status.json");
    await fs.writeFile(statusPath, JSON.stringify(status, null, 2), "utf-8");
}
async function listDreamIds() {
    const dir = dreamsDir();
    try {
        const entries = await fs.readdir(dir, { withFileTypes: true });
        return entries
            .filter((e) => e.isDirectory() && e.name.startsWith("drm_"))
            .map((e) => e.name)
            .sort()
            .reverse();
    }
    catch {
        return [];
    }
}
export async function dreamCreate(args) {
    const scriptArgs = [];
    if (args.instructions) {
        if (args.instructions.length > 4096) {
            return {
                ok: false,
                dream: null,
                reason: "instructions exceed 4096 char limit",
            };
        }
        scriptArgs.push("--instructions", args.instructions);
    }
    if (args.transcript_filter?.project_slug) {
        scriptArgs.push("--slug", args.transcript_filter.project_slug);
    }
    if (args.transcript_filter?.since) {
        scriptArgs.push("--since", args.transcript_filter.since);
    }
    const maxCount = Math.min(args.transcript_filter?.max_count ?? 50, 100);
    scriptArgs.push("--max-count", String(maxCount));
    if (args.model) {
        scriptArgs.push("--model", args.model);
    }
    try {
        const { stdout, stderr } = await exec("bash", [join(scriptsDir(), "dream-snapshot.sh"), ...scriptArgs], { timeout: 30_000, env: { ...process.env } });
        const dreamId = stdout.trim();
        if (!dreamId.startsWith("drm_")) {
            return {
                ok: false,
                dream: null,
                reason: stderr.trim() || "dream-snapshot.sh failed",
            };
        }
        const status = await readStatus(dreamId);
        return { ok: true, dream: status };
    }
    catch (err) {
        return {
            ok: false,
            dream: null,
            reason: err.stderr?.trim() || err.message || String(err),
        };
    }
}
export async function dreamStatus(args) {
    const status = await readStatus(args.dream_id);
    if (!status) {
        return { ok: false, dream: null, reason: `dream ${args.dream_id} not found` };
    }
    let diffPreview;
    if (status.status === "completed") {
        const diffPath = join(dreamsDir(), args.dream_id, "diff.md");
        try {
            const content = await fs.readFile(diffPath, "utf-8");
            const lines = content.split("\n");
            diffPreview = lines.slice(0, 50).join("\n");
            if (lines.length > 50)
                diffPreview += "\n... (truncated)";
        }
        catch { }
    }
    return { ok: true, dream: status, diff_preview: diffPreview };
}
export async function dreamList(args) {
    const ids = await listDreamIds();
    const dreams = [];
    for (const id of ids) {
        const status = await readStatus(id);
        if (!status)
            continue;
        if (!args.include_archived && status.archived_at)
            continue;
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
export async function dreamAccept(args) {
    try {
        const { stdout, stderr } = await exec("bash", [join(scriptsDir(), "dream-accept.sh"), args.dream_id], { timeout: 30_000, env: { ...process.env } });
        const output = stdout.trim();
        if (output)
            return { ok: true, summary: output };
        return { ok: false, reason: stderr.trim() || "dream-accept.sh failed" };
    }
    catch (err) {
        return {
            ok: false,
            reason: err.stderr?.trim() || err.message || String(err),
        };
    }
}
export async function dreamDiscard(args) {
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
    }
    catch { }
    status.archived_at = new Date().toISOString();
    await writeStatus(args.dream_id, status);
    return { ok: true };
}
export async function dreamCancel(args) {
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
//# sourceMappingURL=dream.js.map