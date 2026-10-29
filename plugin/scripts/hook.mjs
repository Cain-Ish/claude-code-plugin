// One process per hook event (V2-D18): node hook.mjs <session-start|prompt|read|onboard>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAP, index, openEpoch, takeForce, labels, rel, toplevel, startText } from './map.mjs';

const emit = (ev, text) => { if (text) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
const which = process.argv[2];
const input = which === 'onboard' ? {} : JSON.parse(fs.readFileSync(0, 'utf8'));
const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd());

if (which === 'session-start') {
  const idx = index(root);
  // the marker only serves the forced decision: a missing or read-only TEMP must not cost the rest (D18, 2g)
  if (idx) try { openEpoch(input.session_id); } catch {}
  emit('SessionStart', startText(idx).text);
} else if (which === 'prompt') {
  // the hook also fires on a background subagent's report and another session's message: the force waits for a typed
  // prompt (06, 2i). shortcut: matched on the wrappers transcripts record; another form spends the force as before
  if (!/^\s*(Another Claude session sent a message:|<(task-notification|cross-session-message|agent-message)[\s>])/.test(input.prompt ?? '')) emit('UserPromptSubmit', takeForce(input.session_id));
} else if (which === 'read') {
  const file = rel(root, input.tool_input?.file_path);
  if (file.startsWith(`${MAP}/`) && file.endsWith('.md')) {
    let text;
    // fail closed: whatever goes wrong, the file's entries are not delivered as reviewed (D14, D18)
    try { text = labels(root, file); } catch { text = `[project map] The labels for ${file} could not be computed: treat every entry in it as unreviewed and unverified.\n`; }
    emit('PostToolUse', text);
  }
} else if (which === 'onboard') {
  const gitVersion = spawnSync('git', ['--version'], { encoding: 'utf8' }).stdout?.trim();
  const idx = index(root);
  const fit = startText(idx);
  const mapDir = path.join(root, MAP);
  const mapFiles = fs.existsSync(mapDir) ? fs.readdirSync(mapDir).filter((f) => f.endsWith('.md')).length : 0;
  console.log([
    `Node ${process.version}${Number(process.versions.node.split('.')[0]) < 20 ? ': the project map needs Node 20 or later' : ''}`,
    gitVersion ?? 'git not found: the project map needs git',
    idx === null ? 'Not a git repository: the index lists the files git tracks, so it is empty here.'
      : `Index: ${fit.total ? idx.split('\n').slice(1, -1).reduce((n, l) => n + l.split(', ').length, 0) : 0} documents in ${fit.total} directories, ${Buffer.byteLength(idx)} bytes at session start.`,
    ...(fit.listed < fit.total ? [`Warning: session start is past the 10,000-character limit of one hook output, so it lists ${fit.listed} of the index's ${fit.total} directories.`] : []),
    `Map: ${mapFiles} file(s) in ${MAP}/.`,
  ].join('\n'));
}
