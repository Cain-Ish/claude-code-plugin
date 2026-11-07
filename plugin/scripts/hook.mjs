// One process per hook event (V2-D18): node hook.mjs <session-start|prompt|read|bash|onboard>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAP, CAP, index, openEpoch, takeForce, labels, rel, toplevel, startText, V1_LEFT } from './map.mjs';

// note: a line for the user, not for Claude's context (V2-D27)
const emit = (ev, text, note) => { if (text || note) process.stdout.write(JSON.stringify({ ...(note && { systemMessage: note }), hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
const which = process.argv[2];
const input = which === 'onboard' ? {} : JSON.parse(fs.readFileSync(0, 'utf8'));
const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd());
// fail closed: whatever goes wrong, the file's entries are not delivered as reviewed (D14, D18)
const closed = (file, why = 'could not be computed') => `[project map] The labels for ${file} ${why}: treat every entry in it as unreviewed and unverified.\n`;
const labelled = (file) => { try { return labels(root, file); } catch { return closed(file); } };

if (which === 'session-start') {
  const idx = index(root);
  // the marker only serves the forced decision: a missing or read-only TEMP must not cost the rest (D18, 2g)
  if (idx) try { openEpoch(input.session_id); } catch {}
  // v1's statusline and timer shims outlive an update to v2 (V2-D26)
  const brain = process.env.BRAIN_DIR || path.join(os.homedir(), '.second-brain');
  const v1 = ['buddy-statusline.sh', 'sb-extract-drain.sh'].some((f) => fs.existsSync(path.join(brain, 'bin', f)));
  emit('SessionStart', startText(idx).text, v1 ? V1_LEFT : undefined);
} else if (which === 'prompt') {
  // the hook also fires on a background subagent's report and another session's message: the force waits for a typed
  // prompt (06, 2i). shortcut: matched on the wrappers transcripts record; another form spends the force as before
  if (!/^\s*(Another Claude session sent a message:|<(task-notification|cross-session-message|agent-message)[\s>])/.test(input.prompt ?? '')) emit('UserPromptSubmit', takeForce(input.session_id));
} else if (which === 'read') {
  const file = rel(root, input.tool_input?.file_path);
  if (file.startsWith(`${MAP}/`) && file.endsWith('.md')) emit('PostToolUse', labelled(file));
} else if (which === 'bash' || which === 'bash-failure') {
  // a map file read through Bash gets what a Read of it gets (D14, 06 2j): a part of the command, between |, ;, & or a
  // line break, with a read verb that names a map file and does not redirect into the folder. A command that exits
  // non-zero comes as PostToolUseFailure (06 2m). shortcut: a script that reads the file, or a command that names only
  // the folder, stays unlabelled (04's accepted risk)
  // only this repo's own map files, as a Read labels them (06 2m): each path is the shell's, from the hook's cwd and
  // each cd before it. shortcut: a cd inside a subshell is taken to last, so a file after the subshell may go unlabelled
  const shell = (p) => (p === '~' || p.startsWith('~/') ? os.homedir() + p.slice(1) : process.platform === 'win32' ? p.replace(/^\/([a-z])(\/|$)/i, '$1:/') : p);
  const real = (d) => { try { return fs.realpathSync(d); } catch { return d; } };
  const ours = (d) => path.relative(root, d) === '' || path.relative(real(root), real(d)) === '';
  let cwd = input.cwd ?? root;
  const files = new Map(); // a map file -> false when a cd before it could not be followed: it then fails closed
  for (const part of String(input.tool_input?.command ?? '').split(/[|;&\n]/)) {
    if (/^[\s({]*(cd|pushd)(\s|$)/.test(part)) {
      const t = /^[\s({]*(?:cd|pushd)(?:\s+(['"]?)([^'"\s$]+)\1)?\s*$/.exec(part);
      cwd = !t || cwd === null || t[2]?.startsWith('-') ? null : t[2] ? path.resolve(cwd, shell(t[2])) : os.homedir();
      continue;
    }
    if (!/\b(cat|head|tail|sed|grep|less|more|awk)\b/.test(part) || />\s*['"]?[^\s'"]*\.project-map\//.test(part)) continue;
    for (const m of part.matchAll(/([^\s'"`<>=]*)\.project-map\/([^\s'"`<>]+?\.md)(?![\w.-])/g)) {
      const f = path.posix.normalize(`${MAP}/${m[2]}`);
      if (!f.startsWith(`${MAP}/`)) continue;
      if (cwd === null) files.set(f, false);
      else if (!files.has(f) && ours(path.resolve(cwd, shell(m[1]) || '.'))) files.set(f, true);
    }
  }
  // the files share one output: whole files' labels while they fit beside the closing lines of the rest (D18, J3)
  const parts = [...files].map(([f, ok]) => [f, ok ? labelled(f) : closed(f)]).filter(([, t]) => t);
  const rest = (k) => parts.slice(k).map(([f]) => closed(f, 'are not shown')).join('');
  let out = '';
  let k = 0;
  for (; k < parts.length && out.length + parts[k][1].length + rest(k + 1).length <= CAP; k++) out += parts[k][1];
  emit(which === 'bash' ? 'PostToolUse' : 'PostToolUseFailure', out + rest(k));
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
