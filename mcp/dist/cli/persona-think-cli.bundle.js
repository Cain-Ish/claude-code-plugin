// src/cli/persona-think-cli.ts
import { join as join2 } from "path";

// src/tools/persona-think.ts
import { spawn } from "child_process";
import { promises as fs } from "fs";
import { join } from "path";
var DEFAULT_MODEL = process.env.SB_PERSONA_MODEL ?? "claude-opus-4-7";
var COST_PER_CALL = Number(process.env.SB_PERSONA_COST_PER_CALL ?? "0.11");
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
    const p = spawn("claude", ["-p", "--model", model, "--system-prompt", system], {
      stdio: ["pipe", "pipe", "pipe"]
    });
    let out = "";
    let err = "";
    p.stdout.on("data", (d) => {
      out += d.toString();
    });
    p.stderr.on("data", (d) => {
      err += d.toString();
    });
    p.on("error", reject);
    p.on("close", (code) => {
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
  if (deps.budgetExceeded) {
    return { ...EMPTY, budget_skipped: true };
  }
  const runner = deps.runner ?? defaultRunner;
  const model = deps.model ?? DEFAULT_MODEL;
  const hints = (args.context_hints ?? []).join("\n");
  const user = hints ? `Context hints:
${hints}

User prompt:
${args.prompt}` : args.prompt;
  try {
    const raw = await runner(SYSTEM_PROMPT, user, model);
    const brief = parseBrief(raw);
    if (!brief) return { ...EMPTY, error: "no JSON in response" };
    if (deps.brainDir) {
      await recordSpend(deps.brainDir, COST_PER_CALL).catch(() => {
      });
    }
    return brief;
  } catch (e) {
    return { ...EMPTY, error: e?.message ?? String(e) };
  }
}
async function readBudget(brainDir2) {
  const file = join(brainDir2, "persona-budget.json");
  const today = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  try {
    const txt = await fs.readFile(file, "utf-8");
    const j = JSON.parse(txt);
    if (j.date === today) return { date: today, today_usd: Number(j.today_usd) || 0 };
  } catch {
  }
  return { date: today, today_usd: 0 };
}
async function recordSpend(brainDir2, usd) {
  const current = await readBudget(brainDir2);
  const next = { date: current.date, today_usd: current.today_usd + usd };
  await fs.mkdir(brainDir2, { recursive: true }).catch(() => {
  });
  await fs.writeFile(join(brainDir2, "persona-budget.json"), JSON.stringify(next));
  return next;
}

// src/cli/persona-think-cli.ts
var brainDir = process.env.BRAIN_DIR || join2(process.env.HOME ?? process.env.USERPROFILE ?? "", ".second-brain");
var dailyBudget = Number(process.env.SB_PERSONA_DAILY_BUDGET ?? "20");
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
var budget = await readBudget(brainDir);
var budgetExceeded = budget.today_usd >= dailyBudget;
var r = await personaThink({ prompt }, { budgetExceeded, brainDir });
if (r.budget_skipped) {
  process.stdout.write(`[persona think skipped \u2014 daily budget $${dailyBudget} reached]
`);
  process.exit(0);
}
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
