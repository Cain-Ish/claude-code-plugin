// src/cli/persona-think-cli.ts
import { join as join2 } from "path";

// src/tools/persona-think.ts
import { spawn } from "child_process";
import { promises as fs } from "fs";
import { join, dirname } from "path";
async function readOpusLedger(ledgerPath) {
  const today = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  try {
    const txt = await fs.readFile(ledgerPath, "utf-8");
    const j = JSON.parse(txt);
    if (j.date === today) {
      return {
        date: today,
        opus_cost_usd: Number(j.opus_cost_usd) || 0,
        opus_calls: Number(j.opus_calls) || 0,
        cap_usd: Number(j.cap_usd) || 5
      };
    }
  } catch {
  }
  return { date: today, opus_cost_usd: 0, opus_calls: 0, cap_usd: 5 };
}
async function recordOpusLedger(ledgerPath, inputTokens, outputTokens) {
  const callCost = inputTokens / 1e6 * 5 + outputTokens / 1e6 * 25;
  const today = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  let current = { date: today, opus_cost_usd: 0, opus_calls: 0, cap_usd: 5 };
  try {
    const txt = await fs.readFile(ledgerPath, "utf-8");
    const j = JSON.parse(txt);
    if (j.date === today) {
      current = {
        date: today,
        opus_cost_usd: Number(j.opus_cost_usd) || 0,
        opus_calls: Number(j.opus_calls) || 0,
        cap_usd: Number(j.cap_usd) || 5
      };
    }
  } catch {
  }
  const next = {
    date: today,
    opus_cost_usd: current.opus_cost_usd + callCost,
    opus_calls: current.opus_calls + 1,
    cap_usd: current.cap_usd
  };
  try {
    await fs.mkdir(dirname(ledgerPath), { recursive: true });
    await fs.writeFile(ledgerPath, JSON.stringify(next));
  } catch {
  }
}
var DEFAULT_MODEL = process.env.SB_PERSONA_MODEL ?? "claude-opus-4-7";
var COST_PER_CALL = Number(process.env.SB_PERSONA_COST_PER_CALL ?? "0.11");
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
  if (deps.budgetExceeded) {
    return { ...EMPTY, budget_skipped: true };
  }
  const lPath = deps.ledgerPath ?? (deps.brainDir ? join(deps.brainDir, "opus-budget.json") : null);
  const opusCap = deps.opusCap ?? Number(process.env.COST_ROUTER_OPUS_CAP_USD ?? "5.0");
  if (lPath) {
    const ledger = await readOpusLedger(lPath).catch(() => null);
    if (ledger && ledger.opus_cost_usd >= opusCap) {
      return {
        ...EMPTY,
        budget_skipped: true,
        error: `Opus daily budget exhausted (spent $${ledger.opus_cost_usd.toFixed(4)} of $${opusCap} cap) \u2014 try later or raise COST_ROUTER_OPUS_CAP_USD`
      };
    }
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
    if (lPath) {
      const inputTok = deps.inputTokens ?? 0;
      const outputTok = deps.outputTokens ?? 0;
      if (inputTok > 0 || outputTok > 0) {
        await recordOpusLedger(lPath, inputTok, outputTok).catch(() => {
        });
      } else {
        await recordSpend(deps.brainDir, COST_PER_CALL).catch(() => {
        });
      }
    } else if (deps.brainDir) {
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
