// 06, section 3, S7 (V2-D31, D32): the dream's deterministic steps. No model and no network; spawns only git. Run as a
// command by /second-brain:dream, never by a hook, so no hook pays to load it:
//   node dream.mjs <prepare|finish|abort> <the plugin's data folder>
//   prepare: lock, snapshot, find this repo's sessions, write tagged digests into the run folder.
//   finish:  validate the staged proposals, apply them (map entries proposed, rule and skill drafts inert), log, state.
//   abort:   put the snapshot back and release the lock.
// The run folder inside the repo holds only the digests and the staged proposals (P2: temp-folder access prompts) and
// ignores itself. The snapshot and the run record, which names session ids, live in the plugin's data folder.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { spawnSync } from 'node:child_process';
import { MAP, entries, foundIn, stateDir, loadState, knownDirs, localDate, toplevel, decode, dreamDate, reviewStep, git, exe, quoteOf, idsIn, utf16, inRepo, words, configDir, readMapFile, lastDream } from './map.mjs';
import { FILES } from './setup.mjs';

const RUN = `${MAP}/.dream-run`;
const MAX_SESSIONS = 30;
const MAX_BYTES = 5 << 20;
// 8d (D35): the files that make a folder a package, for placing a path rule in a monorepo
const PKG = ['package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'pom.xml', 'build.gradle'];
const STALE_LOCK_MS = 2 * 3600e3;
const enc = (p) => p.replace(/[^A-Za-z0-9]/g, '-');
const real = (p) => fs.realpathSync.native(p);
// D-1 (06, 8a): Claude Code loads a folder's CLAUDE.md, CLAUDE.local.md or AGENTS.md as instructions when Claude reads a
// file there, so a proposal never makes one in the map folder
export const topic = (f) => f.endsWith('.md') && !['readme.md', 'dreams.md', 'steering.md', 'claude.md', 'claude.local.md', 'agents.md'].includes(f.toLowerCase());
const stamp = () => new Date().toISOString().replace(/[:.]/g, '-');
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };

// ---------- the watched set: the map, and what Claude Code loads as instructions (06, S7 amendments) ----------
// no folder on the way from the repo's root to p (p itself not counted) is a link. A link there could aim a scan, a
// write or a delete anywhere: outside the repo, or at its .git/hooks (agy's release round). Such a path is never
// watched, written or removed; a link that was there before the dream is kept, and not followed
const plain = (root, p) => {
  const rel = path.relative(root, p);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return false;
  let q = root;
  for (const s of rel.split(path.sep).slice(0, -1)) {
    q = path.join(q, s);
    const st = lstat(q);
    if (!st) return true;
    // a file where a folder is due: nothing can be written there (Audit 3, 06, 8m review)
    if (st.isSymbolicLink() || !st.isDirectory()) return false;
  }
  return true;
};
// what a folder holds, if it and every folder above it are plain: its regular files, and its links, never followed, so
// a restore never removes or writes a file through one
const scan = (root, d) => {
  const files = [];
  const links = [];
  const top = path.join(root, d);
  if (!lstat(top)?.isDirectory() || !plain(root, top) || !inRepo(root, top)) return { files, links };
  const walk = (rel) => { let es = []; try { es = fs.readdirSync(path.join(root, rel), { withFileTypes: true }); } catch { return; } for (const e of es) { const p = `${rel}/${e.name}`; if (p === RUN) continue; if (e.isSymbolicLink()) links.push(p); else if (e.isDirectory()) walk(p); else if (e.isFile()) files.push(p); } };
  walk(d);
  return { files, links };
};
// what Claude Code loads as instructions or tools from the project; settings files are only reported (SETTINGS), since
// an "always allow" the user gives during the dream lands there and must stand
// AU-20 (06, 9): and the hook scripts the settings name, which run with the person's rights
const DIRS = ['.claude/rules', '.claude/skills', '.claude/agents', '.claude/commands', '.claude/output-styles', '.claude/hooks'];
const TOP = ['CLAUDE.md', 'CLAUDE.local.md', '.claude/CLAUDE.md', '.mcp.json'];
const SETTINGS = ['.claude/settings.json', '.claude/settings.local.json'];
const lstat = (p) => { try { return fs.lstatSync(p); } catch { return null; } };
const sha = (p) => { try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } catch { return null; } };
const settingsNow = (root) => Object.fromEntries(SETTINGS.map((f) => [f, sha(path.join(root, f))]));
const mapFiles = (root) => scan(root, MAP).files.filter((p) => p.endsWith('.md')).sort();
// shortcut: copies every file under those folders; a repo with large skill assets pays for the copy, add a size cap if one does
const watched = (root) => [...new Set([...mapFiles(root), ...DIRS.flatMap((d) => scan(root, d).files), ...TOP.filter((f) => plain(root, path.join(root, f)) && lstat(path.join(root, f))?.isFile())])].sort();
// the links in the same places, with where each points: Claude Code follows a linked rule or skill, so a link that
// appears or changes during the dream is removed. The watched folders themselves count too: a .claude/rules made a
// link to a folder of rules elsewhere would load them (the devils-advocate review)
const FOLDERS = [MAP, '.claude', ...DIRS];
const linkAt = (root, f) => plain(root, path.join(root, f)) && lstat(path.join(root, f))?.isSymbolicLink();
const links = (root) => Object.fromEntries([...FOLDERS.filter((f) => linkAt(root, f)), ...scan(root, MAP).links, ...DIRS.flatMap((d) => scan(root, d).links), ...TOP.filter((f) => linkAt(root, f))]
  .map((f) => [f, (() => { try { return fs.readlinkSync(path.join(root, f)); } catch { return ''; } })()]));
// a path the dream watches: a map file outside the run folder, a file under a watched folder, or a top file. Every
// segment is a plain name (no "", ".", ".." or backslash), so a forged run record cannot aim the restore at settings,
// the run folder or git hooks (agy's release round)
const watchable = (f) => typeof f === 'string' && !f.includes('\\') && !f.split('/').some((s) => !s || s === '.' || s === '..')
  && ((f.startsWith(`${MAP}/`) && f.endsWith('.md') && !f.startsWith(`${RUN}/`)) || DIRS.some((d) => f.startsWith(`${d}/`)) || TOP.includes(f));
// a write target: plain, not a link itself, and its nearest existing folder inside the repo
const inside = (root, p) => plain(root, p) && !lstat(p)?.isSymbolicLink() && inRepo(root, path.dirname(p));
// puts the watched set back to the snapshot. Each file it replaces or removes is copied to undone/ first, so nothing
// is destroyed: another session may have captured an entry during the dream
function restore(root, dir, runDir, list, before, dirs) {
  const snap = path.join(runDir, 'snapshot');
  const keep = new Set(list);
  const undone = path.join(dir, 'undone', stamp());
  const changed = [];
  const save = (f) => { const to = path.join(undone, f); fs.mkdirSync(path.dirname(to), { recursive: true }); fs.cpSync(path.join(root, f), to, { recursive: true }); };
  for (const [f, to] of Object.entries(links(root))) {
    if (before[f] === to) continue;
    fs.mkdirSync(path.dirname(path.join(undone, f)), { recursive: true });
    fs.writeFileSync(path.join(undone, `${f}.link`), `${to}\n`);
    fs.rmSync(path.join(root, f), { force: true });
    changed.push(`removed the link ${f}`);
  }
  // AU-20 (06, 9): a record from before 2.6.1 watched no hook script, so none is removed for it
  const theirs = (f) => !f.startsWith('.claude/hooks/') || (dirs ?? []).includes('.claude/hooks');
  for (const f of watched(root)) if (!keep.has(f) && theirs(f) && plain(root, path.join(root, f))) { save(f); fs.rmSync(path.join(root, f), { force: true }); changed.push(`removed ${f}`); }
  for (const f of list) {
    const p = path.join(root, f);
    // a link on its path, or a folder that leads outside the repo: nothing there is touched
    if (!plain(root, p) || !inRepo(root, path.dirname(p))) { changed.push(`not restored ${f} (a link is on its path)`); continue; }
    const bytes = fs.readFileSync(path.join(snap, f));
    let link = false, now = null;
    try { link = fs.lstatSync(p).isSymbolicLink(); if (!link) now = fs.readFileSync(p); } catch {}
    if (now?.equals(bytes)) continue;
    // what is in its place is saved first (a folder too); a link goes, not what it points to
    if (!link && fs.existsSync(p)) save(f);
    fs.rmSync(p, { force: true, recursive: true });
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, bytes);
    changed.push(`restored ${f}`);
  }
  return { changed, undone: fs.existsSync(undone) ? undone : null };
}
// Q-15 (06, 8m): what finish or abort put back is also kept for the next session start to tell once (its reading is
// 8l's), in undone.txt in the repo's state folder: the session that made an edit is not the dream's
const tell = (dir, s) => { if (s) fs.appendFileSync(path.join(dir, 'undone.txt'), `${s}\n`); return s; };
// the run record: the root it was prepared in (linked worktrees share the state folder), the watched set, the manifest
function record(root, dir, step) {
  const runDir = path.join(dir, 'run');
  const job = readJson(path.join(runDir, 'run.json'), null);
  if (!job) return { runDir, job: null, whole: false };
  if (job.root !== real(root)) throw new Error(`this dream was prepared in another worktree of this repo: run ${step} there`);
  const forged = !Array.isArray(job.watched) || !job.watched.every(watchable) || Object.keys(job.links ?? {}).some((f) => !FOLDERS.includes(f) && !watchable(f));
  const whole = !forged && fs.existsSync(path.join(runDir, 'snapshot')) && job.watched.every((f) => lstat(path.join(runDir, 'snapshot', f))?.isFile());
  return { runDir, job, whole, forged };
}
// AU-10 (06, 9): the run the skill names (prepare printed its id) is the one the record holds. With no id given (a
// skill from before 2.6.1, or a person's own command), or a record from before 2.6.1, there is nothing to compare
// (null: finish run as a command with no id, which refuses a run that has one)
function ours(job, id) {
  if (!job?.id || id === undefined || job.id === id) return;
  if (id === null) throw new Error('finish needs the run id that prepare printed ("Run id: <id>"): run it as the dream skill says');
  throw new Error('this is not the run that was prepared for this dream: a newer dream took its lock over, so nothing of this one is applied, and the newer dream finishes on its own');
}
// the data folder the command is given: Claude Code's plugin data root, never inside the repo. The skill's grant
// allows the command with any arguments, so a session could otherwise point it at a run record it wrote itself (the
// devils-advocate review)
// The test is on real paths: the folder's nearest existing ancestor, through any link, lies under Claude Code's own
// plugins/data, not inside the repo (agy's release round: a link named plugins/data passed a test on the name)
const dataOk = (root, data) => inRepo(path.join(configDir(), 'plugins', 'data'), data) && !inRepo(root, data);

