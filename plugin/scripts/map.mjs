// The project map's hook library (V2-D14, D16, D18, D22). No model and no network: hooks spawn only git, and no map
// text reaches a process.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const MAP = '.project-map';

// D14's capture instruction, frozen: its sha256 is in the ledger. 06, section 3, S4: new entries go to topic files
// with front matter, and carry id and verified lines; a review line where a decision is time-bound; status lines
// name the new entry's id
export const INSTRUCTION = `This project keeps a map of its knowledge in the folder .project-map/. When, during your work, someone states a
decision or rule for this project, or you receive or read a document that states requirements, specifications or
rules the project's work must follow, add each one as its own entry, in the words used, with its source, to the
topic file in .project-map/ that covers its area. If none fits, create one named for the area, such as avatars.md,
that starts with this front matter:

---
name: <the area>
description: <what it covers, and when to read it>
---

Keep what will still matter in later sessions; leave out one-off details of the current task.
Decisions and rules for this project belong in this map, not in your auto memory, which is for your own way of working.
Entry format:

### <the part of the project it governs>
> <the decision, rule or requirement, in the words used>

- id: <a short unique slug, such as avatars-local-only>
- source: <who stated it, or the document's title or path>, <date>
- when: ["<kind of work it applies to>", "..."]
- verified: <YYYY-MM-DD> <how you know it holds, such as "stated by the PM">

End the source line with the date, as YYYY-MM-DD; put any other detail in parentheses before it.
If a decision holds only until a known date, add the line: - review: <YYYY-MM-DD>
When a new entry replaces, narrows or ends an existing one, keep the old entry and add this line under its when line:
- status: <superseded|narrowed|expired|done> <YYYY-MM-DD> by <the new entry's id>: <what still holds>

Never write session ids, email addresses or absolute file paths into an entry. The map is plain files in this
repository: your changes to it stay in the working tree and are reviewed with the commit, like any other change.`;

// D22: Vercel's instruction with its scope adapted, fixed before the pull check ran; then the documents by directory
export const HEADER = 'IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project. '
  + "This project's documents, by directory:";

// D22's forced decision, at the first prompt of each epoch
export const FORCE = 'Before you start: for each directory in this project\'s document index, state in one line whether its '
  + 'documents bear on this task (yes or no). Then read the documents in every directory you marked yes before you '
  + 'change anything.';

// V2-D23: A1 item (5), the decisions followed and their sources, named when Claude finishes; frozen with D23's check.
// 06, 2s: (d) once per session, and not an entry a status line ends (D28's N)
export const NAME = 'When you finish, name each of this project\'s recorded decisions you followed and its source, as the '
  + 'map entry or document gives it, unless you named it earlier in this session. Do not name a decision you did not '
  + 'follow, one whose status line says it no longer holds, or a source the record does not give.';

export const UNREVIEWED = 'unreviewed, not yet committed';
// 06, 2n: the field found "unverified quote" unexplained; wording only, D16's choice unchanged
export const UNVERIFIED_NOTE = '("unverified quote": the entry\'s source is not a file in this repo, such as a person\'s words, so its '
  + 'quote cannot be re-found; the date is when it was captured.)';
// V2-D27: shown to the user, never to Claude, while v1's statusline or timer shim is on disk
export const V1_LEFT = 'second-brain v1 left its statusline or timer on this machine. To remove them: '
  + 'https://github.com/Cain-Ish/claude-code-plugin#coming-from-v1';

