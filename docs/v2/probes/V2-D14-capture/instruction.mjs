// V2-D14 capture hook: at every SessionStart (startup, resume, clear, compact) it gives Claude the map's capture
// instruction as additionalContext (D12: arrives in the main session; after compaction only because it fires on
// compact too). The instruction names no answer of any eval scenario; its sha256 is recorded in DECISIONS.md.
//   node instruction.mjs            (as a hook: reads the event on stdin)
//   node instruction.mjs --print    (prints the instruction and its hash)
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const INSTRUCTION = `This project keeps a map of its knowledge in the folder .project-map/. When, during your work, someone states a
decision or rule for this project, or you receive or read a document that states requirements, specifications or
rules the project's work must follow, add each one to .project-map/captured.md as its own entry, in the words used,
with its source. Keep what will still matter in later sessions; leave out one-off details of the current task.
Entry format:

### <the part of the project it governs>
> <the decision, rule or requirement, in the words used>

- source: <who stated it, or the document's title or path>, <date>
- when: ["<kind of work it applies to>", "..."]

Never write session ids, email addresses or absolute file paths into an entry. The map is plain files in this
repository: your changes to it stay in the working tree and are reviewed with the commit, like any other change.`;

export const HASH = crypto.createHash('sha256').update(INSTRUCTION).digest('hex').slice(0, 12);

const direct = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (direct && process.argv.includes('--print')) {
  console.log(INSTRUCTION, `\n\nsha256 ${HASH}`);
} else if (direct) {
  const ev = JSON.parse(fs.readFileSync(0, 'utf8')).hook_event_name;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: INSTRUCTION } }));
}