// ---------- the lock: it names the root that holds it; its age is its file's mtime (a reader between create and
// write would see no time in it). Past two hours it is taken over without a restore (S7: a restore days after a crash
// would revert what was captured since). shortcut: a dream still running after two hours loses its run to the next one
// (/code-review of 2.3.0); refresh the lock during a run if dreams ever take that long ----------
function lock(dir, root) {
  const f = path.join(dir, 'dream.lock');
  fs.mkdirSync(dir, { recursive: true });
  try { fs.writeFileSync(f, real(root), { flag: 'wx' }); return; } catch (e) { if (e.code !== 'EEXIST') throw e; }
  if (Date.now() - fs.statSync(f).mtimeMs < STALE_LOCK_MS) throw new Error('another dream is running in this repo (or one stopped less than two hours ago: run abort)');
  // D-4 (06, 8a): the stale lock is taken by renaming it away, which only one prepare can do; when what it renamed is
  // fresh (another prepare took the lock in between), it goes back and this one refuses
  const away = `${f}.${process.pid}.${Date.now()}`;
  try { fs.renameSync(f, away); } catch { throw new Error('another dream is running in this repo'); }
  if (Date.now() - fs.statSync(away).mtimeMs < STALE_LOCK_MS) { try { fs.renameSync(away, f); } catch {} throw new Error('another dream is running in this repo'); }
  fs.rmSync(away, { force: true });
  try { fs.writeFileSync(f, real(root), { flag: 'wx' }); } catch { throw new Error('another dream is running in this repo'); }
}
const unlock = (dir) => fs.rmSync(path.join(dir, 'dream.lock'), { force: true });

// ---------- the transcripts ----------
const parse = (l) => { try { return JSON.parse(l); } catch { return null; } };
const one = (s, n) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
const textOf = (c) => (typeof c === 'string' ? c : Array.isArray(c) ? c.map((x) => x.text ?? (typeof x.content === 'string' ? x.content : '')).join(' ') : '');
// Q-16 (06, 8m): a U or Q line cut short says so, so no one reads its start as the whole; finish strips the mark (CUT)
// only at the end of a part, where prepare puts it: a typed one mid-line would splice the words around it
const CUT = / …\[cut at \d+ of \d+ characters\]$/;
// L-8 (06, 8m): a line sent through claude -p, perhaps by another program, is not shown to be the person's
const SDK = "[sdk-cli: not shown to be the person's] ";
const whole = (s, n) => { const t = one(s, Infinity); return t.length > n ? `${t.slice(0, n)} …[cut at ${n} of ${t.length} characters]` : t; };
// Q-7 (06, 8m): Claude Code's own wrappers (a slash command, a local command's output, a reminder, a task's notice)
const WRAPPER = /^<(command-(name|message|args)|local-command-[a-z]+|system-reminder|task-notification|persisted-output|bash-(input|stdout|stderr))>/;
// one transcript record as digest lines (U, Q, A, T, R); everything else (attachments, hook context, loaded rules,
// API records, meta records) is dropped, so a rule the dream wrote cannot look common because it was loaded. A Q line
// needs the tool call it answers to be AskUserQuestion (names: tool_use ids to tool names, from the session so far),
// so another tool's output shaped like answers stays an R line. `rel` makes the repo's paths relative before a tool
// line is cut (06, 8m)
export function tag(r, names = new Map(), rel = (s) => s) {
  if (!r || typeof r !== 'object') return [];
  const sdk = r.entrypoint === 'sdk-cli' ? SDK : '';
  if (r.type === 'user' && !r.isMeta && !r.isSidechain) {
    const c = r.message?.content;
    // Q-7: a prompt with an image keeps its text parts
    if (typeof c === 'string' || (Array.isArray(c) && c.some((x) => x?.type === 'text') && c.every((x) => x?.type === 'text' || x?.type === 'image'))) {
      const t = textOf(c);
      const typed = ['sdk', 'typed'].includes(r.promptSource) || r.origin?.kind === 'human';
      return typed && !WRAPPER.test(t.trimStart()) ? [`U: ${sdk}${whole(t, 4000)}`] : [];
    }
    if (!Array.isArray(c)) return [];
    return c.filter((x) => x?.type === 'tool_result').flatMap((x) => {
      const a = r.toolUseResult?.answers;
      if (names.get(x.tool_use_id) === 'AskUserQuestion' && a && typeof a === 'object' && !Array.isArray(a)) return Object.entries(a).map(([q, v]) => `Q: ${sdk}${whole(q, 300)} = ${whole(v, 300)}`);
      // 8c (D35): a failed result is marked, so a dream can see what went wrong
      return [`R${x.is_error ? '!' : ''}: ${one(textOf(x.content) || x.content, 300)}`];
    });
  }
  if (r.type === 'assistant' && !r.isSidechain) {
    return (r.message?.content ?? []).flatMap((x) => {
      if (x?.type === 'text') return [`A: ${one(x.text, 600)}`];
      // 8c (D35): a skill's name and an agent's type come first, so the input's 80-character cut never drops them
      if (x?.type === 'tool_use') { const k = used(x)?.name; return [`T: ${x.name}${k ? ` ${one(k, 80)}` : ''} ${one(rel(JSON.stringify(x.input) ?? ''), 80)}`]; }
      return [];
    });
  }
  return [];
}
// K1 (06, section 4, 4g): the map files a tool call read, by Read or by a Bash command naming them, the two routes the
// read hooks label. shortcut: the path is not anchored to this repo, so another repo's map file of the same name counts;
// anchor it if sessions here read other repos' maps
const MAP_FILE = /\.project-map[\\/]([\w.-]+\.md)\b/g;
export const mapReads = (x) => [...String((x.name === 'Read' ? x.input?.file_path : x.name === 'Bash' ? x.input?.command : '') ?? '').matchAll(MAP_FILE)].map((m) => m[1]);
// 8c (D35): a tool call that uses a skill or an agent, as { kind, name } (an older Skill call names it as command)
const used = (x) => { const s = x?.name === 'Skill' && (x.input?.skill ?? x.input?.command); return s ? { kind: 'skill', name: String(s) }
  : /^(Agent|Task)$/.test(x?.name) && x.input?.subagent_type ? { kind: 'agent', name: String(x.input.subagent_type) } : null; };
