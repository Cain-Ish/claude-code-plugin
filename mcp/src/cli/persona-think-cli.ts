// Standalone entry for the /? prefix path in persona-context.sh.
// Reads the user prompt from stdin (or argv), prints the structured brief
// as compact markdown lines so the bash hook can wrap it as additionalContext.
import { join } from 'path';
import { personaThink, readBudget } from '../tools/persona-think.js';

const brainDir = process.env.BRAIN_DIR || join(process.env.HOME ?? process.env.USERPROFILE ?? '', '.second-brain');
const dailyBudget = Number(process.env.SB_PERSONA_DAILY_BUDGET ?? '20');

const argvPrompt = process.argv.slice(2).join(' ').trim();
const stdinPrompt = await new Promise<string>((resolve) => {
  if (process.stdin.isTTY) return resolve('');
  let buf = '';
  process.stdin.setEncoding('utf-8');
  process.stdin.on('data', (d) => { buf += d; });
  process.stdin.on('end', () => resolve(buf.trim()));
});
const prompt = argvPrompt || stdinPrompt;
if (!prompt) process.exit(0);

const budget = await readBudget(brainDir);
const budgetExceeded = budget.today_usd >= dailyBudget;

const r = await personaThink({ prompt }, { budgetExceeded, brainDir });

if (r.budget_skipped) {
  process.stdout.write(`[persona think skipped — daily budget $${dailyBudget} reached]\n`);
  process.exit(0);
}
if (r.error) {
  process.stderr.write(`persona think error: ${r.error}\n`);
  process.exit(0);
}

const lines: string[] = [];
if (r.intent_read) lines.push(`Intent: ${r.intent_read}`);
if (r.prompt_enrichment) lines.push(`Enrichment: ${r.prompt_enrichment}`);
if (r.clarifying_questions.length) lines.push(`Ask user: ${r.clarifying_questions.map((q, i) => `${i + 1}) ${q}`).join('  ')}`);
if (r.relevant_specialists.length) lines.push(`Consider: ${r.relevant_specialists.join(', ')}`);
if (r.risk_flags.length) lines.push(`Risks: ${r.risk_flags.join('; ')}`);

process.stdout.write(lines.join('\n') + '\n');
