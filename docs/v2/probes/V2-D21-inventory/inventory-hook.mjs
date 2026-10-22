// V2-D21 option (b), the hook: the run's precomputed path inventory, delivered when the prompt arrives. Each call is
// logged to <run dir>/deliveries.jsonl, which D20's harness reads to check the delivery happened.
//   node inventory-hook.mjs <run dir>
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const text = fs.readFileSync(path.join(dir, 'inventory.txt'), 'utf8');
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: input.hook_event_name, additionalContext: text } }));
fs.appendFileSync(path.join(dir, 'deliveries.jsonl'), `${JSON.stringify({ ev: input.hook_event_name, inventory: true,
  bytes: Buffer.byteLength(text), ms: Math.round(process.uptime() * 1000) })}\n`);