// a session's lines from a byte offset, streamed, so a large transcript is never read whole. accept(cwd) sees the
// first cwd; the stream stops there when it says no. 8c (D35): also its uses of skills and agents, each marked when a
// typed line follows it before the next use, and its failed tool results by tool. A typed /<name> is a use only when
// `skills` holds the name or it is a plugin's (plugin:skill); a built-in such as /compact is neither a use nor an end.
// D-6 (06, 8a): read only up to `end`, the size prepare recorded, so what a session adds meanwhile is the next dream's.
// Q-6 (06, 8m): a dream's own turns, from its start (the typed command, or Claude's Skill call) to the result of its
// finish or abort, to prepare's refusal, or to the end of what is read, are not read
export async function digestFrom(file, start, accept, skills = new Set(), end = Infinity, rel) {
  const lines = [];
  const names = new Map();
  const reads = new Set();
  const uses = [], fails = {};
  let open = [];
  let first = null, last = null, cwd = null, inDream = false, endId = null, shown = null;
  const input = fs.createReadStream(file, { start, ...(end !== Infinity && { end: end - 1 }), encoding: 'utf8' });
  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  // Claude's Skill or Agent call ends the uses still open; a person's typed /<name> is added beside them
  const use = (u, ends) => { const e = { ...u, after: false }; open = ends ? [e] : [...open, e]; uses.push(e); };
  const agentCalls = new Set();
  // 8d (D35): the files the session's own Read, Edit and Write calls named, as given (prepare keeps those in the repo)
  const touched = new Set();
  // 8f (K1's second signal): the lines of the tool calls that read a map file, and which files, so the trim keeps them
  // and finish can tell a correction that came after a read
  const mapAt = [];
  for await (const l of rl) {
    const r = parse(l);
    if (!r) continue;
    if (cwd === null && typeof r.cwd === 'string') { cwd = r.cwd; if (!accept(cwd)) break; }
    const content = Array.isArray(r.message?.content) ? r.message.content : [];
    const calls = r.type === 'assistant' ? content.filter((x) => x?.type === 'tool_use') : [];
    // Claude Code records a slash command as a command-name record, not as a typed prompt (/code-review's finding)
    const cmd = r.type === 'user' && typeof r.message?.content === 'string' ? /<command-name>\/([^<\s]+)<\/command-name>/.exec(r.message.content)?.[1] : null;
    let t = tag(r, names, rel);
    // the skill's text with prepare's output in it; the read of the session that runs a dream begins at or before it
    const meta = r.type === 'user' && r.isMeta ? textOf(r.message?.content) : '';
    if (cmd === 'second-brain:dream' || calls.some((x) => used(x)?.name === 'second-brain:dream') || t.some((l) => /^U: (\[sdk-cli[^\]]*\] )?\/second-brain:dream(\s|$)/.test(l)) || /^Dream prepared: /m.test(meta)) { inDream = true; endId = null; continue; }
    if (inDream) {
      // its finish or abort (after a cd, or from a folder with a space), or prepare's refusal, ends it; one outside a
      // dream is only read
      const fin = calls.find((x) => x.name === 'Bash' && /\bnode\b.*dream\.mjs["']?\s+(finish|abort)\b/.test(x.input?.command ?? ''));
      if (fin) endId = fin.id;
      else if (endId ? r.type === 'user' && content.some((x) => x?.type === 'tool_result' && x.tool_use_id === endId) : /^The dream stopped: /m.test(meta)) inDream = false;
      continue;
    }
    if (r.timestamp) { first ??= r.timestamp; last = r.timestamp; }
    // the review of 8l: a skill the person starts by typing /<name> gets the line a Skill call gets, so a correction after
    // it can name it (the wrapper and the skill's text are otherwise dropped)
    if (cmd && (skills.has(cmd) || cmd.includes(':')) && !t.length) t = [`T: Skill ${one(cmd, 80)}`];
    // R-d (06, 8l): a D line where the date changes, so evidence carries its date (the first is prepare's report's)
    const day = t.length && typeof r.timestamp === 'string' ? r.timestamp.slice(0, 10) : null;
    if (day) { if (day !== (shown ?? String(first).slice(0, 10))) lines.push(`D: ${day}`); shown = day; }
    // each reading call's own line: tag() gives an assistant record one line per text and per tool call, in order
    const at = lines.length;
    let off = 0;
    if (r.type === 'assistant') for (const x of content) {
      if (x?.type === 'text') { off++; continue; }
      if (x?.type !== 'tool_use') continue;
      names.set(x.id, x.name);
      const read = mapReads(x);
      for (const f of read) reads.add(f);
      if (read.length && !r.isSidechain) mapAt.push({ idx: at + off, files: read });
      off++;
      const u = !r.isSidechain && used(x);
      if (u) { use({ ...u, via: 'call' }, true); if (u.kind === 'agent') agentCalls.add(x.id); }
      const fp = x.input?.file_path ?? x.input?.notebook_path;
      if (!r.isSidechain && /^(Read|Edit|Write|MultiEdit|NotebookEdit)$/.test(x.name) && typeof fp === 'string') touched.add(fp);
    }
    if (cmd && (skills.has(cmd) || cmd.includes(':'))) use({ kind: 'skill', name: cmd, via: 'typed' }, false);
    if (r.type === 'user' && !r.isSidechain) for (const x of content) if (x?.type === 'tool_result' && x.is_error) { const t = names.get(x.tool_use_id) ?? 'unknown'; fails[t] = (fails[t] ?? 0) + 1; }
    if (t.some((x) => x.startsWith('U: '))) { for (const u of open) u.after = true; open = []; }
    lines.push(...t);
  }
  input.destroy();
  return { lines, first, last, cwd, reads, uses, fails, agentCalls, touched, mapAt };
}

// 8f: a digest keeps every U, Q and A line; every line 8c added for D35, a skill's or an agent's call and a failed
// result (the decision-checker's finding: the trim dropped them); the 4 tool lines (T or R) before each U or Q line; and
// each tool line that reads a map file. Each other run of tool lines becomes one "…: <n> tool lines" line. On this
// repo's sessions, 97 of 13,793 digest lines were U or Q lines. `at` maps a line's index to its number in the trimmed
// digest
export function trim(lines, keepAt = new Set()) {
  const tool = (l) => /^(T|R!?): /.test(l);
  const keep = lines.map((l, i) => !tool(l) || keepAt.has(i) || /^(T: (Skill|Agent|Task) |R!: )/.test(l));
  lines.forEach((l, i) => {
    if (!/^(U|Q): /.test(l)) return;
    for (let k = i - 1, n = 0; k >= 0 && n < 4; k--) if (tool(lines[k])) { keep[k] = true; n++; }
  });
  const out = [];
  const at = new Map();
  let gap = 0;
  lines.forEach((l, i) => {
    if (!keep[i]) { gap++; return; }
    if (gap) { out.push(`…: ${gap} tool lines`); gap = 0; }
    out.push(l);
    at.set(i, out.length);
  });
  if (gap) out.push(`…: ${gap} tool lines`);
  return { out, at };
}
// 8c (D35): a session's subagent runs by type, from Claude Code's meta files beside its transcript, and the failed tool
// results in each run's own transcript, counted only (no subagent text enters a digest). A run counts when its
// toolUseId names an Agent call in the part of the session this dream read, or when the run that started it counts; so
// runs follow the session's read offset, and go back with it when a dream is discarded. A run with no agentType is
// "unknown"; one that names no call (Claude Code 2.1.331 records one in nearly every meta file) is not counted
async function subagentRuns(transcript, calls) {
  const d = path.join(transcript.replace(/\.jsonl$/, ''), 'subagents');
  const runs = [];
  let files = [];
  try { files = fs.readdirSync(d).filter((f) => f.endsWith('.meta.json')).sort(); } catch { return runs; }
  const meta = new Map(files.map((f) => { try { return [f.slice(0, -'.meta.json'.length).replace(/^agent-/, ''), JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')) ?? {}]; } catch { return [f, {}]; } }));
  const counted = new Set();
  for (let grew = true; grew;) {
    grew = false;
    for (const [id, m] of meta) if (!counted.has(id) && ((typeof m.toolUseId === 'string' && calls.has(m.toolUseId)) || counted.has(m.parentAgentId))) { counted.add(id); grew = true; }
  }
  for (const id of [...counted].sort()) {
    const m = meta.get(id);
    const type = typeof m.agentType === 'string' && m.agentType ? m.agentType : 'unknown';
    const p = path.join(d, `agent-${id}.meta.json`);
    let failed = 0;
    try {
      const rl = readline.createInterface({ input: fs.createReadStream(p.replace(/\.meta\.json$/, '.jsonl'), 'utf8'), crlfDelay: Infinity });
      for await (const l of rl) { const r = parse(l); if (r?.type === 'user' && Array.isArray(r.message?.content)) failed += r.message.content.filter((x) => x?.type === 'tool_result' && x.is_error).length; }
    } catch {}
    runs.push({ meta: p, type, failed });
  }
  return runs;
}
// 06, 8k: the offset just past a session's last newline at or before `size`, never below `from`, so a record still
// being written when prepare looks is read whole by the next dream. Read back from `size` a window at a time
function lineEnd(p, from, size) {
  if (size <= from) return from;
  const fd = fs.openSync(p, 'r');
  try {
    const b = Buffer.alloc(64 << 10);
    for (let at = size; at > from;) {
      const k = Math.min(b.length, at - from);
      at -= k;
      const nl = b.subarray(0, fs.readSync(fd, b, 0, k, at)).lastIndexOf(10);
      if (nl >= 0) return at + nl + 1;
    }
    return from;
  } finally { fs.closeSync(fd); }
}
// the root and its worktrees, by real path; a worktree whose folder was deleted but never pruned is still listed by git
const worktrees = (root) => [root, ...git(root, 'worktree', 'list', '--porcelain').stdout.split('\n').filter((l) => l.startsWith('worktree ')).map((l) => l.slice(9))]
  .map((r) => { try { return real(r); } catch { return path.resolve(r); } });
// this repo's transcript folders: the ones session start learned, plus the folders of the root and its worktrees
function folders(dir, rootsReal) {
  const projects = path.join(configDir(), 'projects');
  const prefixes = [...new Set(rootsReal.map(enc))];
  let names = [];
  try { names = fs.readdirSync(projects); } catch {}
  const found = names.filter((n) => prefixes.some((p) => n === p || n.startsWith(`${p}-`))).map((n) => path.join(projects, n));
  return [...new Set([...knownDirs(dir), ...found])].filter((d) => fs.existsSync(d));
}
export async function prepare(root, data) {
  const dir = stateDir(root, data);
  if (!inRepo(root, path.join(root, MAP))) throw new Error(`${MAP}/ is a link that leads outside the repo: the dream writes nothing through it`);
  // AU-13 (06, 9): and finish's own test, so a dream finish would refuse never starts
  if (!inside(root, path.join(root, MAP, 'dreams.md'))) throw new Error(`${MAP}/ or its log is a link: the dream writes nothing through it`);
  lock(dir, root);
  try {
    const st = loadState(dir);
    // the last dream (map.mjs, lastDream): kept, it stays; discarded when its line is gone, and then its sessions go
    // back to this one; still waiting for review while the line is only in the working tree, and then no new dream
    // starts, so two unreviewed dreams never stack
    if (st.pending) {
      const { at, here, kept, waits } = lastDream(root, st);
      if (waits) {
        throw new Error(`the last dream is still waiting for review${at === here ? '' : ` in the worktree ${at}`}: accept or reject its proposals and commit them with ${MAP}/dreams.md, or discard them, then dream again. ${reviewStep(root)}`);
      }
      // discarded: its sessions and its date go back, so the next log line and the nudge count from the dream before
      if (!kept) { st.seen = st.pending.prevSeen; st.lastDream = st.pending.prevLastDream ?? null; st.lastDreamDate = st.pending.prevLastDreamDate ?? null; }
      st.pending = null;
      fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify(st, null, 1));
    }
    // K-1: the repo's run folder emptied, its .gitignore last; one a program holds stops the dream before anything moves
    const run = path.join(root, RUN);
    if (!clearRun(run)) throw new Error(STUCK);
    // a run left by a dream that did not finish (its lock went stale): moved aside, not restored, since a restore days
    // later would revert what was captured and committed since; the report names what differs from its snapshot
    const runDir = path.join(dir, 'run');
    let leftover = '';
    const old = readJson(path.join(runDir, 'run.json'), null);
    if (old) {
      const to = path.join(dir, 'undone', `${stamp()}-stale`);
      const snap = path.join(runDir, 'snapshot');
      const here = old.root === real(root);
      const differ = here
        ? [...new Set([...watched(root), ...old.watched])].filter((f) => { try { return !fs.readFileSync(path.join(root, f)).equals(fs.readFileSync(path.join(snap, f))); } catch { return true; } })
        : [];
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.renameSync(runDir, to);
      leftover = here
        ? `A dream of ${old.date} did not finish. ${differ.length ? `These files differ from its snapshot; check them with git diff: ${differ.join(', ')}.` : 'Nothing here differs from its snapshot.'} Its snapshot is saved in ${to}.`
        : `A dream of ${old.date} in the worktree ${old.root} did not finish; check that worktree with git diff. Its snapshot is saved in ${to}.`;
    }
    fs.rmSync(runDir, { recursive: true, force: true });
    fs.mkdirSync(path.join(run, 'digests'), { recursive: true });
    fs.mkdirSync(path.join(run, 'proposals'), { recursive: true });
    fs.writeFileSync(path.join(run, '.gitignore'), '*\n');
    // the snapshot that finish and abort put back, and the links already there
    const list = watched(root);
    const linked = links(root);
    const snap = path.join(runDir, 'snapshot');
    fs.mkdirSync(snap, { recursive: true });
    for (const f of list) { fs.mkdirSync(path.dirname(path.join(snap, f)), { recursive: true }); fs.copyFileSync(path.join(root, f), path.join(snap, f)); }
    const rootsReal = worktrees(root);
    // whose session: the repo of its cwd, or of the nearest folder above it that still exists. A session of another
    // repo is foreign. One whose folder is gone and whose nearest folder is not ours is ours when it sits in a
    // transcript folder this repo's session start learned (a removed worktree's), and otherwise is marked seen
    // unread, so the due nudge cannot count it for ever (/code-review's finding)
    const known = new Set(knownDirs(dir));
    const owners = new Map();
    // X-2: how sessions spell their folders: each recorded folder (Claude Code writes it, not the model) beside its real
    // path, both cut back to where their names part (a link or a short name)
    const spellings = [];
    const owner = (cwd) => {
      if (!owners.has(cwd)) {
        let q = path.resolve(cwd);
        while (!fs.existsSync(q) && path.dirname(q) !== q) q = path.dirname(q);
        let o = null;
        try { o = real(toplevel(q)); } catch {}
        let a = path.resolve(cwd), b = a;
        try { b = path.join(real(q), path.relative(q, a)); } catch {}
        while (path.basename(a) && path.basename(a) === path.basename(b)) { a = path.dirname(a); b = path.dirname(b); }
        // the longest first, as the roots are: a shorter one (a linked temp folder) would map past a link below it
        if (a !== b) { spellings.push([a, b]); spellings.sort((x, y) => y[0].length - x[0].length); }
        owners.set(cwd, { ours: Boolean(o) && rootsReal.includes(o), gone: q !== path.resolve(cwd) });
      }
      const { ours, gone } = owners.get(cwd);
      return ours ? 'ours' : gone ? 'gone' : 'foreign';
    };
    const candidates = [];
    for (const d of folders(dir, rootsReal)) {
      for (const f of fs.readdirSync(d).filter((x) => x.endsWith('.jsonl'))) {
        // Audit 8 (06, 8m): one session file, listed again through another spelling of its folder, is read once
        if (candidates.some((c) => c.f === f)) continue;
        const p = path.join(d, f);
        const from = st.seen[f] ?? 0;
        const size = lineEnd(p, from, fs.statSync(p).size);
        if (size > from) candidates.push({ p, f, d, from, size, mtime: fs.statSync(p).mtimeMs });
      }
    }
    candidates.sort((a, b) => a.mtime - b.mtime);
    const manifest = [];
    let bytes = 0;
    const left = [];
    // 8c (D35): what the read sessions did with skills and agents, and their subagent runs; keyed by names from
    // transcripts, so the counters have no prototype (a skill named "constructor" or "__proto__" is only a name)
    const bag = () => Object.create(null);
    const usage = { sessions: 0, skill: bag(), agent: bag(), failed: bag(), subagents: bag(), digests: bag() };
    // 8g: a session may spell its folder through a link or a short name (macOS /var, a Windows 8.3 name) while the
    // worktree roots are real paths, so a file is mapped through the sessions' spellings to its real path. X-2: by
    // strings only, since the name is the model's and a file-system call on it can reach another host (a UNC path)
    const realDir = (a) => { for (const [s, r] of spellings) { const q = path.relative(s, a); if (!q.startsWith('..') && !path.isAbsolute(q)) return path.join(r, q); } return a; };
    // 8d (D35): a file a session named, relative to the root of the worktree that holds it (the longest root first, so a
    // worktree under .claude/worktrees/ is its own; a relative path is taken from the session's folder), or null when
    // no root holds it (the 8d review)
    const roots = [...new Set([path.resolve(root), ...rootsReal])].sort((a, b) => b.length - a.length);
    const inRoot = (p, cwd) => { const a = realDir(path.resolve(cwd ?? root, p)); for (const r of roots) { const q = path.relative(r, a); if (q && !q.startsWith('..') && !path.isAbsolute(q)) return q.split(path.sep).join('/'); } return null; };
    // D-3 (06, 8k): the roots as a digest's text names them, longest first: as given, real, and as the sessions so far
    // spelled them (8g); with \ or /, or with \\ as a tool's JSON input escapes it; ending at a separator or at a
    // character no name holds there, so a sibling folder such as <root>-old is not one
    const SEP = String.raw`(?:\\\\|\\|/)`;
    const rootsIn = () => {
      const all = [...new Set([...roots, ...spellings.flatMap(([s, r]) => roots.filter((x) => `${x}${path.sep}`.startsWith(`${r}${path.sep}`)).map((x) => s + x.slice(r.length)))])];
      // Git Bash spells C:\x as /c/x
      if (process.platform === 'win32') all.push(...all.filter((x) => /^[a-z]:[\\/]/i.test(x)).map((x) => `/${x[0]}${x.slice(2)}`));
      const alt = all.sort((a, b) => b.length - a.length).map((x) => x.split(/[\\/]/).map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join(SEP));
      // a separator ends the root unless .. follows, or a character that ends a path in text does (Gemini, 8k review)
      return new RegExp(`(?:${alt.join('|')})(${SEP}(?!\\.\\.(?:[\\\\/]|$))|(?=[\\s"'\`<>|:;,)\\]}]|$))`, process.platform === 'win32' ? 'gi' : 'g');
    };
    // a file's package: the nearest folder below the root that holds a package manifest; null when none does
    const pkgs = new Map();
    const packageOf = (rel) => {
      for (let d = path.posix.dirname(rel); d && d !== '.'; d = path.posix.dirname(d)) {
        if (!pkgs.has(d)) pkgs.set(d, PKG.some((f) => fs.existsSync(path.join(root, d, f))));
        if (pkgs.get(d)) return d;
      }
      return null;
    };
    // the repo's own skills and agents, each reported even when no session used it
    const own = (d, re) => { try { return fs.readdirSync(path.join(root, '.claude', d), { withFileTypes: true }).flatMap((e) => re(e)); } catch { return []; } };
    usage.ownSkills = own('skills', (e) => (e.isDirectory() && fs.existsSync(path.join(root, '.claude', 'skills', e.name, 'SKILL.md')) ? [e.name] : []));
    usage.ownAgents = own('agents', (e) => (e.isFile() && e.name.endsWith('.md') ? [e.name.slice(0, -3)] : []));
    for (const c of candidates) {
      if (manifest.filter((m) => m.digest).length >= MAX_SESSIONS || bytes >= MAX_BYTES) { left.push(c.f); continue; }
      let kind = 'none', re = null;
      const dg = await digestFrom(c.p, c.from, (cwd) => {
        kind = owner(cwd);
        if (kind === 'gone' && known.has(c.d)) kind = 'ours';
        return kind === 'ours';
      }, new Set(usage.ownSkills), c.size, (s) => s.replace((re ??= rootsIn()), (m, sep) => (sep ? '' : '.')));
      // a session of another repo, whose folder name this repo's prefix also matches: seen, and never read again
      if (kind === 'foreign') { manifest.push({ f: c.f, end: c.size, skipped: 'another repo' }); continue; }
      if (kind === 'gone') { manifest.push({ f: c.f, end: c.size, skipped: 'its folder is gone' }); continue; }
      if (kind === 'none') { manifest.push({ f: c.f, end: c.size, skipped: 'no working folder recorded' }); continue; }
      // 8c (D35): use is counted for every session of this repo the dream reads, before a session with nothing typed is
      // skipped, so a skill a person only starts with /<name> is counted too
      for (const u of dg.uses) { const e = (usage[u.kind][u.name] ??= { uses: 0, sessions: 0, after: 0 }); e.uses++; if (u.after) e.after++; }
      for (const k of new Set(dg.uses.map((u) => `${u.kind}\0${u.name}`))) { const [kind, n] = k.split('\0'); usage[kind][n].sessions++; }
      for (const [t, n] of Object.entries(dg.fails)) usage.failed[t] = (usage.failed[t] ?? 0) + n;
      for (const s of await subagentRuns(c.p, dg.agentCalls)) { const e = (usage.subagents[s.type] ??= { runs: 0, failed: 0 }); e.runs++; e.failed += s.failed; }
      if (!dg.lines.some((l) => /^(U|Q): /.test(l))) { manifest.push({ f: c.f, end: c.size, skipped: 'nothing typed' }); continue; }
      const name = `d${manifest.filter((m) => m.digest).length + 1}.digest`;
      // 8f: the trimmed digest, and each map read's line in it. D-3: redacted line by line before the trim, so the lines'
      // numbers hold
      const { out, at } = trim(dg.lines.map(redact(rootsIn())), new Set(dg.mapAt.map((m) => m.idx)));
      const readsAt = dg.mapAt.flatMap((m) => m.files.map((file) => ({ file, line: at.get(m.idx) })));
      const text = `${out.join('\n')}\n`;
      fs.writeFileSync(path.join(run, 'digests', name), text);
      bytes += Buffer.byteLength(text);
      // its hash, kept outside the repo: finish reads only a digest that nothing changed since (the session can edit the
      // run folder, which is inside the repo)
      // 8d (D35): each digest's uses and the repo files it touched, kept here in the data folder for finish's checks,
      // and given to the analyzers in the run folder
      const files = [...new Set([...dg.touched].map((p) => inRoot(p, dg.cwd)).filter(Boolean))].sort();
      const its = [...new Set(dg.uses.map((u) => `${u.kind}\0${u.name}`))].map((k) => { const [kind, n] = k.split('\0'); return { kind, name: n }; });
      manifest.push({ f: c.f, end: c.size, digest: name, sha: crypto.createHash('sha256').update(text).digest('hex'), first: dg.first?.slice(0, 10), last: dg.last?.slice(0, 10), reads: [...dg.reads], readsAt, uses: its, touched: files });
      usage.sessions++;
    }
    // P-2: a git-ignored file (node_modules, build output) is no one's work, so it makes no package and no rule's paths.
    // One check for every digest's files
    const kept = new Set();
    // J-4 (06, 8m): git is given only paths it can take: none past a link, none read as pathspec magic, none in a
    // submodule or another repo (a folder on its way holds a .git)
    const rest = [...new Set(manifest.flatMap((m) => m.touched ?? []))].filter((f) => !f.startsWith(':') && plain(root, path.join(root, f)) && !f.split('/').slice(0, -1).some((s, i, a) => lstat(path.join(root, ...a.slice(0, i + 1), '.git'))));
    if (rest.length) {
      const x = spawnSync(exe('git'), ['check-ignore', '-z', '-v', '-n', '--stdin'], { cwd: root, input: rest.join('\0'), encoding: 'utf8' });
      const f = (x.stdout ?? '').split('\0');
      // "<source>\0<line>\0<pattern>\0<path>\0" per path: no pattern, or a "!" one, is not ignored
      for (let k = 0; k + 3 < f.length; k += 4) if (!f[k + 2] || f[k + 2].startsWith('!')) kept.add(f[k + 3]);
    }
    for (const m of manifest.filter((x) => x.digest)) {
      const files = (m.touched = m.touched.filter((f) => kept.has(f)));
      usage.digests[m.digest] = { uses: m.uses, touched: files, packages: [...new Set(files.map(packageOf).filter(Boolean))].sort() };
    }
    fs.writeFileSync(path.join(run, 'usage.json'), JSON.stringify(usage, null, 1));
    // 8c (D35): the team's steering, as HEAD holds it (under D14 an uncommitted edit is unreviewed); guidance for the
    // analyzers, never a source
    const steer = git(root, 'show', `HEAD:./${MAP}/steering.md`);
    if (steer.status === 0) fs.writeFileSync(path.join(run, 'steering.md'), steer.stdout);
    // the commit the tracked sources come from; none before the first commit (rev-parse would print "HEAD" itself)
    const pinned = git(root, 'rev-parse', '--verify', '-q', 'HEAD');
    // AU-10 (06, 9): the run's id, which finish and the skill's abort must name, so a finish that comes after a newer
    // prepare took the lock over (two hours) cannot apply that newer run
    const id = crypto.randomBytes(4).toString('hex');
    fs.writeFileSync(path.join(runDir, 'run.json'), JSON.stringify({ id, dirs: DIRS, root: real(root), head: pinned.status === 0 ? pinned.stdout.trim() : '', watched: list, links: linked, settings: settingsNow(root), manifest, left: left.length, date: localDate(), usage }, null, 1));
    const digests = manifest.filter((m) => m.digest);
    // K1: which topic files each session read, and the ones none read (evidence for the user, never a proposal)
    let topics = [];
    try { topics = fs.readdirSync(path.join(root, MAP)).filter(topic); } catch {}
    const read = new Set(digests.flatMap((m) => m.reads));
    // 8d (D35): the files these sessions touched, counted by package (counts only, no file names)
    const byPkg = new Map();
    for (const m of digests) for (const f of m.touched) { const k = packageOf(f) ?? '(no package)'; byPkg.set(k, (byPkg.get(k) ?? 0) + 1); }
    return [
      `Dream prepared: ${digests.length} session digest(s) in ${RUN}/digests/: ${digests.map((m) => `${m.digest} (${m.first}${m.last && m.last !== m.first ? ` to ${m.last}` : ''})`).join(', ') || 'none'}.`,
      digests.length ? `Map files these sessions read: ${digests.map((m) => `${m.digest}: ${m.reads.join(', ') || 'none'}`).join('; ')}. Topic files no session read: ${topics.filter((f) => !read.has(f)).join(', ') || 'none'}.` : '',
      [...byPkg.keys()].some((k) => k !== '(no package)') ? `Files these sessions touched, by package: ${[...byPkg].sort().map(([k, v]) => `${k} ${v}`).join(', ')}. Each digest's packages are in ${RUN}/usage.json.` : '',
      left.length ? `${left.length} more session(s) wait for the next dream (the cap is ${MAX_SESSIONS} sessions or ${MAX_BYTES >> 20} MB a run).` : '',
      digests.length ? '' : 'Nothing new to read since the last dream: run finish now to close it.',
      `Run id: ${id} (finish and abort take it).`,
      steer.status === 0 ? `Steering: ${RUN}/steering.md, the team's word on what matters here, as HEAD holds it.` : '',
      leftover,
    ].filter(Boolean).join('\n');
  } catch (e) { unlock(dir); throw e; }
}

// ---------- finish: validate, apply, log ----------
// email addresses (with a letter TLD, so react@18.3.1 is not one: the audit, 4k); drive, UNC and home-like absolute paths; UUIDs (session ids); common key shapes. A word character
// such as "_" before an id or a key does not hide it. D-2 (06, 8a): sk_/rk_, SendGrid, Hugging Face and bearer tokens,
// Slack webhooks, and a URL's credentials, its user empty or not (8k); and "[private]", a redacted digest line quoted.
// Q-14 (06, 8m): no route or web path (/users/:id, /home/dashboard: /home/<name> is a home when a path or the text
// ends after it), file name (avatar@2x.png), git remote (git@host:org/repo) or system folder (/etc, /opt, /srv); temp
// roots stay private. AU-18 (06, 9): and a session_ id of 20 letters or digits or more
export const PRIVATE = /[\w.+-]+@(?!\d+x\.(?:png|jpe?g|gif|webp|svg|avif)\b)[\w-]+(?:\.[\w-]+)*\.[a-z]{2,}(?![\w-]|\.[\w-]|:[\w~.-]*\/)|(?<![a-z0-9])[a-z]:[\\/]|\\\\[\w.$-]+\\|(?:^|[\s([{`'"=:;,<>*_~|]|\/\/)\/(?:users\/[\w.+$-]|home\/[\w.+$-]+(?:\/|(?=["'`\\\r\n]|$))|(?:root|var|tmp|mnt|private|volumes)\/)|(?:^|[\s([{`'"=:;,<>*_~|]|\/\/)\/(?:cygdrive\/)?[a-z]\/(?:users|home)\/|(?<![a-z0-9])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![a-z0-9])|(?<![a-z0-9])(?:[sr]k[-_][a-z0-9_-]{10,}|sg\.[a-z0-9_-]{16,}\.[a-z0-9_-]{16,}|hf_[a-z0-9]{30,}|gh[pousr]_[a-z0-9]{10,}|github_pat_[a-z0-9_]{10,}|(?:akia|asia)[0-9a-z]{12,}|xox[abpr]-[a-z0-9-]{10,}|glpat-[a-z0-9_-]{15,}|npm_[a-z0-9]{30,}|aiza[0-9a-z_-]{30,}|eyj[a-z0-9_-]{10,}\.[a-z0-9_-]{10,})|(?<![a-z0-9])session_[a-z0-9]{20,}(?![a-z0-9])|begin [a-z0-9 ]*private key|hooks\.slack\.com\/services\/|:\/\/[^\s/:@]*:[^\s/@]+@|bearer\s+[a-z0-9._~+/=-]{16,}|\[private\]/i;
// D-3 (06, 8a; amended in 8k): a digest line as the analyzers read it. After its tag, which the trim, finish and the
// analyzers key on, paths under the repo's roots (prepare's pattern) become relative; then each private match is
// replaced to the end of its token (a webhook's or a path's tail), and a key's header to the end of its line (the body)
const PRIVATE_ALL = new RegExp(`(?:${PRIVATE.source})\\S*`, 'gi');
const redact = (roots) => (l) => {
  const tag = /^[A-Z]!?: /.exec(l)?.[0] ?? '';
  return tag + l.slice(tag.length).replace(roots, (m, sep) => (sep ? '' : '.')).replace(/begin [a-z0-9 ]*private key.*/i, '[private]').replace(PRIVATE_ALL, '[private]');
};
// J-2 (06, 8m review): a byte-order mark before it, as map.mjs's FRONT allows
const front = (t) => /^﻿?---\n([\s\S]*?)\n---\n/.exec(t.replace(/\r/g, ''));
// a front-matter key's value on its own line, quotes dropped; '' when the key is missing or empty (the 8d review: \s*
// crossed the line end, so an empty "tools:" took the next key's value). K-4: or a YAML block list below the key
// ("tools:" then "  - Read" lines, the form Claude Code's docs show), its items joined
const field = (fm, k) => (new RegExp(`^${k}:[ \\t]*(\\S.*)$`, 'm').exec(fm?.[1] ?? '')?.[1]
  ?? new RegExp(`^${k}:[ \\t]*((?:\\n[ \\t]*-[ \\t]+\\S.*)+)`, 'm').exec(fm?.[1] ?? '')?.[1].split(/\n[ \t]*-[ \t]+/).slice(1).join(', ') ?? '').trim().replace(/^["']|["']$/g, '');
// X-4: a top-level key's whole text, each time it occurs: its line and the lines that continue it (indented, a list's
// "-" lines, blank ones, comments, which YAML skips inside a list), so a list, a folded value or a repeated key is seen
const entry = (fm, k) => { let on = false; return (fm?.[1] ?? '').split('\n').filter((l) => (on = /^([ \t#-]|$)/.test(l) ? on : new RegExp(`^${k}[ \\t]*:`).test(l))).join('\n'); };
// keys that let an agent or a skill act without asking: a draft that may set one is refused, never promoted on one yes.
// A top-level line that is not a plain key (a quoted or escaped key, an anchor, a tag, "?", "<<", a flow mapping) could
// spell one unseen, so it counts too
const POWERS = ['permissionMode', 'hooks', 'mcpServers'];
const odd = (fm) => !(fm?.[1] ?? '').split('\n').every((l) => /^([ \t#-]|$)|^[\w-]+[ \t]*:/.test(l));
const powers = (fm) => POWERS.some((k) => entry(fm, k)) || odd(fm);
// 8o: memory: user puts an agent's notes outside the repo; only project, local or none pass, spelled once, plainly
const userMemory = (fm) => Boolean(entry(fm, 'memory')) && !/^memory[ \t]*:[ \t]*(["']?)(project|local)\1[ \t]*$/.test(entry(fm, 'memory'));
// AU-1 (06, 9): the powers an artifact's front matter sets, by name, which the trial's show names for the person (D34:
// they approve what runs); the dream's own drafts may set none. A closing --- with no line end after it still counts
export function powersIn(kind, t) {
  const fm = front(`${t.replace(/\r/g, '').replace(/^---[ \t]+$/gm, '---')}\n`);
  const set = POWERS.filter((k) => entry(fm, k));
  if (kind === 'skill' && entry(fm, 'allowed-tools')) set.push('allowed-tools');
  if (kind === 'agent' && userMemory(fm)) set.push('memory');
  if (odd(fm)) set.push('odd');
  return set;
}
// AU-6 (06, 9): a skill's command lines, which run when it loads: an inline !` or a fenced ```! block, whole to its
// closing fence (show's reading, C-1)
export const commandLines = (t) => { let fenced = false; return t.split('\n').filter((l) => { const keep = fenced || /!`|^\s*```!/.test(l); fenced = fenced ? !/^\s*```\s*$/.test(l) : /^\s*```!/.test(l); return keep; }); };
const MADE = new Set(FILES.map(([, to]) => to));
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'entry';
// every ellipsis-separated segment of a proposed quote has 3 or more words, so none goes unchecked (the read hook's
// foundIn skips shorter segments, as 2.2.0's did)
const provable = (q) => { const segs = q.split(/…|\.\.\./).map((s) => words(s)).filter((w) => w.length); return segs.length > 0 && segs.every((w) => w.length >= 3); };
// a proposed entry keeps its heading (80 characters), its quote, and the lines id, source (200), when and review
const KEEP = /^- (id|source|when|review):/;
const tidy = (b) => b.split('\n').filter((l, k) => k === 0 || l.startsWith('>') || !l.trim() || KEEP.test(l))
  .map((l, k) => (k === 0 ? l.slice(0, 84) : l.startsWith('- source:') ? l.slice(0, 210) : l)).join('\n');
const STATUS = /^- status: (superseded|narrowed|expired|done) (\d{4}-\d{2}-\d{2}) by ([\w.-]+): (.+)$/;
// a digest line's reference, the digest perhaps with the folder it lies in, as an analyzer was given its path; one
// pattern for the evidence lines and the candidates (Audit 4, 06, 8m)
const REF = String.raw`(?:[^|,]*[\\/])?(d\d+\.digest):(\d+)`;
const evidence = (t, digests) => {
  const m = /<!--\s*evidence:([^>]*)-->/.exec(t);
  return new Set((m?.[1] ?? '').split(',').map((ref) => {
    const r = new RegExp(`^\\s*${REF}\\s*$`).exec(ref);
    const line = r && digests[r[1]]?.[Number(r[2]) - 1];
    return line && /^(U|Q): /.test(line) ? r[1] : null;
  }).filter(Boolean));
};
// 8f: the repo's run folder, emptied with its .gitignore last, so a folder the system will not fully remove (Windows,
// while a program has a folder in it as its working folder) never leaves a digest that git would see (D10). False when
// something is left
const clearRun = (run) => {
  try {
    // a link in its place is removed, never followed: emptying it would delete what it points to
    if (!lstat(run)?.isSymbolicLink()) for (const e of fs.readdirSync(run)) if (e !== '.gitignore') fs.rmSync(path.join(run, e), { recursive: true, force: true });
    fs.rmSync(run, { recursive: true, force: true });
    return true;
  } catch (e) { return e.code === 'ENOENT'; }
};
const STUCK = `${RUN}/ could not be removed (a program has it open, such as a shell whose working folder is inside it): delete that folder once nothing holds it.`;

export function finish(root, data, id) {
  const dir = stateDir(root, data);
  if (!fs.existsSync(path.join(dir, 'dream.lock'))) throw new Error('no dream is running here: run prepare first');
  // every check before the first change
  const { runDir, job, whole, forged } = record(root, dir, 'finish');
  if (!job) throw new Error('the run record is missing: run abort, then dream again');
  ours(job, id);
  if (forged) throw new Error('the run record names a path a dream never watches: run abort, then dream again');
  if (!whole) throw new Error('the snapshot is incomplete: run abort, then dream again');
  if (!inside(root, path.join(root, MAP, 'dreams.md'))) throw new Error(`${MAP}/ or its log is a link: the dream writes nothing through it; run abort`);
  const run = path.join(root, RUN);
  const digests = {};
  for (const m of job.manifest.filter((x) => x.digest)) {
    let bytes;
    try { bytes = fs.readFileSync(path.join(run, 'digests', m.digest)); } catch { throw new Error(`the digest ${m.digest} is missing: run abort, then dream again`); }
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== m.sha) throw new Error(`the digest ${m.digest} changed after prepare wrote it: run abort, then dream again`);
    digests[m.digest] = bytes.toString('utf8').split('\n');
  }
  // 8f (K1's second signal): a topic file read in a session, then corrected in the same session, from the analyzers'
  // candidates the skill wrote. A correction counts only at a U or Q line of its digest, after a read of that file
  // there (the reads' lines are the run record's, which the session cannot edit). Names and counts only, for the
  // person: never a proposal (D31)
  const corrected = new Map();
  let cands = '';
  try { cands = fs.readFileSync(path.join(run, 'candidates.txt'), 'utf8'); } catch {}
  for (const l of cands.split(/\r?\n/)) {
    const c = new RegExp(`^CANDIDATE \\| correction \\| ${REF} \\|`).exec(l.trim());
    if (!c || !/^(U|Q): /.test(digests[c[1]]?.[Number(c[2]) - 1] ?? '')) continue;
    // L-9 (06, 8m): a correction that names the topic file it corrects, as its last field, counts for that file only
    const named = /\| *(?:[\w.-]+[\\/])*([\w.-]+\.md) *$/.exec(l.trim())?.[1];
    for (const r of job.manifest.find((x) => x.digest === c[1])?.readsAt ?? []) if (topic(r.file) && r.line < Number(c[2]) && (!named || r.file === named)) { if (!corrected.has(r.file)) corrected.set(r.file, new Set()); corrected.get(r.file).add(c[1]); }
  }
  // what changed during the dream goes back to the snapshot: proposals reach the repo only through this step (06, S7)
  const { changed: strays, undone } = restore(root, dir, runDir, job.watched, job.links ?? {}, job.dirs);
  const settings = SETTINGS.filter((f) => (job.settings ?? {})[f] !== settingsNow(root)[f]);
  // what a person typed (U lines), and their answers to Claude's questions (Q lines). A quote resting on a Q line must
  // hold the answer they chose: the question's text is Claude's, and quoted alone it can say the opposite of the
  // choice (/code-review's finding)
  const lines = Object.values(digests).flat();
  // Q-16 (06, 8m): each session's typed lines apart, so a quote's pieces come from one session; a cut's mark and the
  // sdk-cli mark (L-8), each where prepare puts it, are no one's words
  const said = (l) => (l.startsWith(SDK, 3) ? l.slice(3 + SDK.length) : l.slice(3));
  const userTexts = Object.values(digests).map((d) => d.filter((l) => l.startsWith('U: ')).map((l) => said(l).replace(CUT, '')).join('\n').toLowerCase());
  const answers = lines.filter((l) => l.startsWith('Q: ') && l.includes(' = ')).map(said).map((l) => ({ question: l.slice(0, l.lastIndexOf(' = ')).replace(CUT, '').toLowerCase(), answer: words(l.slice(l.lastIndexOf(' = ') + 3).replace(CUT, '')).join(' ') }));
  // the quote holds the choice as its own part, "<the question> = <the answer>": its question part (three words or
  // more) is found in the Q line's question, and its answer part is the answer chosen, word for word. Before, an
  // answer's word that also occurred in the question let a quote of the question alone pass (agy's release round)
  const chosen = (q) => {
    const k = q.lastIndexOf(' = ');
    if (k < 0) return false;
    const asked = q.slice(0, k);
    const picked = words(q.slice(k + 3)).join(' ');
    return words(asked).length >= 3 && answers.some((a) => a.answer && picked === a.answer && foundIn(asked, a.question));
  };
  // a tracked file's text as HEAD holds it: an uncommitted edit, or a tracked link to an ignored file, is no source.
  // D-5 (06, 8a): each file's text apart, never joined (a join past about 512 MB throws, with the lock held), and a
  // file holding a NUL byte is binary and skipped. shortcut: blobs over 2 MB are skipped and the rest are read at
  // once; stream them if a repo's text outgrows memory
  let repoText = null;
  const headText = () => {
    // a repo with no commit at prepare has no tracked source: HEAD at finish would count commits made during the dream
    if (!job.head) return [];
    const tree = spawnSync(exe('git'), ['ls-tree', '-r', '-l', '-z', job.head], { cwd: root, encoding: 'utf8', maxBuffer: 256 << 20 }).stdout ?? '';
    const oids = tree.split('\0').map((l) => /^(\d+) blob ([0-9a-f]+) +(\d+)\t(.*)$/s.exec(l)).filter((m) => m && m[1] !== '120000' && Number(m[3]) <= 2 << 20 && !m[4].startsWith(`${MAP}/`)).map((m) => m[2]);
    if (!oids.length) return [];
    const out = spawnSync(exe('git'), ['cat-file', '--batch'], { cwd: root, input: `${oids.join('\n')}\n`, maxBuffer: 1 << 30 }).stdout ?? Buffer.alloc(0);
    const parts = [];
    // "<oid> blob <size>\n<bytes>\n" per blob; a missing object is "<oid> missing\n", with no body (/code-review)
    for (let i = 0; i < out.length;) {
      const nl = out.indexOf(10, i);
      if (nl < 0) break;
      const [, type, size] = out.toString('latin1', i, nl).split(' ');
      if (type !== 'blob') { i = nl + 1; continue; }
      const body = out.subarray(nl + 1, nl + 1 + Number(size));
      if (!body.includes(0)) parts.push(body.toString('utf8').toLowerCase());
      i = nl + 1 + Number(size) + 1;
    }
    return parts;
  };
  const inTracked = (q) => { repoText ??= headText(); return repoText.some((t) => foundIn(q, t)); };
  const date = localDate();
  const n = { entries: 0, status: 0, rules: 0, skills: 0, agents: 0, changes: 0 };
  const dropped = {};
  const drop = (why) => { dropped[why] = (dropped[why] ?? 0) + 1; };
  const written = [];
  // 06, 8k: map files are read as the hooks read them (readMapFile, H4), so a FIFO, a device or a file over 4 MB is
  // never read, written or given a status line; null when one cannot be read
  const readMap = (f) => { try { return readMapFile(root, f); } catch { return null; } };
  // every id the map holds now, so a new entry never reuses one
  const ids = new Set(mapFiles(root).flatMap((f) => { const b = readMap(f); return b ? idsIn(decode(b)) : []; }));
  // a proposed id that clashed, and its new name, so a status line's "by" follows it
  const renamed = new Map();
  // a UTF-16 map file (Windows PowerShell 5.1 writes one) is never appended to: UTF-8 text after it would corrupt it
  const mapText = (f) => { const b = readMap(f); return b && !utf16(b) ? b.toString('utf8') : null; };
  const P = path.join(run, 'proposals');
  // map entries: appended to their topic file, each marked proposed, never replacing or changing what is there. The
  // dream log and the README are no topic files (/code-review of 2.3.0)
  const mapDir = path.join(P, 'map');
  for (const f of fs.existsSync(mapDir) ? fs.readdirSync(mapDir).filter((x) => /^[\w.-]+\.md$/.test(x)) : []) {
    if (!topic(f)) { drop('not a topic file'); continue; }
    if (PRIVATE.test(f)) { drop('private data'); continue; } // a file name becomes a path and a name in the repo
    const text = fs.readFileSync(path.join(mapDir, f), 'utf8').replace(/\r/g, '');
    const target = path.join(root, MAP, f);
    const safe = inside(root, target);
    const now = fs.existsSync(target) ? readMap(`${MAP}/${f}`) : Buffer.alloc(0);
    const keep = [];
    for (let b of entries(text)) {
      if (!safe) { drop('a link on its path'); continue; }
      if (!now) { drop('a map file that cannot be read'); continue; }
      if (utf16(now)) { drop('a UTF-16 map file'); continue; }
      // the privacy scan reads the entry whole, before tidy cuts its lines, and again once its id is made from its heading
      if (PRIVATE.test(b)) { drop('private data'); continue; }
      // D-1 (06, 8a and 8k): the when and review lines are free text the model writes, so an entry holds one of each,
      // of at most 200 characters
      if (/^- (when|review):(?:.{201,}$|[\s\S]*^- \1:)/m.test(b)) { drop('more than one when or review line, or one over 200 characters'); continue; }
      b = tidy(b);
      const q = quoteOf(b);
      if (!q.trim() || !provable(q) || !(userTexts.some((t) => foundIn(q, t)) || chosen(q) || inTracked(q))) { drop('no typed or tracked source'); continue; }
      let id = idsIn(b)[0];
      const asked = id;
      if (!id || ids.has(id)) { const base = slug(id ?? b.split('\n')[0].slice(4)); id = base; for (let k = 2; ids.has(id); k++) id = `${base}-${k}`; b = /^- id:/m.test(b) ? b.replace(/^- id:.*$/m, `- id: ${id}`) : `${b}\n- id: ${id}`; }
      if (PRIVATE.test(b)) { drop('private data'); continue; }
      ids.add(id);
      if (asked && asked !== id) renamed.set(asked, id);
      keep.push(`${b.trimEnd()}\n- proposed: dream ${date}`);
    }
    if (!keep.length) continue;
    // a new topic file gets fixed front matter: its description reaches session start's catalog before any review, so
    // no proposed text goes there
    const exists = fs.existsSync(target);
    const head = exists ? '' : `---\nname: ${f.replace(/\.md$/, '')}\ndescription: Decisions a dream proposed for this area. Read before changing it.\n---\n`;
    fs.appendFileSync(target, `${head}${exists ? '\n' : ''}${keep.join('\n\n')}\n`);
    written.push(`${MAP}/${f}`);
    n.entries += keep.length;
  }
  // status lines: added to an existing entry, after its last line; the entry's other lines stay as they are. The id
  // after "by" names an entry the map holds or this dream proposes
  const sf = path.join(P, 'status.md');
  for (const line of fs.existsSync(sf) ? fs.readFileSync(sf, 'utf8').split('\n').filter((l) => l.includes('|')) : []) {
    const id = line.slice(0, line.indexOf('|')).trim();
    const raw = line.slice(line.indexOf('|') + 1).trim();
    const s = STATUS.exec(raw);
    if (!/^[\w.-]+$/.test(id) || !s || PRIVATE.test(raw)) { drop('malformed status line'); continue; }
    const by = renamed.get(s[3]) ?? s[3];
    if (!ids.has(by)) { drop('status naming an unknown id'); continue; }
    const sline = `- status: ${s[1]} ${s[2]} by ${by}: ${s[4].slice(0, 200)}`;
    const found = mapFiles(root).filter((p) => topic(path.basename(p))).map((p) => [p, mapText(p)]).find(([, t]) => t !== null && idsIn(t).includes(id));
    if (!found) { drop('status for an unknown id'); continue; }
    const [file, t] = found;
    if (!inside(root, path.join(root, file))) { drop('a link on its path'); continue; }
    // the entry's metadata lines, the last of them possibly the file's last line with no newline after it
    const re = new RegExp(`(^- id:[ \\t]*${id.replace(/[.]/g, '\\.')}[ \\t]*(?:\\r?\\n|$)(?:- .*(?:\\r?\\n|$))*)`, 'm');
    if (/^- status:/m.test(t.slice(t.search(re)).split(/\n(?=#{1,3} )/)[0])) { drop('entry already has a status'); continue; }
    // marked proposed too, so the read hook labels it until review (a function, so "$&" in the text stays text)
    fs.writeFileSync(path.join(root, file), t.replace(re, (all) => `${all}${all.endsWith('\n') ? '' : '\n'}${sline}\n${/^- proposed:/m.test(all) ? '' : `- proposed: dream ${date}\n`}`));
    written.push(file);
    n.status++;
  }
  // rule and skill drafts: inert (*.md.draft, which Claude Code never loads) until review promotes them (D31)
  const rulesDir = path.join(P, 'rules');
  for (const f of fs.existsSync(rulesDir) ? fs.readdirSync(rulesDir).filter((x) => /^[\w.-]+\.md$/.test(x)) : []) {
    if (PRIVATE.test(f)) { drop('private data'); continue; }
    const t = fs.readFileSync(path.join(rulesDir, f), 'utf8').replace(/\r/g, '');
    const fm = front(t);
    const paths = fm && /^paths:[ \t]*(\[[^\]]*\S[^\]]*\]|\n(?:[ \t]+-[ \t]+\S.*\n?)+)/m.exec(`${fm[1]}\n`);
    if (!paths) { drop('rule without paths'); continue; }
    // 8d (D35): a rule placed in a package names folders the repo holds: each glob's fixed part, up to its last /
    // an inline list splits on commas outside quotes and braces, so "packages/{api,web}/**" stays one glob (the 8d review)
    const globs = (paths[1].startsWith('[') ? paths[1].slice(1, -1).match(/(?:"[^"]*"|'[^']*'|\{[^}]*\}|[^,])+/g) ?? [] : paths[1].split('\n').map((l) => l.replace(/^[ \t]*-[ \t]+/, ''))).map((g) => g.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
    const fixed = (g) => { const pre = g.split(/[*?[{]/)[0]; return pre.includes('/') ? pre.slice(0, pre.lastIndexOf('/')) : ''; };
    // lstat: a linked folder, or a name the system cannot hold (a NUL), counts as lacking; a backslash is no glob separator
    if (globs.some((g) => g.includes('\\') || (fixed(g) && !(lstat(path.join(root, fixed(g)))?.isDirectory() && inRepo(root, path.join(root, fixed(g))))))) { drop('rule paths naming a folder the repo lacks'); continue; }
    if (t.split('\n').length > 60 || PRIVATE.test(t)) { drop('rule too long or private'); continue; }
    if (evidence(t, digests).size < 2) { drop('rule from fewer than two sessions'); continue; }
    // a name that neither a draft nor a live rule holds, so promoting the draft (dropping .draft) replaces no rule
    const rd = path.join(root, '.claude', 'rules');
    const stem = f.replace(/\.md$/, '');
    let target;
    for (let k = 1; ; k++) { const live = path.join(rd, `${k === 1 ? stem : `${stem}-${k}`}.md`); if (!fs.existsSync(live) && !fs.existsSync(`${live}.draft`)) { target = `${live}.draft`; break; } }
    if (!inside(root, target)) { drop('a link on its path'); continue; }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, t, { flag: 'wx' });
    written.push(path.relative(root, target).split(path.sep).join('/'));
    n.rules++;
  }
  const skillsDir = path.join(P, 'skills');
  for (const d of fs.existsSync(skillsDir) ? fs.readdirSync(skillsDir).filter((x) => /^[\w.-]+$/.test(x)) : []) {
    const p = path.join(skillsDir, d, 'SKILL.md');
    if (!fs.existsSync(p)) continue;
    if (PRIVATE.test(d)) { drop('private data'); continue; }
    // the user's word (06, 8m): the draft is written as proposed, with no disable-model-invocation added
    const t = fs.readFileSync(p, 'utf8').replace(/\r/g, '');
    const fm = front(t);
    if (!field(fm, 'name') || !field(fm, 'description')) { drop('skill without name or description'); continue; }
    // Audit 3 (06, 8m): as for agents, the name is the folder's, and nothing the folder holds is replaced or doubled
    if (field(fm, 'name') !== d) { drop('a name that is not its file name'); continue; }
    // J-1 (06, 8m): what a skill may run, or hooks, the person sets by hand
    if (powers(fm) || entry(fm, 'allowed-tools')) { drop('skill that may set allowed-tools, hooks or other powers'); continue; }
    // AU-6 (06, 9): and its command lines, which run when it loads
    if (commandLines(t).length) { drop('skill with a command line (!)'); continue; }
    if (PRIVATE.test(t)) { drop('skill with private data'); continue; }
    if (evidence(t, digests).size < 2) { drop('skill from fewer than two sessions'); continue; }
    const folder = path.join(root, '.claude', 'skills', d);
    if (fs.existsSync(path.join(folder, 'SKILL.md'))) { drop('a skill the repo holds'); continue; }
    if (fs.existsSync(path.join(folder, 'SKILL.md.draft'))) { drop('a draft already waits'); continue; }
    if (!inside(root, path.join(folder, 'SKILL.md.draft'))) { drop('a link on its path'); continue; }
    fs.mkdirSync(folder, { recursive: true });
    fs.writeFileSync(path.join(folder, 'SKILL.md.draft'), t, { flag: 'wx' });
    written.push(path.relative(root, path.join(folder, 'SKILL.md.draft')).split(path.sep).join('/'));
    n.skills++;
  }
  // 8d (D35): agent drafts, never loaded until review promotes them (D34, probe 3), through a skill draft's gates
  const agentsDir = path.join(P, 'agents');
  for (const f of fs.existsSync(agentsDir) ? fs.readdirSync(agentsDir).filter((x) => /^[\w.-]+\.md$/.test(x)) : []) {
    if (PRIVATE.test(f)) { drop('private data'); continue; }
    const t = fs.readFileSync(path.join(agentsDir, f), 'utf8').replace(/\r/g, '');
    const fm = front(t);
    if (!field(fm, 'name') || !field(fm, 'description') || !field(fm, 'tools')) { drop('agent without name, description or tools'); continue; }
    // Claude Code knows an agent by its name, so the name is the file's: a draft cannot pass as another agent
    if (field(fm, 'name') !== f.slice(0, -3)) { drop('a name that is not its file name'); continue; }
    if (powers(fm)) { drop('agent that may set permissionMode, hooks or mcpServers'); continue; }
    if (userMemory(fm)) { drop('agent with memory: user, or a memory other than project or local'); continue; }
    if (PRIVATE.test(t)) { drop('agent with private data'); continue; }
    if (evidence(t, digests).size < 2) { drop('agent from fewer than two sessions'); continue; }
    const live = path.join(root, '.claude', 'agents', f);
    if (fs.existsSync(live)) { drop('an agent the repo holds'); continue; }
    if (fs.existsSync(`${live}.draft`)) { drop('a draft already waits'); continue; }
    if (!inside(root, `${live}.draft`)) { drop('a link on its path'); continue; }
    fs.mkdirSync(path.dirname(live), { recursive: true });
    fs.writeFileSync(`${live}.draft`, t, { flag: 'wx' });
    written.push(path.relative(root, `${live}.draft`).split(path.sep).join('/'));
    n.agents++;
  }
  // 8d (D35): a change to a skill or agent the repo holds, as a draft beside it, when every session it cites used it
  // (the uses kept in the run record, which the session cannot edit). A skill's change keeps the file's
  // disable-model-invocation as it is: the person chose whether Claude may start that skill
  const usedIn = Object.fromEntries(job.manifest.filter((m) => m.digest).map((m) => [m.digest, new Set((m.uses ?? []).map((u) => `${u.kind}\0${u.name}`))]));
  const list = (d, re) => { try { return fs.readdirSync(d).filter((x) => re.test(x)); } catch { return []; } };
  const changes = [
    ...list(path.join(P, 'change', 'skills'), /^[\w.-]+$/).map((d) => ({ kind: 'skill', name: d, src: path.join(P, 'change', 'skills', d, 'SKILL.md'), live: path.join(root, '.claude', 'skills', d, 'SKILL.md') })),
    ...list(path.join(P, 'change', 'agents'), /^[\w.-]+\.md$/).map((f) => ({ kind: 'agent', name: f.slice(0, -3), src: path.join(P, 'change', 'agents', f), live: path.join(root, '.claude', 'agents', f) })),
  ];
  for (const c of changes) {
    if (!fs.existsSync(c.src)) continue;
    if (PRIVATE.test(c.name)) { drop('private data'); continue; }
    let t = fs.readFileSync(c.src, 'utf8').replace(/\r/g, '');
    const fm = front(t);
    if (!field(fm, 'name') || !field(fm, 'description') || (c.kind === 'agent' && !field(fm, 'tools'))) { drop('change without name, description or tools'); continue; }
    if (field(fm, 'name') !== c.name) { drop('a name that is not its file name'); continue; }
    if (powers(fm)) { drop('change that may set permissionMode, hooks or mcpServers'); continue; }
    if (userMemory(fm)) { drop('change with memory: user, or a memory other than project or local'); continue; }
    // the files setup makes stay the plugin's: setup updates them (D29), and map-review is the review itself (D33)
    if (MADE.has(path.relative(root, c.live).split(path.sep).join('/'))) { drop('a change to a file setup makes'); continue; }
    if (PRIVATE.test(t)) { drop('change with private data'); continue; }
    const cited = evidence(t, digests);
    if (cited.size < 2) { drop('change from fewer than two sessions'); continue; }
    if (![...cited].every((d) => usedIn[d]?.has(`${c.kind}\0${c.name}`))) { drop('change whose sessions did not use it'); continue; }
    if (!fs.existsSync(c.live)) { drop('change for a file the repo lacks'); continue; }
    const liveText = fs.readFileSync(c.live, 'utf8').replace(/\r/g, '');
    const liveFm = front(liveText);
    // X-4: a change keeps what the skill or agent may run as the live file has it (J-2, 06, 8m: and may not), so a
    // removed disallowedTools is a widening too; the person changes that by hand
    if (['allowed-tools', 'tools', 'disallowedTools'].some((k) => entry(fm, k) !== entry(liveFm, k))) { drop('change to allowed-tools or tools'); continue; }
    // AU-6 (06, 9): a skill's change keeps its command lines exactly as the live file has them, in order
    if (c.kind === 'skill' && commandLines(t).join('\n') !== commandLines(liveText).join('\n')) { drop('change to a command line (!)'); continue; }
    if (fs.existsSync(`${c.live}.draft`)) { drop('a draft already waits'); continue; }
    if (!inside(root, `${c.live}.draft`)) { drop('a link on its path'); continue; }
    if (c.kind === 'skill') {
      const flag = (liveFm?.[1] ?? '').split('\n').find((l) => /^disable-model-invocation\s*:/.test(l));
      t = `---\n${[...(flag ? [flag] : []), ...fm[1].split('\n').filter((l) => !/^disable-model-invocation\s*:/.test(l))].join('\n')}\n---\n${t.slice(fm[0].length)}`;
    }
    fs.writeFileSync(`${c.live}.draft`, t, { flag: 'wx' });
    written.push(path.relative(root, `${c.live}.draft`).split(path.sep).join('/'));
    n.changes++;
  }
  // the log line: counts only, no ids; the previous dream's survival is what its proposals became in HEAD (G7)
  const st = loadState(dir);
  const head = git(root, 'show', `HEAD:./${MAP}/dreams.md`).status === 0 ? mapFiles(root).map((f) => git(root, 'show', `HEAD:./${f}`).stdout).join('\n') : '';
  // the previous dream's local date, the one its proposed lines carry (lastDream is UTC; /code-review's finding)
  const prev = dreamDate(st);
  const accepted = prev ? (head.match(new RegExp(`^- origin: dream ${prev}`, 'gm')) ?? []).length : 0;
  const waiting = prev ? (head.match(new RegExp(`^- proposed: dream ${prev}`, 'gm')) ?? []).length : 0;
  const read = job.manifest.filter((m) => m.digest);
  const span = read.length ? `${read[0].first} to ${read.at(-1).last ?? read.at(-1).first}` : 'none';
  const line = `- ${date}: ${read.length} session(s) (${span}); proposed ${n.entries} entr${n.entries === 1 ? 'y' : 'ies'}, ${n.status} status line(s), ${n.rules} rule draft(s), ${n.skills} skill draft(s)${n.agents ? `, ${n.agents} agent draft(s)` : ''}${n.changes ? `, ${n.changes} change draft(s)` : ''}; dropped ${Object.values(dropped).reduce((a, b) => a + b, 0)}`
    + (prev ? `; the dream of ${prev}: ${accepted} accepted, ${waiting} still proposed` : '');
  // a dream that read nothing writes no log line and keeps the last dream's date; skipped sessions still count as seen
  const prevSeen = { ...st.seen };
  for (const m of job.manifest) st.seen[m.f] = m.end;
  if (read.length) {
    const log = path.join(root, MAP, 'dreams.md');
    fs.appendFileSync(log, `${fs.existsSync(log) ? '' : '# Dream log\n\n'}${line}\n`);
    // the watermark moves; it moves back if this log line is never kept (prepare's check)
    st.pending = { line, prevSeen, prevLastDream: st.lastDream, prevLastDreamDate: st.lastDreamDate ?? null, root: real(root) };
    st.lastDream = new Date().toISOString();
    st.lastDreamDate = date;
  }
  // the state after the run record is gone: a finish that stopped before it can be retried without a second pending
  // record overwriting the first one's prevSeen (the devils-advocate review). The repo's run folder goes last, at best:
  // Windows refuses to delete a folder while a program has it as its working folder, and that must not strand the lock
  // and the state (8f, a field failure of 2.5.1); prepare clears a leftover one
  fs.rmSync(runDir, { recursive: true, force: true });
  fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify(st, null, 1));
  // still under the lock, so a new prepare cannot lose its folder to this removal (the 8f review); clearRun never throws
  const stuck = clearRun(run) ? '' : `${STUCK} The dream is finished.`;
  unlock(dir);
  const drops = Object.entries(dropped).map(([k, v]) => `${v} ${k}`).join(', ');
  return [`Dream finished: ${line.slice(2)}.`, ...usageLines(job.usage),
    corrected.size ? `Read, then corrected again in the same session: ${[...corrected].sort().map(([f, s]) => `${f} (${s.size} session${s.size === 1 ? '' : 's'})`).join(', ')}.` : '',
    tell(dir, strays.length ? `Undone, because they changed during the dream (only its proposals reach the repo): ${strays.join(', ')}.${undone ? ` What they replaced is saved in ${undone}; copy back anything that was not the dream's.` : ''}` : ''),
    settings.length ? `Changed during the dream and left as they are: ${settings.join(', ')}. An "always allow" you gave lands there; check the rest, hooks above all.` : '',
    drops ? `Dropped: ${drops}.` : '', written.length ? `Written (uncommitted): ${[...new Set(written)].join(', ')}.` : 'Nothing written.',
    // AU-3 (06, 9): the next prepare waits until the log line is committed, so the Next line names it
    `Next: ${written.length || !read.length ? `${reviewStep(root)} to accept or reject the proposals and promote drafts; then commit${read.length ? ` them with ${MAP}/dreams.md, whose new line the next dream waits for` : ''}.` : `commit ${MAP}/dreams.md, whose new line the next dream waits for.`}`, stuck].filter(Boolean).join('\n');
}

// 8c (D35): the report's lines on use: one per skill and agent the repo holds, then failures and subagent runs. Counts
// only, from this machine's sessions; "no use" needs 10 sessions read
export function usageLines(u) {
  if (!u) return [];
  const n = u.sessions;
  // names come from transcripts and meta files: no control character can start a line of its own, and none runs long
  const safe = (s) => String(s).replace(/[\x00-\x1f\x7f]/g, '?').slice(0, 80);
  const line = (kind, name) => {
    const e = Object.hasOwn(u[kind], name) ? u[kind][name] : null;
    if (e) return `${kind === 'skill' ? 'Skill' : 'Agent'} ${safe(name)}: used ${e.uses} time${e.uses === 1 ? '' : 's'} in ${e.sessions} session${e.sessions === 1 ? '' : 's'} here; a typed line after ${e.after}.`;
    return n >= 10 ? `${kind === 'skill' ? 'Skill' : 'Agent'} ${safe(name)}: no use in the ${n} sessions this machine's dream read; a teammate's sessions are not counted.` : '';
  };
  const list = (o, f) => Object.entries(o).map(([k, v]) => f(safe(k), v)).join(', ');
  return [
    ...(u.ownSkills ?? []).map((s) => line('skill', s)),
    ...(u.ownAgents ?? []).map((a) => line('agent', a)),
    Object.keys(u.failed).length ? `Failed tool results in these sessions: ${list(u.failed, (t, v) => `${t} ${v}`)}.` : '',
    Object.keys(u.subagents).length ? `Subagent runs: ${list(u.subagents, (t, v) => `${t} ${v.runs}${v.failed ? ` (${v.failed} failed tool result${v.failed === 1 ? '' : 's'})` : ''}`)}.` : '',
  ].filter(Boolean);
}

// ---------- abort: the snapshot back, the lock released, the watermark untouched ----------
export function abort(root, data, id) {
  const dir = stateDir(root, data);
  const { runDir, job, whole } = record(root, dir, 'abort');
  // with no id, the skill's route for a dream that stopped in another session, which the person confirms
  ours(job, id);
  // no run record yet: the lock still names the root that holds it
  const holder = (() => { try { return fs.readFileSync(path.join(dir, 'dream.lock'), 'utf8'); } catch { return ''; } })();
  if (!job && holder && holder !== real(root)) throw new Error('this dream was prepared in another worktree of this repo: run abort there');
  let said = 'Dream aborted: nothing was restored, because its run record or snapshot is missing. The next dream reads the same sessions.';
  if (job && whole) {
    const { changed, undone } = restore(root, dir, runDir, job.watched, job.links ?? {}, job.dirs);
    const settings = SETTINGS.filter((f) => (job.settings ?? {})[f] !== settingsNow(root)[f]);
    const what = changed.length ? ` Undone: ${changed.join(', ')}.${undone ? ` What they replaced is saved in ${undone}.` : ''}` : '';
    tell(dir, what && `A dream was aborted.${what}`);
    said = `Dream aborted: the map and Claude's instruction files are as they were before the dream, and the next dream reads the same sessions.${what}`
      + (settings.length ? ` Changed during the dream and left as they are: ${settings.join(', ')}; check them, hooks above all.` : '');
  }
  // the run record first, then the repo's run folder, which never throws, then the lock, as finish does (8f)
  fs.rmSync(runDir, { recursive: true, force: true });
  if (inRepo(root, path.join(root, MAP)) && !clearRun(path.join(root, RUN))) said += ` ${STUCK}`;
  unlock(dir);
  return said;
}

// the command: the repo is the git top level of where Claude Code runs it
if (path.basename(process.argv[1] ?? '') === 'dream.mjs') {
  const [step, data, id] = process.argv.slice(2);
  const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? process.cwd());
  // N6 (06, section 4, 4c): prepare runs from the skill's ! line, and a failed ! command aborts the skill (Claude Code's
  // docs), so its refusals exit 0 and reach Claude as text; finish and abort, run by Claude, keep exit 1
  const stop = (why) => { console.log(`The dream stopped: ${why}`); if (step !== 'prepare') process.exitCode = 1; };
  if (!['prepare', 'finish', 'abort'].includes(step) || !data) {
    console.log('usage: node dream.mjs <prepare|finish|abort> <the plugin data folder>; run it as /second-brain:dream');
    process.exitCode = 1;
  } else if (!fs.existsSync(path.join(root, '.git'))) {
    // Q-11 (06, 8k): the dream's state is kept per git repository, so with no .git it says so plainly, naming no path
    stop(`this folder is not in a git repository, and the team memory (${MAP}/) is kept per repository. Run /second-brain:dream inside one.`);
  } else if (!dataOk(root, data)) {
    stop('its data folder must be the plugin\'s own (under plugins/data), outside the repo. Run it as /second-brain:dream.');
  } else {
    try { console.log(step === 'prepare' ? await prepare(root, data) : step === 'finish' ? finish(root, data, id ?? null) : abort(root, data, id)); } catch (e) { stop(e.message); }
  }
}
