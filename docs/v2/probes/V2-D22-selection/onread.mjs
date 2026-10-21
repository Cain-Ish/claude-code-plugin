// V2-D22 route hook, the user's route ("pick + pointers, then on read"). At the first prompt: the pick's entries (at
// most 8 KB) and its sections as pointers. After each Read of a repo file: that file's map entries in source order,
// at most 8 KB, once per file, none already delivered; nothing for a file with no entries. The run's route comes from
// <run dir>/route.json; every delivery is logged to <run dir>/deliveries.jsonl, which is also the state.
//   node onread.mjs <run dir>
import fs from 'node:fs';
import path from 'node:path';

const t0 = Date.now();
const dir = process.argv[2];
const route = JSON.parse(fs.readFileSync(path.join(dir, 'route.json'), 'utf8'));
const logPath = path.join(dir, 'deliveries.jsonl');
const past = (fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').trim().split('\n') : []).flatMap((l) => (l ? [JSON.parse(l)] : []));
const delivered = new Set(past.flatMap((l) => l.ids ?? []));
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const ev = input.hook_event_name;
const CAP = 8 * 1024;
const show = (id) => route.entries[id].text;
const fill = (ids) => {
  const out = [];
  let used = 0;
  for (const id of ids) {
    const b = Buffer.byteLength(show(id));
    if (!delivered.has(id) && used + b <= CAP) { out.push(id); used += b; }
  }
  return { out, used };
};
let ctx = null;
const log = { ev };

if (ev === 'UserPromptSubmit' && !past.some((l) => l.ev === 'UserPromptSubmit')) {
  const { out, used } = fill(route.push);
  ctx = '[d22-map] Project knowledge for this task, quoted from the project\'s own documents with their source.\n\n'
    + `${out.map(show).join('\n')}\nSections that hold more on this task; read them where the task needs them:\n`
    + route.pointers.map((p) => `- ${p}`).join('\n');
  Object.assign(log, { ids: out, bytes: used + Buffer.byteLength(route.pointers.join('\n')) });
} else if (ev === 'PostToolUse' && input.tool_name === 'Read') {
  // Windows sends the path absolute with backslashes; the map is keyed by the repo-relative path
  const file = path.relative(input.cwd ?? '.', String(input.tool_input?.file_path ?? '')).replace(/\\/g, '/');
  if (route.byFile[file] && !past.some((l) => l.file === file)) {
    const { out, used } = fill(route.byFile[file]);
    if (out.length) {
      ctx = `[d22-map] Project knowledge recorded for ${file}:\n\n${out.map(show).join('\n')}`;
      Object.assign(log, { file, ids: out, bytes: used });
    }
  }
}
if (ctx) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: ctx } }));
fs.appendFileSync(logPath, `${JSON.stringify({ ...log, ms: Date.now() - t0 })}\n`);
