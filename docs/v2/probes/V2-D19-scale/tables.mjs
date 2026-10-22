// The Opus re-baseline's thresholds as Markdown for 05-eval-plan.md, from the scripted results only: A1 from
// V2-D17-eval/results/summary-opus.json, A2 and the investigation tasks from results/rebase-opus.json (native.mjs
// rebase). D17's rule with the gap-target forms (D17, D19): below = M1's median minus its spread; at floor 0 a rule
// needs 8 of 10; where the spread is at least the median, no gain is claimed and v2 stays at or below median plus
// spread.
//   node tables.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const a1 = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'V2-D17-eval', 'results', 'summary-opus.json'), 'utf8')).M1;
const a2 = JSON.parse(fs.readFileSync(path.join(HERE, 'results', 'rebase-opus.json'), 'utf8'));
const num = (x) => (Number.isInteger(x) ? x.toLocaleString('en-US') : Math.abs(x) < 100 ? x.toFixed(2) : x.toLocaleString('en-US', { maximumFractionDigits: 0 }));
const cell = (m) => (!m ? 'n/a' : m.noGain ? `no gain; at most ${num(m.ceiling)} (${num(m.median)}, ${num(m.spread)})` : `below ${num(m.median - m.spread)} (${num(m.median)}, ${num(m.spread)})`);
const fromStat = (s) => (s.median - s.spread > 0 ? { median: s.median, spread: s.spread } : { median: s.median, spread: s.spread, noGain: true, ceiling: s.median + s.spread });
const target = (n) => (n === 0 ? '0, target 8' : String(n));
const out = [];

out.push('#### A1 (M1, 10 valid chains)', '');
out.push(`- Pass items, M1's count of 10 (v2 needs at least that; at 0, 8): ${Object.entries({ ...a1.capture, ...a1.test, ...a1.neighbour }).map(([k, v]) => `${k} ${target(v)}`).join(', ')}.`);
const m = a1.metrics;
out.push(`- Tool calls before the first write: ${cell(fromStat(m.toolCallsBeforeFirstWrite))}. Files read before it: ${cell(fromStat(m.filesReadBeforeFirstWrite))}.`);
out.push(`- T tokens, all kinds: ${cell(fromStat(m.tTokensTotal))}. T output tokens: ${cell(fromStat(m.tOutputTokens))}. T USD: ${cell(fromStat(m.tCostUsd))}.`);
out.push(`- Always-on bytes (recorded, no threshold): ${num(m.alwaysOnBytes.median)}.`, '');

out.push('#### A2 and the investigation tasks (M1)', '');
out.push('| Task | M1 arm, valid runs, stopped | Rules (M1\'s count of 10) |', '| --- | --- | --- |');
for (const [id, t] of Object.entries(a2.tasks)) {
  out.push(`| ${id} | ${t.m1Arm}, ${t.validRuns}, ${t.stopped ?? '-'} | ${Object.entries(t.rules).map(([r, v]) => `${r} ${target(v.m1)}`).join(', ')} |`);
}
out.push('', '| Task | Tool calls before the first write | Files read before it | Tokens, all kinds | Output tokens | USD |', '| --- | --- | --- | --- | --- | --- |');
for (const [id, t] of Object.entries(a2.tasks)) {
  const x = t.measures;
  out.push(`| ${id} | ${cell(x.toolCallsBeforeFirstWrite)} | ${cell(x.filesReadBeforeFirstWrite)} | ${cell(x.tokensAll)} | ${cell(x.outputTokens)} | ${cell(x.costUsd)} |`);
}
out.push('', 'In brackets: M1\'s median and spread. Tokens and USD cover the whole session, subagents included.');
console.log(out.join('\n'));
