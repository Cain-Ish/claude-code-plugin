// One process per hook event (V2-D18): node hook.mjs <session-start|prompt|read|bash|bash-failure|onboard|setup>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { MAP, CAP, git, index, openEpoch, takeForce, labels, headTexts, rel, toplevel, startText, under, V1_LEFT, waiting, dreamDue, dreamLeft, safeName, stateDir } from './map.mjs';
import { setup } from './setup.mjs';

// note: a line for the user, not for Claude's context (V2-D27)
const emit = (ev, text, note) => { if (text || note) process.stdout.write(JSON.stringify({ ...(note && { systemMessage: note }), hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
const which = process.argv[2];
// N5 (06, section 4, 4a): on macOS, readFileSync(0) on a socket stdin blocked for good in 13 of 600 probe calls; a
// readSync loop over the same input, 0 of 1,200. So the input is read in chunks until a read returns 0
const readInput = () => {
  const b = Buffer.alloc(65536), parts = [];
  for (let k; (k = fs.readSync(0, b, 0, b.length, null)) > 0;) parts.push(Buffer.from(b.subarray(0, k)));
  return Buffer.concat(parts).toString('utf8');
};
// Q-13 (06, 8k): below Node 20 a hook exits 0 before it reads its input (Node 16 failed there), and only session start
// says so, once a session; onboard and setup print their own reports
const old = !['onboard', 'setup'].includes(which) && Number(process.versions.node.split('.')[0]) < 20;
const input = old || ['onboard', 'setup'].includes(which) ? {} : JSON.parse(readInput());
const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd());
// fail closed: whatever goes wrong, the file's entries are not delivered as reviewed (D14, D18)
const closed = (file, why = 'could not be computed') => `[project map] The labels for ${safeName(file)} ${why}: treat every entry in it as unreviewed and unverified.\n`;
const labelled = (file, output, heads) => { try { return labels(root, file, output, heads); } catch { return closed(file); } };

if (old) {
  if (which === 'session-start') process.stdout.write(JSON.stringify({ systemMessage: 'The project map needs Node 20 or later; install it, or disable the plugin.' }));
} else if (which === 'session-start') {
  // v1's statusline and timer shims outlive an update to v2 (V2-D26)
  const brain = process.env.BRAIN_DIR || path.join(os.homedir(), '.second-brain');
  const v1 = ['buddy-statusline.sh', 'sb-extract-drain.sh'].some((f) => fs.existsSync(path.join(brain, 'bin', f)));
  // 06, section 3, S6 (D32): what waits for review, and whether a dream is due, for the user only, at a session's
  // start or after /clear; any failure here costs the rest nothing
  const notes = v1 ? [V1_LEFT] : [];
  const idx = index(root, notes);
  // the marker only serves the forced decision: a missing or read-only TEMP must not cost the rest (D18, 2g)
  if (idx) try { openEpoch(input.session_id); } catch {}
  // 06, 8l: a session the SDK started (claude -p, sdk-ts, sdk-py) has no person to tell, so Claude is not told a dream
  // is due there
  const person = !String(process.env.CLAUDE_CODE_ENTRYPOINT ?? '').startsWith('sdk-');
  let due = false;
  if (idx !== null && ['startup', 'clear'].includes(input.source)) {
    try { const w = waiting(root); if (w) notes.push(w); } catch {}
    const data = process.env.CLAUDE_PLUGIN_DATA;
    if (data) {
      let held = '';
      try { held = dreamLeft(root, data); } catch {}
      // the review of 8l: not while a dream holds the lock
      // AU-3 (06, 9): nor while the last dream's log line waits for its commit, which the due line then names
      try { const d = dreamDue(root, data, input.transcript_path); if (d) { notes.push(d); due = person && !held && d.startsWith('second-brain: a dream is due'); } } catch {}
      if (held) notes.push(held);
      // Q-15 (06, 8m): what a dream's finish or abort put back, told to the person once; a headless session leaves it
      if (person) try { const f = path.join(stateDir(root, data), 'undone.txt'); const u = fs.readFileSync(f, 'utf8').trim(); fs.rmSync(f); if (u) notes.push(u); } catch {}
    }
  }
  // Q-8 (06, 8k): with no index, outside git or where git cannot run, Claude gets nothing (it got 2,215 bytes); in a
  // repo, index() has told the person why
  emit('SessionStart', idx === null ? '' : startText(idx, due).text, notes.length ? notes.join('\n') : undefined);
} else if (which === 'prompt') {
  // the hook also fires on a background subagent's report and another session's message: the force waits for a typed
  // prompt (06, 2i). shortcut: matched on the wrappers transcripts record; another form spends the force as before
  if (!/^\s*(Another Claude session sent a message:|<(task-notification|cross-session-message|agent-message)[\s>])/.test(input.prompt ?? '')) emit('UserPromptSubmit', takeForce(input.session_id));
} else if (which === 'read') {
  // Q-12 (06, 8k): the root by its real path too, as 8g spells it (macOS /var, a Windows 8.3 name); by strings only,
  // since the path is the model's and a file-system call on it can reach another host (X-2)
  const at = (r) => rel(r, input.tool_input?.file_path);
  let file = at(root);
  if (!file.startsWith(`${MAP}/`)) try { file = at(fs.realpathSync.native(root)); } catch {}
  if (file.startsWith(`${MAP}/`) && file.endsWith('.md')) emit('PostToolUse', labelled(file));
} else if ((which === 'bash' || which === 'bash-failure') && String((input.tool_name === 'Grep' ? [input.tool_input?.path, input.tool_input?.glob].join(' ') : input.tool_input?.command) ?? '').toLowerCase().replace(/\\\r?\n/g, '').replace(/["'`\\]/g, '').includes(MAP)) {
  // a Bash command that names the map folder gets every uncommitted entry's labels, and those of the committed entries
  // its output shows (D14, 06 2o): the output is every string in tool_response (stdout, stderr), or the failure's
  // error text. shortcut: a command that does not name the map folder gets nothing, so `git diff` from the root stays
  // unlabelled (04's accepted risk). The if field spares the process; the check above holds when Claude Code lets
  // through a command that does not name it, as it did with some compound ones (8h). H1 (06, 8a; settles C-10 in 8k):
  // it names the map after letter case, quotes, backslashes and backslash-newlines are set aside, so the check is
  // never narrower than the if field's match
  // 8o: PowerShell as Bash; a Grep names the map by path or glob (no if: Claude Code matches Grep(...) on the pattern)
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
  try { files = under(root, MAP, new Set([fs.realpathSync(path.join(root, MAP))])).filter((f) => f.endsWith('.md')).sort(); } catch (e) { files = e.code === 'ENOENT' && !fs.existsSync(path.join(root, MAP)) ? [] : null; }
  // a listed file that cannot be read fails closed too: labels() reads ENOENT as "no file", and a name that is not
  // valid UTF-8 is listed with U+FFFD, which no read finds (2o attempt 3). A name listed twice (two names decoded
  // alike) cannot tell which file a read reaches, so it fails closed (attempt 4)
  const twice = new Set((files ?? []).filter((f, i) => i && files[i - 1] === f));
  if (files) files = [...new Set(files)];
  // every file's HEAD text in one git call (AU-7, 06, 9); should it fail, each file reads its own
  let heads;
  try { if (files?.length) heads = headTexts(root, files); } catch {}
  const walked = (f) => { if (twice.has(f)) return closed(f); const t = labelled(f, output, heads); return t || fs.existsSync(path.join(root, f)) ? t : closed(f); };
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
} else if (which === 'setup') {
  // 06, section 3, S5 (D29): the templates sit beside scripts/, in the plugin this file runs from
  console.log(setup(root, path.resolve(path.dirname(process.argv[1]), '..')));
} else if (which === 'onboard') {
  const gitVersion = git(root, '--version').stdout?.trim();
  // AU-12 (06, 9): why git cannot list the repo, as session start says it
  const why = [];
  const idx = index(root, why);
  const fit = startText(idx);
  const mapDir = path.join(root, MAP);
  const mapFiles = fs.existsSync(mapDir) ? fs.readdirSync(mapDir).filter((f) => f.endsWith('.md')) : [];
  // 06, 2q: a map file HEAD lacks keeps its entries labelled unreviewed until it is committed
  // with no git that runs, what is committed cannot be told, so it is not said (AU-12)
  const tracked = idx === null ? null : git(root, 'ls-tree', '-r', '--name-only', '-z', 'HEAD', '--', MAP).stdout?.split('\0') ?? [];
  const loose = tracked ? mapFiles.filter((f) => !tracked.includes(`${MAP}/${f}`)).length : 0;
  console.log([
    `Node ${process.version}${Number(process.versions.node.split('.')[0]) < 20 ? ': the project map needs Node 20 or later' : ''}`,
    gitVersion ?? 'git not found: the project map needs git',
    idx === null ? (why.length ? why.join(' ').replace(/^second-brain: the/, 'The').replace(/this session has no map/, 'the index is empty here') : 'Not a git repository: the index lists the files git tracks, so it is empty here.')
      : `Index: ${fit.total ? idx.split('\n').slice(1, -1).reduce((n, l) => n + l.replace(/, \d+ (?:due|proposed)\b/g, '').split(', ').length, 0) : 0} documents in ${fit.total} directories, ${Buffer.byteLength(idx)} bytes at session start.`,
    ...(fit.listed < fit.total ? [`Warning: session start is past the 10,000-character limit of one hook output, so it lists ${fit.listed} of the index's ${fit.total} directories.`] : []),
    `Map: ${mapFiles.length} file(s) in ${MAP}/${loose ? `; ${loose} not committed, so their entries stay labelled "unreviewed" until they are` : ''}.`,
  ].join('\n'));
}
