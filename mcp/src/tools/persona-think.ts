import { spawn } from 'child_process';

export interface PersonaThinkArgs {
  prompt: string;
  context_hints?: string[];
}

export interface PersonaBrief {
  intent_read: string;
  prompt_enrichment: string;
  clarifying_questions: string[];
  relevant_specialists: string[];
  risk_flags: string[];
  error?: string;
  cached?: boolean;
}

export interface PersonaThinkDeps {
  runner?: (system: string, user: string, model: string) => Promise<string>;
  model?: string;
}

const DEFAULT_MODEL = process.env.SB_PERSONA_MODEL ?? 'claude-opus-4-7';
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

function defaultRunner(system: string, user: string, model: string): Promise<string> {
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
      setTimeout(() => { if (!p.killed) p.kill('SIGKILL'); }, 2000);
      reject(new Error(`timeout after ${THINK_TIMEOUT_MS}ms`));
    }, THINK_TIMEOUT_MS);
    p.stdout.on('data', (d) => { out += d.toString(); });
    p.stderr.on('data', (d) => { err += d.toString(); });
    p.on('error', (e) => { clearTimeout(timer); if (!killed) reject(e); });
    p.on('close', (code) => {
      clearTimeout(timer);
      if (killed) return;
      if (code === 0) resolve(out);
      else reject(new Error(err || `claude -p exited ${code}`));
    });
    p.stdin.write(user);
    p.stdin.end();
  });
}

const EMPTY: PersonaBrief = {
  intent_read: '',
  prompt_enrichment: '',
  clarifying_questions: [],
  relevant_specialists: [],
  risk_flags: [],
};

function parseBrief(raw: string): PersonaBrief | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const parsed = JSON.parse(match[0]);
    return {
      intent_read: typeof parsed.intent_read === 'string' ? parsed.intent_read : '',
      prompt_enrichment: typeof parsed.prompt_enrichment === 'string' ? parsed.prompt_enrichment : '',
      clarifying_questions: Array.isArray(parsed.clarifying_questions) ? parsed.clarifying_questions.slice(0, 2).map(String) : [],
      relevant_specialists: Array.isArray(parsed.relevant_specialists) ? parsed.relevant_specialists.map(String) : [],
      risk_flags: Array.isArray(parsed.risk_flags) ? parsed.risk_flags.map(String) : [],
    };
  } catch {
    return null;
  }
}

export async function personaThink(args: PersonaThinkArgs, deps: PersonaThinkDeps = {}): Promise<PersonaBrief> {
  const runner = deps.runner ?? defaultRunner;
  const model = deps.model ?? DEFAULT_MODEL;
  const hints = (args.context_hints ?? []).join('\n');
  const user = hints ? `Context hints:\n${hints}\n\nUser prompt:\n${args.prompt}` : args.prompt;

  try {
    const raw = await runner(SYSTEM_PROMPT, user, model);
    const brief = parseBrief(raw);
    if (!brief) return { ...EMPTY, error: 'no JSON in response' };
    return brief;
  } catch (e: any) {
    return { ...EMPTY, error: e?.message ?? String(e) };
  }
}
