// V2-D20 stage 2 hook. Arm (b), delivery: the task's cards when the prompt arrives, and again as a one-time deny
// before the first write in each card's area. Arm (d) adds the pattern checks after each write and, at Stop, the
// failing checks plus a request for the rule account. The run's cards come from <run dir>/cards.json; every call is
// logged to <run dir>/deliveries.jsonl with its duration.
//   node deliver.mjs <run dir>
import fs from 'node:fs';
import path from 'node:path';
import { check, changedFiles, slash } from './check.mjs';

const dir = process.argv[2];
const { arm, cards } = JSON.parse(fs.readFileSync(path.join(dir, 'cards.json'), 'utf8'));
const logPath = path.join(dir, 'deliveries.jsonl');
// the log is the state: a card already denied-and-delivered before a write is not delivered there again
const logged = (fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').trim().split('\n') : []).flatMap((l) => (l ? [JSON.parse(l)] : []));
const preWrite = logged.filter((l) => l.ev === 'PreToolUse').flatMap((l) => l.cards ?? []);
// stage 3 (arms o*): the cards reach the first prompt of the session only
const prompted = arm.startsWith('o') && logged.some((l) => l.ev === 'UserPromptSubmit' && l.cards);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const ev = input.hook_event_name;
const line = (c) => `- ${c.id} (${c.area}): ${c.text} [source: ${c.source}]`;
const file = slash(path.relative(input.cwd ?? '.', input.tool_input?.file_path ?? input.tool_input?.notebook_path ?? ''));
const log = { ev };
let out = null;

if ((ev === 'UserPromptSubmit' && !prompted) || (ev === 'SessionStart' && arm === 'or')) { // or: again after compaction
  out = { hookSpecificOutput: { hookEventName: ev, additionalContext: '[d20-rules] Rules of this project that bind this '
    + 'task, quoted from its own files with their source. Where existing code differs from a rule, follow the rule.\n'
    + cards.map(line).join('\n') } };
  log.cards = cards.map((c) => c.id);
} else if (ev === 'PreToolUse') {
  const due = cards.filter((c) => c.scope && new RegExp(c.scope).test(file) && !preWrite.includes(c.id));
  if (due.length) {
    out = { hookSpecificOutput: { hookEventName: ev, permissionDecision: 'deny', permissionDecisionReason:
      `[d20-deny] Before you write ${file}: these project rules govern it. Write it again so it follows them (asked `
      + `once per area).\n${due.map(line).join('\n')}` } };
    Object.assign(log, { file, cards: due.map((c) => c.id) });
  }
} else if (ev === 'PostToolUse' && ['d', 'od'].includes(arm)) {
  const { files, fresh } = changedFiles(input.cwd);
  const bad = file in files ? cards.filter((c) => c.cls === 'pattern' && c.check.where !== 'reply'
    && new RegExp(c.check.path ?? '.').test(file) && !check(c.check, { [file]: files[file] }, '', fresh)) : [];
  if (bad.length) {
    out = { decision: 'block', reason: `[d20-check] ${file} breaks a project rule:\n`
      + bad.map((c) => `- ${c.id}: ${c.msg} [source: ${c.source}]`).join('\n') };
    Object.assign(log, { file, cards: bad.map((c) => c.id) });
  }
} else if (ev === 'Stop' && ['d', 'od'].includes(arm) && !input.stop_hook_active) {
  const { files, fresh } = changedFiles(input.cwd);
  const bad = cards.filter((c) => c.cls === 'pattern' && c.check.where !== 'reply' && !check(c.check, files, '', fresh));
  out = { decision: 'block', reason: '[d20-stop] Before you finish:\n'
    + (bad.length ? `These checks fail; fix them first:\n${bad.map((c) => `- ${c.id}: ${c.msg} [source: ${c.source}]`).join('\n')}\n` : '')
    + 'Then end your reply with a section headed exactly "## Rule account" that names every rule below as applied '
    + `(where) or not applicable (why), each with its source.\n${cards.map((c) => `- ${c.id}: ${c.source}`).join('\n')}` };
  log.cards = bad.map((c) => c.id);
}

if (out) { process.stdout.write(JSON.stringify(out)); log.bytes = Buffer.byteLength(JSON.stringify(out)); }
log.ms = Math.round(process.uptime() * 1000);
fs.appendFileSync(logPath, `${JSON.stringify(log)}\n`);
