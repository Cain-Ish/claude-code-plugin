// src/tools/persona-think.ts
import { spawn } from "child_process";

// src/model-resolve.ts
import { readFileSync } from "node:fs";
import { join as join2 } from "node:path";

// src/brain-paths.ts
import { join, isAbsolute } from "path";
import { homedir } from "os";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}

// src/brain-paths.ts
function resolveBrainDir(override) {
  if (override) return override;
  return cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
}

// ../model-ladder.json
var model_ladder_default = {
  _comment: "Single source of truth for model selection. Ladders are ORDERED preference lists walked by sb_resolve_model (bash) and resolveModel (TS). Rung 0 is always a bare ALIAS so a newly released model is picked up with no code change; pinned IDs below it exist only as the demotion path. The dispatch ladders may contain aliases ONLY -- the Agent tool's model param is a schema-level enum and rejects full IDs before any API call. Guarded by tests/test-model-ladder.sh.",
  schema: 1,
  tiers: ["fast", "mid", "deep"],
  protocol_names: { fast: "SCOUT", mid: "DO", deep: "THINK" },
  dispatch_aliases: ["haiku", "sonnet", "opus", "fable"],
  ladders: {
    headless: {
      fast: ["haiku", "claude-haiku-4-5", "sonnet"],
      mid: ["sonnet", "claude-sonnet-5", "claude-sonnet-4-6", "opus", "haiku"],
      deep: ["opus", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "sonnet"]
    },
    dispatch: {
      fast: ["haiku", "sonnet"],
      mid: ["sonnet", "opus", "haiku"],
      deep: ["opus", "fable", "sonnet"]
    }
  },
  pins: {
    fast: ["SB_MODEL_TIER_FAST", "SB_QUALITY_GATE_MODEL"],
    mid: ["SB_MODEL_TIER_MID", "SB_EXTRACTOR_MODEL", "SB_MAINTAIN_LLM_MODEL"],
    deep: ["SB_MODEL_TIER_DEEP", "SB_PERSONA_MODEL"]
  }
};

// src/constants/model-ladder.ts
var TIERS = model_ladder_default.tiers;
var SURFACES = Object.keys(model_ladder_default.ladders);
var DISPATCH_ALIASES = model_ladder_default.dispatch_aliases;
var LADDERS = model_ladder_default.ladders;
var PIN_ENVS = model_ladder_default.pins;
var PROTOCOL_NAMES = model_ladder_default.protocol_names;

// src/model-resolve.ts
var DEFAULT_TTL_SECONDS = 604800;
var authFingerprint = () => process.env.ANTHROPIC_API_KEY ? "apikey" : "oauth";
function blockedSet(surface) {
  const blocked = /* @__PURE__ */ new Set();
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(join2(resolveBrainDir(), "model-availability.json"), "utf8"));
  } catch {
    return blocked;
  }
  if (parsed.auth_fingerprint !== authFingerprint()) return blocked;
  const ttlRaw = Number(process.env.SB_MODEL_CACHE_TTL);
  const ttl = Number.isFinite(ttlRaw) && ttlRaw >= 0 ? ttlRaw : DEFAULT_TTL_SECONDS;
  const now = Math.floor(Date.now() / 1e3);
  for (const [model, v] of Object.entries(parsed.surfaces?.[surface] ?? {})) {
    if (v?.state !== "blocked") continue;
    const epoch = typeof v.epoch === "number" ? v.epoch : 0;
    if (epoch > 0 && now - epoch >= ttl) continue;
    blocked.add(model);
  }
  return blocked;
}
function resolveModel(tier, surface = "headless") {
  const pins = (PIN_ENVS[tier] ?? []).map((envName) => process.env[envName]).filter((v) => typeof v === "string" && v.length > 0);
  const rungs = [...pins, ...LADDERS[surface]?.[tier] ?? []];
  if (rungs.length === 0) return "sonnet";
  if (process.env.SB_MODEL_ELASTIC === "0") return rungs[0];
  const blocked = blockedSet(surface);
  return rungs.find((m) => !blocked.has(m)) ?? rungs[0];
}

