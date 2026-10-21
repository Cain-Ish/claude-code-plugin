// V2-D18 prototype hook scripts, one per event; each is `node hooks.mjs <event>` so they share one module load.
//   session-start   D14's capture instruction; the cache rebuilt if any map file is newer
//   on-read         after a Read: the file's own entries, then keyed entries (D22 run 3), guarded, at most 8 KB
//   on-write        after a Write or Edit: the written file's keyed entries (the write-time net), guarded
//   deliver30       bench only: the guards over the first 30 entries of the map, as a push of 30 would run them
import { INSTRUCTION } from '../V2-D14-capture/instruction.mjs';
import { nestedExit, readInput, rel, buildCache, cacheStale, entriesFor, deliver, emit, shard } from './lib.mjs';

nestedExit();
const which = process.argv[2];
const input = readInput();
const root = input.cwd;

if (which === 'session-start') {
  if (cacheStale(root)) buildCache(root);
  emit('SessionStart', INSTRUCTION);
} else if (which === 'on-read' || which === 'on-write') {
  const file = rel(root, input.tool_input?.file_path);
  const out = deliver(root, entriesFor(root, file));
  if (out.length) emit('PostToolUse', `[map] Project knowledge recorded for ${file}:\n\n${out.map((o) => o.block).join('\n')}`);
} else if (which === 'deliver30') {
  const out = deliver(root, shard(root, input.source).slice(0, 30));
  emit('UserPromptSubmit', out.map((o) => o.block).join('\n'));
}
