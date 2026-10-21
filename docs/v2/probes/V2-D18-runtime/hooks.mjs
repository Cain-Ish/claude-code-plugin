// V2-D18 hook scripts, attempt 2, one per event; each is `node hooks.mjs <event>` (exec form: no shell).
//   session-start   the Node check, the cache refreshed and the uncommitted set re-read, D14's capture instruction
//   on-read         after a Read: the file's own entries, then keyed entries (D22 run 3), guarded, at most 8 KB
//   on-write        after a Write or Edit: the same for the written file (the write-time net), guarded
//   deliver30       bench only: the guards over the first 30 entries of one source, as a push of 30 would run them
import { nestedExit, readInput, rel, refresh, entriesFor, deliver, emit, shard, INSTRUCTION } from './lib.mjs';

nestedExit();
const which = process.argv[2];
const input = readInput();
const root = process.env.CLAUDE_PROJECT_DIR ?? input.cwd;

if (which === 'session-start') {
  if (Number(process.versions.node.split('.')[0]) < 20) {
    process.stdout.write(JSON.stringify({ systemMessage: `The project map needs Node 20 or later (found ${process.version}); it stays off until then.` }));
    process.exit(0);
  }
  refresh(root, true);
  emit('SessionStart', INSTRUCTION);
} else if (which === 'on-read' || which === 'on-write') {
  refresh(root);
  const file = rel(root, input.tool_input?.file_path);
  const out = deliver(root, entriesFor(root, file));
  if (out.length) emit('PostToolUse', `[map] Project knowledge recorded for ${file}:\n\n${out.map((o) => o.block).join('\n')}`);
} else if (which === 'deliver30') {
  refresh(root);
  const out = deliver(root, shard(root, input.source).slice(0, 30));
  emit('UserPromptSubmit', out.map((o) => o.block).join('\n'));
}