const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
// the git helper for text output the scripts share (D18: they spawn only git)
export const git = (root, ...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
// UTF-16 with its byte-order mark (Windows PowerShell 5.1's Out-File and > write it), else UTF-8 (D18, J4)
export const utf16 = (b) => (b[0] === 0xff && b[1] === 0xfe) || (b[0] === 0xfe && b[1] === 0xff);
export const decode = (b) => (b[0] === 0xff && b[1] === 0xfe ? b.toString('utf16le')
  : b[0] === 0xfe && b[1] === 0xff ? Buffer.from(b.subarray(0, b.length & ~1)).swap16().toString('utf16le') : b.toString('utf8'));
export const rel = (root, p) => path.relative(root, String(p ?? '')).replace(/\\/g, '/');
// an entry's parts, read the same way by the read hook, the status report and the dream (06, section 4, 4h)
export const quoteOf = (b) => b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n');
export const idsIn = (t) => [...t.matchAll(/^- id:[ \t]*(\S+)[ \t]*\r?$/gm)].map((m) => m[1]);
export const proposedOn = (b) => /^- proposed:[ \t]*dream[ \t]+(\d{4}-\d{2}-\d{2})[ \t]*$/m.exec(b)?.[1];
export const reviewOn = (b) => /^- review:[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$/m.exec(b)?.[1];
// a status line's head, and the id it names after "by": right after the kind and date, holding a digit or a hyphen, so
// free text such as "done 2026-11-18 by hand" never reads as one (agy's S3 round)
export const statusOf = (b) => /^- status:[ \t]*(\S.*)$/m.exec(b)?.[1].trim();
export const replacedBy = (status) => status && /^\S+[ \t]+\d{4}-\d{2}-\d{2}[ \t]+by[ \t]+((?=[\w.-]*[\d-])[A-Za-z0-9][\w.-]*)[ \t]*(?::|$)/.exec(status)?.[1];
export const configDir = () => process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
export const textOf = (root, f) => { try { return decode(fs.readFileSync(path.join(root, f))); } catch { return ''; } };

// The repo's root: the nearest folder at or above where Claude started that holds .git (a folder, or a worktree's
// file), so a session started in a subdirectory still sees the whole index and labels the root's map (D18, 2g)
export function toplevel(dir) {
  for (let d = path.resolve(dir); ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, '.git'))) return d;
    if (path.dirname(d) === d) return path.resolve(dir);
  }
}
// p's nearest existing folder or file, found by lstat so a dangling link stops the walk, resolves inside root; one that
// cannot be resolved counts as outside. Setup and the dream share it (agy's release round: mkdir followed a dangling
// link out of the repo; /code-review of 2.3.0: the dream's copy walked past one)
export function inRepo(root, p) {
  try {
    let q = path.resolve(p);
    while (!fs.lstatSync(q, { throwIfNoEntry: false })) { if (path.dirname(q) === q) return false; q = path.dirname(q); }
    const real = fs.realpathSync.native(q);
    const base = fs.realpathSync.native(root);
    return real === base || real.startsWith(base + path.sep);
  } catch { return false; }
}

// the files under the map folder, as repo paths in git's order; a symlink counts as a file, as git lists it. Given
// `seen`, the real paths of folders already walked (the Bash handler, 06 2o): regular files only, directly or through
// a link, since Claude can read entries through a link and a FIFO would block the read; each folder once
export const under = (root, d, seen) => fs.readdirSync(path.join(root, d), { withFileTypes: true }).flatMap((e) => {
  const p = `${d}/${e.name}`;
  if (!seen) return e.isDirectory() ? under(root, p) : [p];
  // a link whose target is gone shows nothing to `cat`, so it is skipped (Emacs leaves one per unsaved buffer); one
  // whose own name cannot be reached (decoded with U+FFFD) throws here, and the folder fails closed (2o attempt 5)
  const st = e.isSymbolicLink() ? fs.statSync(path.join(root, p), { throwIfNoEntry: false }) : e;
  if (!st) { fs.lstatSync(path.join(root, p)); return []; }
  if (!st.isDirectory()) return st.isFile() ? [p] : [];
  const real = fs.realpathSync(path.join(root, p));
  if (seen.has(real)) return [];
  seen.add(real);
  return under(root, p, seen);
});
export const mapMd = (root) => under(root, MAP).filter((p) => p.endsWith('.md') && !p.includes('/.dream-run/'));
// the ids the map's files hold; null when a file cannot be listed or read, so no id is called missing on a partial read
// (06, section 4, 4h: the altitude review)
export const mapIdsOf = (root) => { try { return new Set(mapMd(root).flatMap((f) => idsIn(decode(fs.readFileSync(path.join(root, f)))))); } catch { return null; } };

