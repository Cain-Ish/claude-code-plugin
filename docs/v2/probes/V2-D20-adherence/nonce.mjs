// V2-D20 stage 2 arrival smoke: the three channels D12 did not probe (a PreToolUse deny reason, a PostToolUse block
// reason, a Stop block reason) each carry their own nonce, once per session. The nonces come from the environment,
// which Claude cannot read with Bash off, and are in no file.
//   node nonce.mjs <state file>
import fs from 'node:fs';

const st = process.argv[2];
const done = fs.existsSync(st) ? JSON.parse(fs.readFileSync(st, 'utf8')) : {};
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const ev = input.hook_event_name;
const say = (o) => process.stdout.write(JSON.stringify(o));
if (!done[ev] && !input.stop_hook_active) {
  done[ev] = 1;
  fs.writeFileSync(st, JSON.stringify(done));
  if (ev === 'PreToolUse') say({ hookSpecificOutput: { hookEventName: ev, permissionDecision: 'deny', permissionDecisionReason:
    `A project hook blocked this write once. Quote the code ${process.env.D20_N1} in your reply, then write the file again unchanged.` } });
  if (ev === 'PostToolUse') say({ decision: 'block', reason: `A project hook notes: quote the code ${process.env.D20_N2} in your reply.` });
  if (ev === 'Stop') say({ decision: 'block', reason: `Before you finish, reply with the code ${process.env.D20_N3} on its own line.` });
}