// src/tools/persona-think.ts
var advisorModel = () => resolveModel("deep", "headless");
var THINK_TIMEOUT_MS = Number(process.env.SB_PERSONA_TIMEOUT_MS ?? "30000");
var SYSTEM_PROMPT = `You are the user's senior-developer persona for the second-brain plugin.
Given the user's prompt plus optional context hints, return ONLY a JSON object with these fields:
  intent_read: one sentence \u2014 what the user probably wants
  prompt_enrichment: a short paragraph adding the context the user might not realize is relevant
  clarifying_questions: array of 0-2 questions worth asking before answering (omit if the prompt is unambiguous)
  relevant_specialists: array of plugin/agent names that fit (or empty)
  risk_flags: array of risks/gotchas (or empty)

Be terse. Default silent on questions/specialists/risks \u2014 only populate when the value is concrete.
Output ONLY the JSON object, no prose around it.`;
function defaultRunner(system, user, model) {
  return new Promise((resolve, reject) => {
    const p = spawn("claude", ["-p", "--bare", "--model", model, "--system-prompt", system], {
      stdio: ["pipe", "pipe", "pipe"]
    });
    let out = "";
    let err = "";
    let killed = false;
    const timer = setTimeout(() => {
      killed = true;
      p.kill("SIGTERM");
      setTimeout(() => {
        if (!p.killed) p.kill("SIGKILL");
      }, 2e3);
      reject(new Error(`timeout after ${THINK_TIMEOUT_MS}ms`));
    }, THINK_TIMEOUT_MS);
    p.stdout.on("data", (d) => {
      out += d.toString();
    });
    p.stderr.on("data", (d) => {
      err += d.toString();
    });
    p.on("error", (e) => {
      clearTimeout(timer);
      if (!killed) reject(e);
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      if (killed) return;
      if (code === 0) resolve(out);
      else reject(new Error(err || `claude -p exited ${code}`));
    });
    p.stdin.write(user);
    p.stdin.end();
  });
}
var EMPTY = {
  intent_read: "",
  prompt_enrichment: "",
  clarifying_questions: [],
  relevant_specialists: [],
  risk_flags: []
};
function parseBrief(raw) {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const parsed = JSON.parse(match[0]);
    return {
      intent_read: typeof parsed.intent_read === "string" ? parsed.intent_read : "",
      prompt_enrichment: typeof parsed.prompt_enrichment === "string" ? parsed.prompt_enrichment : "",
      clarifying_questions: Array.isArray(parsed.clarifying_questions) ? parsed.clarifying_questions.slice(0, 2).map(String) : [],
      relevant_specialists: Array.isArray(parsed.relevant_specialists) ? parsed.relevant_specialists.map(String) : [],
      risk_flags: Array.isArray(parsed.risk_flags) ? parsed.risk_flags.map(String) : []
    };
  } catch {
    return null;
  }
}
async function personaThink(args, deps = {}) {
  const runner = deps.runner ?? defaultRunner;
  const model = deps.model ?? advisorModel();
  const hints = (args.context_hints ?? []).join("\n");
  const user = hints ? `Context hints:
${hints}

User prompt:
${args.prompt}` : args.prompt;
  try {
    const raw = await runner(SYSTEM_PROMPT, user, model);
    const brief = parseBrief(raw);
    if (!brief) return { ...EMPTY, error: "no JSON in response" };
    return brief;
  } catch (e) {
    return { ...EMPTY, error: e?.message ?? String(e) };
  }
}

// src/cli/persona-think-cli.ts
var argvPrompt = process.argv.slice(2).join(" ").trim();
var stdinPrompt = await new Promise((resolve) => {
  if (process.stdin.isTTY) return resolve("");
  let buf = "";
  process.stdin.setEncoding("utf-8");
  process.stdin.on("data", (d) => {
    buf += d;
  });
  process.stdin.on("end", () => resolve(buf.trim()));
});
var prompt = argvPrompt || stdinPrompt;
if (!prompt) process.exit(0);
var r = await personaThink({ prompt });
if (r.error) {
  process.stderr.write(`persona think error: ${r.error}
`);
  process.exit(0);
}
var lines = [];
if (r.intent_read) lines.push(`Intent: ${r.intent_read}`);
if (r.prompt_enrichment) lines.push(`Enrichment: ${r.prompt_enrichment}`);
if (r.clarifying_questions.length) lines.push(`Ask user: ${r.clarifying_questions.map((q, i) => `${i + 1}) ${q}`).join("  ")}`);
if (r.relevant_specialists.length) lines.push(`Consider: ${r.relevant_specialists.join(", ")}`);
if (r.risk_flags.length) lines.push(`Risks: ${r.risk_flags.join("; ")}`);
process.stdout.write(lines.join("\n") + "\n");
