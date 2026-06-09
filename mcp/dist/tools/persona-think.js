import { spawn } from 'child_process';
import { promises as fs } from 'fs';
import { join, dirname } from 'path';
/** Return the path for the shared Opus ledger, given an optional brainDir. */
export function opusLedgerPath(brainDir) {
    if (process.env.COST_ROUTER_LEDGER)
        return process.env.COST_ROUTER_LEDGER;
    const bd = brainDir ?? (process.env.SB_BRAIN_DIR ?? `${process.env.HOME ?? '~'}/.second-brain`);
    return join(bd, 'opus-budget.json');
}
/** Read the shared Opus ledger. Returns zeros on missing/stale file. Never throws. */
export async function readOpusLedger(ledgerPath) {
    const today = new Date().toISOString().slice(0, 10);
    try {
        const txt = await fs.readFile(ledgerPath, 'utf-8');
        const j = JSON.parse(txt);
        if (j.date === today) {
            return {
                date: today,
                opus_cost_usd: Number(j.opus_cost_usd) || 0,
                opus_calls: Number(j.opus_calls) || 0,
                cap_usd: Number(j.cap_usd) || 5.0,
            };
        }
    }
    catch {
        // file absent or malformed — fall through to zeroed ledger
    }
    return { date: today, opus_cost_usd: 0, opus_calls: 0, cap_usd: 5.0 };
}
/** Record an Opus call's cost (in tokens) to the shared ledger. Graceful no-op on write failure. */
export async function recordOpusLedger(ledgerPath, inputTokens, outputTokens) {
    // Opus pricing: $5/Mtok input, $25/Mtok output
    const callCost = (inputTokens / 1e6) * 5 + (outputTokens / 1e6) * 25;
    const today = new Date().toISOString().slice(0, 10);
    let current = { date: today, opus_cost_usd: 0, opus_calls: 0, cap_usd: 5.0 };
    try {
        const txt = await fs.readFile(ledgerPath, 'utf-8');
        const j = JSON.parse(txt);
        if (j.date === today) {
            current = {
                date: today,
                opus_cost_usd: Number(j.opus_cost_usd) || 0,
                opus_calls: Number(j.opus_calls) || 0,
                cap_usd: Number(j.cap_usd) || 5.0,
            };
        }
        // stale date → reset to zeroed current (already set above)
    }
    catch {
        // absent/malformed — start fresh
    }
    const next = {
        date: today,
        opus_cost_usd: current.opus_cost_usd + callCost,
        opus_calls: current.opus_calls + 1,
        cap_usd: current.cap_usd,
    };
    try {
        await fs.mkdir(dirname(ledgerPath), { recursive: true });
        await fs.writeFile(ledgerPath, JSON.stringify(next));
    }
    catch {
        // Graceful no-op — never break persona-think if ledger dir is unwritable
    }
}
const DEFAULT_MODEL = process.env.SB_PERSONA_MODEL ?? 'claude-opus-4-7';
const COST_PER_CALL = Number(process.env.SB_PERSONA_COST_PER_CALL ?? '0.11');
const THINK_TIMEOUT_MS = Number(process.env.SB_PERSONA_TIMEOUT_MS ?? '30000');
const SYSTEM_PROMPT = `You are the user's senior-developer persona for the second-brain plugin.
Given the user's prompt plus optional context hints, return ONLY a JSON object with these fields:
  intent_read: one sentence — what the user probably wants
  prompt_enrichment: a short paragraph adding the context the user might not realize is relevant
  clarifying_questions: array of 0-2 questions worth asking before answering (omit if the prompt is unambiguous)
  relevant_specialists: array of plugin/agent names that fit (or empty)
  risk_flags: array of risks/gotchas (or empty)

Be terse. Default silent on questions/specialists/risks — only populate when the value is concrete.
Output ONLY the JSON object, no prose around it.`;
function defaultRunner(system, user, model) {
    return new Promise((resolve, reject) => {
        const p = spawn('claude', ['-p', '--bare', '--model', model, '--system-prompt', system], {
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        let out = '';
        let err = '';
        let killed = false;
        const timer = setTimeout(() => {
            killed = true;
            p.kill('SIGTERM');
            setTimeout(() => { if (!p.killed)
                p.kill('SIGKILL'); }, 2000);
            reject(new Error(`timeout after ${THINK_TIMEOUT_MS}ms`));
        }, THINK_TIMEOUT_MS);
        p.stdout.on('data', (d) => { out += d.toString(); });
        p.stderr.on('data', (d) => { err += d.toString(); });
        p.on('error', (e) => { clearTimeout(timer); if (!killed)
            reject(e); });
        p.on('close', (code) => {
            clearTimeout(timer);
            if (killed)
                return;
            if (code === 0)
                resolve(out);
            else
                reject(new Error(err || `claude -p exited ${code}`));
        });
        p.stdin.write(user);
        p.stdin.end();
    });
}
const EMPTY = {
    intent_read: '',
    prompt_enrichment: '',
    clarifying_questions: [],
    relevant_specialists: [],
    risk_flags: [],
};
function parseBrief(raw) {
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match)
        return null;
    try {
        const parsed = JSON.parse(match[0]);
        return {
            intent_read: typeof parsed.intent_read === 'string' ? parsed.intent_read : '',
            prompt_enrichment: typeof parsed.prompt_enrichment === 'string' ? parsed.prompt_enrichment : '',
            clarifying_questions: Array.isArray(parsed.clarifying_questions) ? parsed.clarifying_questions.slice(0, 2).map(String) : [],
            relevant_specialists: Array.isArray(parsed.relevant_specialists) ? parsed.relevant_specialists.map(String) : [],
            risk_flags: Array.isArray(parsed.risk_flags) ? parsed.risk_flags.map(String) : [],
        };
    }
    catch {
        return null;
    }
}
export async function personaThink(args, deps = {}) {
    if (deps.budgetExceeded) {
        return { ...EMPTY, budget_skipped: true };
    }
    // ── Contract A: shared Opus ledger check (BEFORE the call) ──────────────────
    // Resolve ledger path: explicit > brainDir > env/default
    const lPath = deps.ledgerPath ?? (deps.brainDir ? join(deps.brainDir, 'opus-budget.json') : null);
    const opusCap = deps.opusCap ?? Number(process.env.COST_ROUTER_OPUS_CAP_USD ?? '5.0');
    if (lPath) {
        const ledger = await readOpusLedger(lPath).catch(() => null);
        if (ledger && ledger.opus_cost_usd >= opusCap) {
            return {
                ...EMPTY,
                budget_skipped: true,
                error: `Opus daily budget exhausted (spent $${ledger.opus_cost_usd.toFixed(4)} of $${opusCap} cap) — try later or raise COST_ROUTER_OPUS_CAP_USD`,
            };
        }
    }
    const runner = deps.runner ?? defaultRunner;
    const model = deps.model ?? DEFAULT_MODEL;
    const hints = (args.context_hints ?? []).join('\n');
    const user = hints ? `Context hints:\n${hints}\n\nUser prompt:\n${args.prompt}` : args.prompt;
    try {
        const raw = await runner(SYSTEM_PROMPT, user, model);
        const brief = parseBrief(raw);
        if (!brief)
            return { ...EMPTY, error: 'no JSON in response' };
        // ── Contract A: record cost to shared Opus ledger (AFTER the call) ─────────
        if (lPath) {
            // Use injected token counts (for tests) or fall back to a fixed-cost estimate
            const inputTok = deps.inputTokens ?? 0;
            const outputTok = deps.outputTokens ?? 0;
            if (inputTok > 0 || outputTok > 0) {
                await recordOpusLedger(lPath, inputTok, outputTok).catch(() => { });
            }
            else {
                // Fall back to legacy fixed-cost estimate for backward compat
                await recordSpend(deps.brainDir, COST_PER_CALL).catch(() => { });
            }
        }
        else if (deps.brainDir) {
            // Legacy path: no ledgerPath, just record to the persona budget
            await recordSpend(deps.brainDir, COST_PER_CALL).catch(() => { });
        }
        return brief;
    }
    catch (e) {
        return { ...EMPTY, error: e?.message ?? String(e) };
    }
}
export async function readBudget(brainDir) {
    const file = join(brainDir, 'persona-budget.json');
    const today = new Date().toISOString().slice(0, 10);
    try {
        const txt = await fs.readFile(file, 'utf-8');
        const j = JSON.parse(txt);
        if (j.date === today)
            return { date: today, today_usd: Number(j.today_usd) || 0 };
    }
    catch { }
    return { date: today, today_usd: 0 };
}
export async function recordSpend(brainDir, usd) {
    const current = await readBudget(brainDir);
    const next = { date: current.date, today_usd: current.today_usd + usd };
    await fs.mkdir(brainDir, { recursive: true }).catch(() => { });
    await fs.writeFile(join(brainDir, 'persona-budget.json'), JSON.stringify(next));
    return next;
}
//# sourceMappingURL=persona-think.js.map