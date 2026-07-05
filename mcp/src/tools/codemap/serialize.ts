/**
 * P3a Task A4 -- graph -> token-capped map.md serializer.
 *
 * INVARIANT (tested, load-bearing for code_map injection): the emitted text's
 * chars/4 token estimate NEVER exceeds tokenBudget. chars/4 is the project's
 * coarse token convention; because it drifts vs a real tokenizer, lines stop
 * at budget*0.95 -- the 5% margin absorbs estimate error, and the omission
 * footer is accounted INSIDE the cap (reserved before each line is admitted),
 * so appending it can never blow the budget at the boundary.
 *
 * Trusts graph.files rank-desc/id-asc ordering (build-graph's tested
 * contract) rather than re-sorting: re-sorting here could mask an upstream
 * ordering regression that determinism tests are meant to catch.
 *
 * Pure: no fs, no clock; the env read happens only in the default-parameter
 * expression at the call boundary, so an explicit budget is referentially
 * transparent.
 */

import type { CodeGraph, FileNode } from './types.js';

const DEFAULT_TOKEN_BUDGET = 2000;
const BUDGET_MARGIN = 0.95;
const CHARS_PER_TOKEN = 4;

/** 'src/a.ts — foo, Bar' | 'src/a.ts' (no symbols). */
function fileLine(f: FileNode): string {
  return f.symbols.length > 0 ? `${f.id} — ${f.symbols.join(', ')}` : f.id;
}

function footerLine(omitted: number): string {
  return `(+${omitted} more files omitted)`;
}

/**
 * Env boundary: a garbage or NEGATIVE SB_CODEMAP_TOKEN_BUDGET falls back to
 * the default (adversarial-review fix — `Number(env)||default` passed -500
 * through as truthy, serialize threw, the fail-soft CLI swallowed it, and
 * codemap generation was PERMANENTLY disabled for that environment). An
 * EXPLICIT bad argument still throws below: that is a programmer error, not
 * an operator typo.
 */
function envTokenBudget(): number {
  const n = Number(process.env.SB_CODEMAP_TOKEN_BUDGET);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TOKEN_BUDGET;
}

export function serialize(
  graph: CodeGraph,
  tokenBudget: number = envTokenBudget(),
): string {
  if (!Number.isFinite(tokenBudget) || tokenBudget <= 0) {
    throw new Error(
      `serialize: tokenBudget must be a positive finite number, got ${tokenBudget}`,
    );
  }
  const total = graph.files.length;
  if (total === 0) return '';

  const capChars = Math.floor(tokenBudget * BUDGET_MARGIN * CHARS_PER_TOKEN);
  // A budget that cannot carry even the all-omitted footer is a caller bug
  // (the MCP surface floors token_budget at 200) -- fail loud, don't emit a
  // map that silently violates the cap invariant.
  if (footerLine(total).length + 1 > capChars) {
    throw new Error(
      `serialize: tokenBudget ${tokenBudget} too small to emit even the omission footer`,
    );
  }

  const lines: string[] = [];
  let used = 0; // chars, each line accounted as length + 1 for its newline
  let included = 0;
  for (const f of graph.files) {
    const line = fileLine(f);
    const remainingAfter = total - included - 1;
    // Admit the line only if the footer that would follow a stop AFTER it
    // still fits -- this keeps "stop now and emit footer" always legal.
    const footerReserve = remainingAfter > 0 ? footerLine(remainingAfter).length + 1 : 0;
    if (used + line.length + 1 + footerReserve > capChars) break;
    lines.push(line);
    used += line.length + 1;
    included++;
  }

  const omitted = total - included;
  if (omitted > 0) lines.push(footerLine(omitted));
  return lines.join('\n') + '\n';
}
