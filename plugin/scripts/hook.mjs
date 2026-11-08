// One process per hook event (V2-D18): node hook.mjs <session-start|prompt|read|bash|bash-failure|onboard>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAP, CAP, index, openEpoch, takeForce, labels, rel, toplevel, startText, under, V1_LEFT } from './map.mjs';

// note: a line for the user, not for Claude's context (V2-D27)
const emit = (ev, text, note) => { if (text || note) process.stdout.write(JSON.stringify({ ...(note && { systemMessage: note }), hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
const which = process.argv[2];
const input = which === 'onboard' ? {} : JSON.parse(fs.readFileSync(0, 'utf8'));
const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd());
// fail closed: whatever goes wrong, the file's entries are not delivered as reviewed (D14, D18)
const closed = (file, why = 'could not be computed') => `[project map] The labels for ${file} ${why}: treat every entry in it as unreviewed and unverified.\n`;
const labelled = (file, output) => { try { return labels(root, file, output); } catch { return closed(file); } };

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
  // a Bash command that names the map folder gets every uncommitted entry's labels, and those of the committed entries
  // its output shows (D14, 06 2o): the output is every string in tool_response (stdout, stderr), or the failure's
  // error text. shortcut: a command that does not name the map folder never starts this handler (the if field), so
  // `git diff` from the root stays unlabelled (04's accepted risk)
  const ev = which === 'bash' ? 'PostToolUse' : 'PostToolUseFailure';
  const strings = (v) => (typeof v === 'string' ? [v] : v && typeof v === 'object' ? Object.values(v).flatMap(strings) : []);
  const got = strings(which === 'bash' ? input.tool_response : input.error);
  // the hook sees only part of what Claude can reach when a background command's output comes later, or Claude Code
  // cut the output and saved it to a file (2n, attempt 2): then every map file's labels, as a Read of each gives them.
  // A long string is the guard should those fields be renamed
  const part = ['backgroundTaskId', 'persistedOutputPath'].some((k) => input.tool_response?.[k]) || got.some((s) => s.length >= 25_000);
  const output = part || /characters truncated/.test(got.join('\n')) ? undefined : got.join('\n').replace(/\r/g, '');
  // the map's .md files, in git's order, through links to folders, each folder once; when the folder exists, any error
  // listing it fails closed as a whole (2o attempt 2: a subfolder that cannot be opened also throws ENOENT)
  let files;
  try { files = under(root, MAP, new Set([fs.realpathSync(path.join(root, MAP))])).filter((f) => f.endsWith('.md')).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)); } catch (e) { files = e.code === 'ENOENT' && !fs.existsSync(path.join(root, MAP)) ? [] : null; }
  // a listed file that cannot be read fails closed too: labels() reads ENOENT as "no file", and a name that is not
  // valid UTF-8 is listed with U+FFFD, which no read finds (2o attempt 3)
  const walked = (f) => { const t = labelled(f, output); return t || fs.existsSync(path.join(root, f)) ? t : closed(f); };
  // the files share one output: whole files' labels while they fit beside the closing lines of the rest, and one
  // line for all when those alone would not fit (D18, J3; 06 2m)
  const texts = files === null ? [[`${MAP}/`, closed(`${MAP}/`)]] : files.map((f) => [f, walked(f)]).filter(([, t]) => t);
  const rest = (k) => texts.slice(k).map(([f]) => closed(f, 'are not shown')).join('');
  let out = '';
  let k = 0;
  for (; k < texts.length && out.length + texts[k][1].length + rest(k + 1).length <= CAP; k++) out += texts[k][1];
  const tail = out.length + rest(k).length <= CAP ? rest(k)
    : `[project map] The labels for the ${texts.length - k} map files this command read are not shown: treat every entry in them as unreviewed and unverified.\n`;
  // a command that exits non-zero comes as PostToolUseFailure, with the same text (06 2m)
  emit(ev, got.length ? out + tail
    : '[project map] The output of this command could not be read, so the map entries it showed are not labelled: treat every map entry it showed as unreviewed and unverified.\n');
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
