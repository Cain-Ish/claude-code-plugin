// V2-D21 option (b), the hook: the run's precomputed path inventory, delivered when the prompt arrives. Each call is
// logged to <run dir>/deliveries.jsonl, which D20's harness reads to check the delivery happened.
// V2-D22's pull check reuses it: [file] names another text in the run dir (the forced-decision text), delivered once
// per event, so it reaches the first prompt only.
//   node inventory-hook.mjs <run dir> [file]
import fs from 'node:fs';
import path from 'node:path';

const [dir, file] = process.argv.slice(2);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const logPath = path.join(dir, 'deliveries.jsonl');
const done = file && fs.existsSync(logPath)
  && fs.readFileSync(logPath, 'utf8').split('\n').some((l) => l && JSON.parse(l).ev === input.hook_event_name && JSON.parse(l).text === file);
if (!done) {
  const text = fs.readFileSync(path.join(dir, file ?? 'inventory.txt'), 'utf8');
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: input.hook_event_name, additionalContext: text } }));
  fs.appendFileSync(logPath, `${JSON.stringify({ ev: input.hook_event_name, ...(file ? { text: file } : { inventory: true }),
    bytes: Buffer.byteLength(text), ms: Math.round(process.uptime() * 1000) })}\n`);
}