// The git folder a repo's worktrees share, found with no git call (D18). `root` is the repo's top level, as toplevel()
// gives it: a .git file (a linked worktree, a submodule) names the git folder, whose commondir names the shared one.
// Throws when root holds no .git, or a .git file names no gitdir; a gitdir that is gone is returned as it is.
// shortcut: a relative commondir is resolved without following a symlinked gitdir first, as 2.2.0's ignoreCase did;
// realpath the gitdir first if a worktree's .git names a link
export function gitDir(root) {
  let dir = path.join(root, '.git');
  if (fs.statSync(dir).isFile()) dir = path.resolve(root, /^gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dir, 'utf8'))[1]);
  try { dir = path.resolve(dir, fs.readFileSync(path.join(dir, 'commondir'), 'utf8').trim()); } catch {}
  return dir;
}
// One key per repo for the plugin's per-machine state (D32), the same from the repo and its linked worktrees: a hash
// of the shared git folder's real path as the OS gives it (a Windows 8.3 short name and its long form are one key; CI
// found the JS realpath keeps the short one), so two paths never share a key. Throws when that folder does not exist
export const repoKey = (root) => crypto.createHash('sha256').update(fs.realpathSync.native(gitDir(root))).digest('hex').slice(0, 16);

// git's core.ignorecase, read from the repo's config file, so session start keeps one git call (D18). Unset, false or
// unreadable means no fold, as in git: a name listed twice loses nothing (06, 2h).
// shortcut: global, system and included config files and config.worktree are not read; read them if a repo sets the
// value there
function ignoreCase(root) {
  try {
    const dir = gitDir(root);
    let core = false, on = false;
    for (let line of fs.readFileSync(path.join(dir, 'config'), 'utf8').split(/\r?\n/)) {
      const s = /^\s*\[([^\]]*)\](.*)$/.exec(line);
      if (s) [core, line] = [s[1].trim().toLowerCase() === 'core', s[2]];
      const kv = /^\s*ignorecase\s*(?:=\s*("?)([^"#;]*)\1)?\s*(?:[#;].*)?$/i.exec(line);
      if (core && kv) on = kv[2] === undefined || /^(true|yes|on|[+-]?0*[1-9]\d*)$/i.test(kv[2].trim());
    }
    return on;
  } catch { return false; }
}

// D22's index: the tracked documents, plus the map files not yet committed (D15), by directory. Empty with no
// documents, null outside git. Untracked files are listed for the map folder only: elsewhere they can be a whole
// unignored build tree. They are read from the folder, not from a second git call (D18's budget), so a map file
// .gitignore excludes is listed too.
export function index(root) {
  const tracked = git(root, 'ls-files', '-z', '--cached');
  if (tracked.status !== 0) return null;
  // letter case is folded as git folds it under core.ignorecase, ASCII letters only (D16's second difference; 06, 2h)
  const fold = ignoreCase(root) ? (p) => p.replace(/[A-Z]+/g, (s) => s.toLowerCase()) : (p) => p;
  // only a tracked map file can match one, so only those are folded (D18's budget)
  const known = new Set(tracked.stdout.split('\0').filter((p) => p.slice(0, MAP.length + 1).toLowerCase() === `${MAP}/`).map(fold));
  let fresh = [];
  try { fresh = under(root, MAP).filter((p) => !known.has(fold(p))).sort(); } catch {}
  const byDir = new Map();
  for (const p of [...tracked.stdout.split('\0'), ...fresh]) {
    // Claude Code loads the root's .claude/rules/ itself (unscoped at launch, paths: on a matching read, write or
    // edit), so the forced decision does not ask about it (D22's 17m, 06 2k). It loads only names that end in .md,
    // case and all (the pinned CLI's walker, 06 2m), so other documents there stay listed. shortcut: the root's folder
    // only; whether Claude Code loads a nested .claude/rules/ was not checked, so one stays listed
    if (!DOC.test(p) || (p.startsWith('.claude/rules/') && p.endsWith('.md'))) continue;
    // 06, section 3, S6: the dream's run folder is working state, never a document
    if (p.startsWith(`${MAP}/.dream-run/`)) continue;
    const i = p.lastIndexOf('/');
    const d = i < 0 ? '.' : p.slice(0, i);
    if (!byDir.has(d)) byDir.set(d, []);
    byDir.get(d).push(p.slice(i + 1));
  }
  // a control character in a committed name is printed as ?, so a path cannot add a line or break one (06, 2i)
  const safe = (s) => s.replace(/[\x00-\x1f\x7f]/g, '?');
  if (byDir.has(MAP)) byDir.set(MAP, catalog(root, byDir.get(MAP)));
  return byDir.size ? `${HEADER}\n${[...byDir].map(([d, f]) => `${safe(d)}/: ${f.map(safe).join(', ')}`).join('\n')}\n` : '';
}

// the user's local date, as YYYY-MM-DD (a review date passes when their day ends)
export const localDate = (now = new Date()) => `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
const FRONT = /^﻿?---\r?\n([\s\S]*?)\r?\n---\r?\n/;
// 06, section 3, S6 (D30): the map folder's line as a catalog once any of its files has front matter (name and
// description): such a file shows its description and counts; any other file, and a whole 2.2.0 map, its bare name
function catalog(root, files) {
  const today = localDate();
  let any = false;
  const parts = files.map((f) => {
    let t;
    try { t = decode(fs.readFileSync(path.join(root, MAP, f))); } catch { return f; }
    const fm = FRONT.exec(t);
    const desc = fm && /^name:[ \t]*\S/m.test(fm[1]) ? /^description:[ \t]*(\S.*?)[ \t]*\r?$/m.exec(fm[1])?.[1] : null;
    if (!desc) return f;
    any = true;
    const es = entries(t);
    const due = es.filter((b) => reviewOn(b) < today).length;
    const prop = es.filter(proposedOn).length;
    const d = desc.replace(/\s+/g, ' ').replace(/,\s*/g, '; ');
    const counts = `${es.length} ${es.length === 1 ? 'entry' : 'entries'}${due ? `, ${due} due` : ''}${prop ? `, ${prop} proposed` : ''}`;
    return { full: `${f} (${d.length > 80 ? `${d.slice(0, 79)}…` : d}; ${counts})`, short: `${f} (${counts})` };
  });
  if (!any) return files;
  // past 3,000 characters the descriptions go and the counts stay, so the map's line cannot crowd out the other
  // directories or pass the hook cap by itself (agy's S6 round)
  const full = parts.map((p) => (typeof p === 'string' ? p : p.full));
  return full.join(', ').length <= 3000 ? full : parts.map((p) => (typeof p === 'string' ? p : p.short));
}

// 06, section 3, S6 (D32): the plugin's per-machine state for one repo, in its data folder. The dream writes
// state.json under its lock; session start only reads it, and appends a transcript folder to dirs.log
export const stateDir = (root, data) => path.join(data, 'repos', repoKey(root));
// a state file of any other shape reads as a fresh one, so a hand edit or a partial write cannot silence the nudge
export const loadState = (dir) => {
  let s = {};
  try { s = JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')); } catch {}
  const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
  s = obj(s) ?? {};
  // a pending record needs its log line and the seen set to go back to, or a dream would stop on it (/code-review)
  const p = obj(s.pending);
  return { ...s, seen: obj(s.seen) ?? {}, lastDream: typeof s.lastDream === 'string' && !Number.isNaN(Date.parse(s.lastDream)) ? s.lastDream : null, pending: p && typeof p.line === 'string' && obj(p.prevSeen) ? p : null };
};
// the last dream's date as the user's day, the one its proposed lines carry; a state from before 2.3.0's review fixes
// has only lastDream, in UTC
export const dreamDate = (st) => (typeof st.lastDreamDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(st.lastDreamDate) ? st.lastDreamDate : st.lastDream?.slice(0, 10) ?? null);
export const knownDirs = (dir) => { try { return [...new Set(fs.readFileSync(path.join(dir, 'dirs.log'), 'utf8').split(/\r?\n/).filter(Boolean))]; } catch { return []; } };
// the inert drafts a dream wrote: .claude/rules/*.md.draft and .claude/skills/*/SKILL.md.draft (D31)
export function drafts(root) {
  const out = [];
  try { for (const f of fs.readdirSync(path.join(root, '.claude', 'rules'))) if (f.endsWith('.md.draft')) out.push(`.claude/rules/${f}`); } catch {}
  try { for (const d of fs.readdirSync(path.join(root, '.claude', 'skills'))) if (fs.existsSync(path.join(root, '.claude', 'skills', d, 'SKILL.md.draft'))) out.push(`.claude/skills/${d}/SKILL.md.draft`); } catch {}
  return out.sort();
}
// the user's line on what waits for review: proposed entries and drafts (a reminder; the drafts are never loaded)
export function waiting(root) {
  let proposed = 0;
  try { for (const f of mapMd(root)) proposed += entries(textOf(root, f)).filter(proposedOn).length; } catch {}
  const d = drafts(root).length;
  if (!proposed && !d) return '';
  const parts = [proposed ? `${proposed} proposed ${proposed === 1 ? 'entry' : 'entries'}` : '', d ? `${d} draft${d === 1 ? '' : 's'}` : ''].filter(Boolean);
  return `second-brain: waiting for review: ${parts.join(' and ')}. ${reviewStep(root)}.`;
}
// where review happens: /map-review, which only setup creates; a repo that never ran setup is pointed there first
// (the devils-advocate review)
export const reviewStep = (root) => (fs.existsSync(path.join(root, '.claude', 'skills', 'map-review', 'SKILL.md')) ? 'Run /map-review' : 'Run /second-brain:setup, which adds /map-review, then /map-review');
// a dream that holds this repo's lock: running in another session, or stopped before finish or abort (the
// devils-advocate review). Its direct writes stay in place until it is aborted
export function dreamLeft(root, data) {
  const f = path.join(stateDir(root, data), 'dream.lock');
  if (!fs.existsSync(f)) return '';
  return 'second-brain: a dream is running in another session, or stopped before it finished. If none is running, run /second-brain:dream: it offers to abort the old one.';
}
// Claude Code's transcript cleanup, in days (its user settings, default 30). shortcut: project, local and managed
// settings are not read; read them if a team sets cleanupPeriodDays there
function cleanupDays() {
  try {
    const v = JSON.parse(fs.readFileSync(path.join(configDir(), 'settings.json'), 'utf8')).cleanupPeriodDays;
    return Number.isFinite(v) && v >= 1 ? v : 30;
  } catch { return 30; }
}
// the transcripts in the known folders the dream has not read, leaving out this session's own; the nudge and the status
// report count them the same way
export const unseenIn = (dirs, seen, current = null) => dirs.flatMap((d) => {
  let names = [];
  try { names = fs.readdirSync(d); } catch {}
  return names.filter((f) => f.endsWith('.jsonl') && f !== current && !Object.hasOwn(seen, f)).map((f) => path.join(d, f));
});
// D32, the user's thresholds: a dream is due at 10 or more new sessions; or 7 or more days since the last dream with
// at least 3 new; or a session Claude Code's cleanup deletes within 5 days. A new session is a transcript in a known
// folder that the dream has not read and that is not this one. Session start learns its folder here (one line).
// shortcut: at most 50 unseen transcripts are stat'ed, in folder order, for age and expiry; stat them all, oldest
// first, if a repo collects more between dreams
export function dreamDue(root, data, transcriptPath, now = Date.now()) {
  const dir = stateDir(root, data);
  const st = loadState(dir);
  const dirs = knownDirs(dir);
  const here = transcriptPath ? path.dirname(transcriptPath) : null;
  if (here && !dirs.includes(here)) { fs.mkdirSync(dir, { recursive: true }); fs.appendFileSync(path.join(dir, 'dirs.log'), `${here}\n`); dirs.push(here); }
  const unseen = unseenIn(dirs, st.seen, transcriptPath ? path.basename(transcriptPath) : null);
  const day = 864e5;
  const keep = cleanupDays();
  let expiring = 0, oldest = now;
  for (const p of unseen.slice(0, 50)) {
    // one transcript that cannot be stat'ed (a link loop, a permission) costs only itself
    let m;
    try { m = fs.statSync(p, { throwIfNoEntry: false })?.mtimeMs; } catch {}
    if (m === undefined) continue;
    oldest = Math.min(oldest, m);
    if (m < now - (keep - 5) * day) expiring++;
  }
  const n = unseen.length;
  const days = (now - (st.lastDream ? Date.parse(st.lastDream) : oldest)) / day;
  if (!(n >= 10 || (days >= 7 && n >= 3) || expiring > 0)) return '';
  return `second-brain: a dream is due: ${n} new session${n === 1 ? '' : 's'} since ${st.lastDream ? `the dream of ${dreamDate(st)}` : 'tracking began'}`
    + `${expiring ? `; ${expiring} will be deleted by Claude Code's cleanup within 5 days` : ''}. Run /second-brain:dream.`;
}

// Session start's text. Claude Code caps a hook's added context at 10,000 characters: past it, the text goes to a
// file and Claude sees a 2,000-character preview. So a larger index is cut at a directory, and says so (D22's guard).
// When cut, the map folder's line goes first, so captured decisions stay listed (D18, the second review's J2).
export const CAP = 10_000;
const notListed = (n) => `(${n} more ${n === 1 ? 'directory' : 'directories'} not listed: session start is past the `
  + '10,000-character limit of one hook output.)';
export function startText(idx) {
  const full = idx ? `${INSTRUCTION}\n\n${idx}\n${NAME}` : `${INSTRUCTION}\n\n${NAME}`;
  let [head, ...dirs] = (idx ?? '').trimEnd().split('\n');
  if (full.length <= CAP) return { text: full, listed: dirs.length, total: dirs.length };
  const m = dirs.findIndex((l) => l.startsWith(`${MAP}/: `));
  if (m > 0) dirs = [dirs[m], ...dirs.slice(0, m), ...dirs.slice(m + 1)];
  const at = (k) => `${INSTRUCTION}\n\n${[head, ...dirs.slice(0, k)].join('\n')}\n${notListed(dirs.length - k)}\n\n${NAME}`;
  // one forward pass (J1): each directory listed adds its line and takes at most one digit off the count
  const fixed = INSTRUCTION.length + 2 + head.length + 1 + 2 + NAME.length;
  let k = 0;
  for (let used = fixed; k < dirs.length && used + dirs[k].length + 1 + notListed(dirs.length - k - 1).length <= CAP; k++) used += dirs[k].length + 1;
  return { text: at(k), listed: k, total: dirs.length };
}

// The forced decision's epoch: every session start opens one, the first prompt after it closes it. A marker file in
// the OS temp folder, so nothing is written in the repo.
const marker = (id) => path.join(os.tmpdir(), `project-map-${String(id).replace(/[^\w-]/g, '')}.pending`);
export const openEpoch = (id) => fs.writeFileSync(marker(id), '');
export function takeForce(id) {
  try { fs.unlinkSync(marker(id)); return FORCE; } catch { return ''; }
}

// A map file's entries: each '### ' block that quotes something, up to the next heading, as its text. A leading
// byte-order mark (Windows PowerShell 5.1 writes one) would hide the first entry, so it goes (D18, 2g).
export const entries = (text) => text.replace(/^﻿/, '').replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b)).map((b) => b.trim());

// D16's re-find (attempt 2's match): every stretch of three or more words between ellipses is in the file's words.
// Found where the stretch's first word starts a word of the lowercased file and the words read on from there match
// it, so the whole file is never split into words (D16, reopened 2026-10-26: the read hook's budget).
const WORD = /[\p{L}\p{N}]+/gu;
const WORD_CHAR = /[\p{L}\p{N}]/u;
export const words = (s) => String(s).toLowerCase().match(WORD) ?? [];
const startsWord = (low, i) => {
  if (i === 0) return true;
  const lo = low.charCodeAt(i - 1), hi = low.charCodeAt(i - 2);
  return !WORD_CHAR.test(lo >= 0xdc00 && lo < 0xe000 && hi >= 0xd800 && hi < 0xdc00 ? low.slice(i - 2, i) : low[i - 1]);
};
const holds = (w, low) => {
  for (let i = low.indexOf(w[0]); i >= 0; i = low.indexOf(w[0], i + 1)) {
    if (!startsWord(low, i)) continue;
    WORD.lastIndex = i;
    if (w.every((t) => WORD.exec(low)?.[0] === t)) return true;
  }
  return false;
};
export const foundIn = (quote, low) => quote.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3).every((w) => holds(w, low));
// the first path an entry's source names (it has a '/' or a document extension, so "Node.js" is not one); the source
// is text Claude wrote, so only relative paths inside the repo count. 06, 2q: none when that path lies inside
// parentheses that pair across the source, where a person's words may mention a file that is not their source
export const sourcePath = (src) => {
  const depth = [];
  let d = 0;
  for (const c of src.split('')) { if (c === ')') d--; depth.push(d); if (c === '(') d++; if (d < 0) break; }
  const paired = d === 0 && depth.length === src.length;
  for (const m of src.matchAll(/[\w.-]+(?:\/[\w.-]+)*\.\w+/g)) {
    const p = m[0].replace(/^\.\//, '');
    if ((p.includes('/') || DOC.test(p)) && !p.split('/').includes('..')) return paired && depth[m.index] > 0 ? undefined : p;
  }
};
// 06, 2n: an entry is shown when the output holds its heading line, a quote line with text, or any other line with
// text that no other entry of the file holds (a shared source or when line does not say which entry was shown).
// Runs of spaces and tabs count as one space on both sides, so filters that re-space the output still match.
const flat = (s) => s.replace(/[ \t]+/g, ' ');
function shown(all, output) {
  const out = flat(output);
  const lines = all.map((b) => [...new Set(b.split('\n').map((l) => flat(l).trim()).filter(Boolean))]);
  const count = new Map();
  for (const ls of lines) for (const l of ls) count.set(l, (count.get(l) ?? 0) + 1);
  return lines.map((ls) => ls.some((l) => (/^(### |>\s*\S)/.test(l) || (!l.startsWith('>') && count.get(l) === 1)) && out.includes(l)));
}
// D16's re-find of an entry's quote in the file its source names: true, false, or null for a file that exists but
// cannot be read, so one locked file costs no other entry its label. Each file is read once per run, lowercased
export const refinder = (root) => {
  const docs = new Map();
  return (at, quote) => {
    try {
      if (!fs.statSync(path.join(root, at), { throwIfNoEntry: false })?.isFile()) return false;
      if (!docs.has(at)) docs.set(at, decode(fs.readFileSync(path.join(root, at))).toLowerCase());
      return foundIn(quote, docs.get(at));
    } catch { return null; }
  };
};

// D14: an entry the file's HEAD version does not hold, word for word, is unreviewed; outside git, or in a file HEAD
// lacks, every entry is. D16 (reopened 2026-10-25, option b): an entry whose source names a repo file is re-found in it
// now, and one not found says so without claiming a change; any other entry carries its capture date as unverified.
// Given a command's output (06, 2o): every entry HEAD does not hold, whatever the output shows, since which entries a
// reshaped output shows cannot be told (2n's three rounds); and the committed entries it shows, by 2n's rule.
// shortcut: one git call per map file on each Bash command that names the folder; batch them (git cat-file --batch)
// if a map ever holds more than a handful of files
export function labels(root, file, output) {
  let bytes;
  // a missing file has nothing to label; any other failure throws, and the read hook labels the file as a whole
  try { bytes = fs.readFileSync(path.join(root, file)); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; }
  // a UTF-16 file printed raw loses its non-ASCII text in the decode, so an output holding a NUL shows all of it
  if (output?.includes('\0') && utf16(bytes)) output = undefined;
  const all = entries(decode(bytes));
  if (!all.length) return '';
  const head = spawnSync('git', ['show', `HEAD:./${file}`], { cwd: root, maxBuffer: 64 << 20 });
  const held = new Set(head.status === 0 ? entries(decode(head.stdout)) : []);
  const seen = output === undefined ? null : shown(all, output);
  const picked = all.map((b, i) => !seen || !held.has(b) || seen[i]);
  const refind = refinder(root);
  // 06, section 3, S3 (D30): the ids every map file holds, read only when a status line names one
  let ids;
  const mapIds = () => (ids === undefined ? (ids = mapIdsOf(root)) : ids);
  // the user's local date, so a review date passes when their day ends (agy's S3 round)
  const today = localDate();
  // 06, 2p: a committed entry whose only label is "unverified quote" joins one line of ranges (D16's content kept)
  const plain = [];
  const out = all.flatMap((b, i) => {
    if (!picked[i]) return [];
    const src = /^- source:(.*)$/m.exec(b)?.[1] ?? '';
    const date = /(\d{4}-\d{2}-\d{2})\s*$/.exec(src)?.[1];
    const at = sourcePath(src);
    const ls = held.has(b) ? [] : [UNREVIEWED];
    // 06, 2r (D28's L): a status line's own head, so an output that shows the entry without that line still says it;
    // never "ended", since a narrowed entry binds in part
    const status = statusOf(b);
    const cut = status?.lastIndexOf(' ', 60);
    if (status) ls.push(`status: ${status.length <= 60 ? status : `${status.slice(0, cut > 0 ? cut : 60)}…`}`);
    // 06, section 3, S3 (D30): lines no 2.2.0 map holds. A dream's proposal until review accepts it; a review date
    // that has passed; a status line naming an id that no map file holds, in a map that has ids at all
    const proposed = proposedOn(b);
    if (proposed) ls.push(`proposed by a dream ${proposed}, not yet accepted`);
    const review = reviewOn(b);
    if (review && review < today) ls.push(`review due since ${review}`);
    const by = replacedBy(status);
    if (by && mapIds()?.size && !mapIds().has(by)) ls.push(`replaced by ${by}, which the map does not hold`);
    if (!at) ls.push(`unverified quote${date ? `, captured ${date}` : ''}`);
    else {
      const found = refind(at, quoteOf(b));
      if (found === null) ls.push(`cannot read ${at}; check it${date ? `, captured ${date}` : ''}`);
      else if (!found) ls.push(`not found word for word in ${at}; check it${date ? `, captured ${date}` : ''}`);
    }
    if (!ls.length) return [];
    const line = `${i + 1}. ${b.split('\n')[0].slice(4)}: ${ls.join('; ')}`;
    if (ls.length === 1 && ls[0].startsWith('unverified quote')) plain.push({ i, date, line });
    return [line];
  });
  const runs = [];
  for (const { i, date } of plain) {
    const r = runs.at(-1);
    if (r && date && r.date === date && r.to === i - 1) r.to = i; else runs.push({ from: i, to: i, date });
  }
  const grouped = runs.length ? `unverified quote, committed: entries ${runs.map((r) => `${r.from + 1}${r.to > r.from ? `-${r.to + 1}` : ''}${r.date ? ` (captured ${r.date})` : ''}`).join(', ')}` : '';
  if (!out.length) return '';
  // the note follows the list: before it, Claude paraphrased the labels (06, 2n attempt 3's smoke)
  const note = (ls) => (ls.some((l) => l.includes('unverified quote')) ? `${UNVERIFIED_NOTE}\n` : '');
  const top = `[project map] Labels on the entries of ${file}${output === undefined ? '' : ' not yet committed, and on those this output shows'}, in file order:\n`;
  // grouped only when the whole text fits; past the cap the output is 2.0.0's (06, 2p attempt 2)
  const solo = new Set(plain.map((p) => p.line));
  const short = grouped ? [grouped, ...out.filter((l) => !solo.has(l))] : out;
  const brief = `${top}${short.join('\n')}\n${note(short)}`;
  if (brief.length <= CAP) return brief;
  // past the cap, Claude would see only a preview, so the labels are cut at a line and the rest fail closed (D18, J3)
  const tail = (k, n = out.length - k) => (k ? `(${n} more ${n === 1 ? 'label' : 'labels'} not shown: treat every entry after entry ${parseInt(out[k - 1], 10)} `
    : `(${n} ${n === 1 ? 'label' : 'labels'} not shown: treat every entry `) + 'in this file as unreviewed and unverified.)\n';
  const whole = `${top}${out.join('\n')}\n${note(out)}`;
  if (whole.length <= CAP) return whole;
  let k = 0;
  for (let used = top.length + note(out).length; k < out.length && used + out[k].length + 1 + tail(k + 1).length <= CAP; k++) used += out[k].length + 1;
  // the note goes when no line it explains is left, which only shortens the text
  return `${top}${out.slice(0, k).map((l) => `${l}\n`).join('')}${tail(k)}${note(out.slice(0, k))}`;
}
