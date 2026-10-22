// V2-D21 option (b), the hook: the run's precomputed path inventory, delivered when the prompt arrives. Each call is
// logged to <run dir>/deliveries.jsonl, which D20's harness reads to check the delivery happened.
// V2-D22's pull check reuses it: [file] names another text in the run dir (the forced-decision text), delivered once
// per event, so it reaches the first prompt only. With [epoch] set, once per epoch instead: again at the first prompt
// after each compaction (arm pfr).
//   node inventory-hook.mjs <run dir> [file] [epoch]
import fs from 'node:fs';
import path from 'node:path';

const [dir, file, epoch] = process.argv.slice(2);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const logPath = path.join(dir, 'deliveries.jsonl');
const lines = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
// the log is the state; an epoch starts at the index's re-delivery after a compaction
const since = epoch ? lines.slice(lines.findLastIndex((l) => l.ev === 'SessionStart' && l.source === 'compact') + 1) : lines;
const done = file && since.some((l) => l.ev === input.hook_event_name && l.text === file);
if (!done) {
  const text = fs.readFileSync(path.join(dir, file ?? 'inventory.txt'), 'utf8');
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: input.hook_event_name, additionalContext: text } }));
  fs.appendFileSync(logPath, `${JSON.stringify({ ev: input.hook_event_name, ...(file ? { text: file } : { inventory: true }),
    ...(input.source ? { source: input.source } : {}), bytes: Buffer.byteLength(text), ms: Math.round(process.uptime() * 1000) })}\n`);
}
