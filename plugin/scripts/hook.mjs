// One process per hook event (V2-D18): node hook.mjs <session-start|prompt|read|onboard>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { INSTRUCTION, NAME, MAP, index, openEpoch, takeForce, labels, rel } from './map.mjs';

const emit = (ev, text) => { if (text) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
const which = process.argv[2];
const input = which === 'onboard' ? {} : JSON.parse(fs.readFileSync(0, 'utf8'));
const root = process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd();

if (which === 'session-start') {
  const idx = index(root);
  if (idx) openEpoch(input.session_id);
  emit('SessionStart', idx ? `${INSTRUCTION}\n\n${idx}\n${NAME}` : `${INSTRUCTION}\n\n${NAME}`);
} else if (which === 'prompt') {
  emit('UserPromptSubmit', takeForce(input.session_id));
} else if (which === 'read') {
  const file = rel(root, input.tool_input?.file_path);
  if (file.startsWith(`${MAP}/`) && file.endsWith('.md')) emit('PostToolUse', labels(root, file));
} else if (which === 'onboard') {
  const gitVersion = spawnSync('git', ['--version'], { encoding: 'utf8' }).stdout?.trim();
  const idx = index(root);
  const lines = idx ? idx.split('\n').slice(1, -1) : [];
  const mapDir = path.join(root, MAP);
  const mapFiles = fs.existsSync(mapDir) ? fs.readdirSync(mapDir).filter((f) => f.endsWith('.md')).length : 0;
  console.log([
    `Node ${process.version}${Number(process.versions.node.split('.')[0]) < 20 ? ': the project map needs Node 20 or later' : ''}`,
    gitVersion ?? 'git not found: the project map needs git',
    idx === null ? 'Not a git repository: the index lists the files git tracks, so it is empty here.'
      : `Index: ${lines.reduce((n, l) => n + l.split(', ').length, 0)} documents in ${lines.length} directories, ${Buffer.byteLength(idx)} bytes at session start.`,
    `Map: ${mapFiles} file(s) in ${MAP}/.`,
  ].join('\n'));
}
