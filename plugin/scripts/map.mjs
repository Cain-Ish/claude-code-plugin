// The project map's hook library (V2-D14, D16, D18, D22). No model and no network: hooks spawn only git, and no map
// text reaches a process.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const MAP = '.project-map';

// D14's capture instruction, frozen: its sha256 is in the ledger, and D17's capture arm ran on this text
export const INSTRUCTION = `This project keeps a map of its knowledge in the folder .project-map/. When, during your work, someone states a
decision or rule for this project, or you receive or read a document that states requirements, specifications or
rules the project's work must follow, add each one to .project-map/captured.md as its own entry, in the words used,
with its source. Keep what will still matter in later sessions; leave out one-off details of the current task.
Entry format:

### <the part of the project it governs>
> <the decision, rule or requirement, in the words used>

- source: <who stated it, or the document's title or path>, <date>
- when: ["<kind of work it applies to>", "..."]

Never write session ids, email addresses or absolute file paths into an entry. The map is plain files in this
repository: your changes to it stay in the working tree and are reviewed with the commit, like any other change.`;

// D22: Vercel's instruction with its scope adapted, fixed before the pull check ran; then the documents by directory
export const HEADER = 'IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for any task in this project. '
  + "This project's documents, by directory:";

// D22's forced decision, at the first prompt of each epoch
export const FORCE = 'Before you start: for each directory in this project\'s document index, state in one line whether its '
  + 'documents bear on this task (yes or no). Then read the documents in every directory you marked yes before you '
  + 'change anything.';

// V2-D23: A1 item (5), the decisions followed and their sources, named when Claude finishes; frozen with D23's check
export const NAME = 'When you finish, name each of this project\'s recorded decisions you followed and its source, as the '
  + 'map entry or document gives it. Do not name a decision you did not follow, or a source the record does not give.';

export const UNREVIEWED = 'unreviewed, not yet committed';

const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const git = (root, args) => spawnSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
export const rel = (root, p) => path.relative(root, String(p ?? '')).replace(/\\/g, '/');

// The repo's root: the nearest folder at or above where Claude started that holds .git (a folder, or a worktree's
// file), so a session started in a subdirectory still sees the whole index and labels the root's map (D18, 2g)
export function toplevel(dir) {
  for (let d = path.resolve(dir); ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, '.git'))) return d;
    if (path.dirname(d) === d) return path.resolve(dir);
  }
}

// the files under the map folder, as repo paths in git's order; a symlink counts as a file, as git lists it
const under = (root, d) => fs.readdirSync(path.join(root, d), { withFileTypes: true })
  .flatMap((e) => (e.isDirectory() ? under(root, `${d}/${e.name}`) : [`${d}/${e.name}`]));

// D22's index: the tracked documents, plus the map files not yet committed (D15), by directory. Empty with no
// documents, null outside git. Untracked files are listed for the map folder only: elsewhere they can be a whole
// unignored build tree. They are read from the folder, not from a second git call (D18's budget), so a map file
// .gitignore excludes is listed too.
export function index(root) {
  const tracked = git(root, ['ls-files', '-z', '--cached']);
  if (tracked.status !== 0) return null;
  // letter case is ignored where the file system ignores it, as git's core.ignorecase does (D16's second difference)
  const fold = ['win32', 'darwin'].includes(process.platform) ? (p) => p.toLowerCase() : (p) => p;
  const known = new Set(tracked.stdout.split('\0').map(fold));
  let fresh = [];
  try { fresh = under(root, MAP).filter((p) => !known.has(fold(p))).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)); } catch {}
  const byDir = new Map();
  for (const p of [...tracked.stdout.split('\0'), ...fresh]) {
    if (!DOC.test(p)) continue;
    const i = p.lastIndexOf('/');
    const d = i < 0 ? '.' : p.slice(0, i);
    if (!byDir.has(d)) byDir.set(d, []);
    byDir.get(d).push(p.slice(i + 1));
  }
  return byDir.size ? `${HEADER}\n${[...byDir].map(([d, f]) => `${d}/: ${f.join(', ')}`).join('\n')}\n` : '';
}

// Session start's text. Claude Code caps a hook's added context at 10,000 characters: past it, the text goes to a
// file and Claude sees a 2,000-character preview. So a larger index is cut at a directory, and says so (D22's guard).
export const CAP = 10_000;
export function startText(idx) {
  const full = idx ? `${INSTRUCTION}\n\n${idx}\n${NAME}` : `${INSTRUCTION}\n\n${NAME}`;
  const [head, ...dirs] = (idx ?? '').trimEnd().split('\n');
  if (full.length <= CAP) return { text: full, listed: dirs.length, total: dirs.length };
  const at = (k) => `${INSTRUCTION}\n\n${[head, ...dirs.slice(0, k)].join('\n')}\n(${dirs.length - k} more directories `
    + 'not listed: the index is past the 10,000-character limit of one hook output.)\n\n' + NAME;
  let k = dirs.length;
  while (k > 0 && at(k).length > CAP) k--;
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
const entries = (text) => text.replace(/^﻿/, '').replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b)).map((b) => b.trim());

// D16's re-find (attempt 2's match): every stretch of three or more words between ellipses is in the file's words.
// Found where the stretch's first word starts a word of the lowercased file and the words read on from there match
// it, so the whole file is never split into words (D16, reopened 2026-10-26: the read hook's budget).
const WORD = /[\p{L}\p{N}]+/gu;
const WORD_CHAR = /[\p{L}\p{N}]/u;
const words = (s) => String(s).toLowerCase().match(WORD) ?? [];
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
const foundIn = (quote, low) => quote.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3).every((w) => holds(w, low));
// the first path an entry's source names (it has a '/' or a document extension, so "Node.js" is not one); the source
// is text Claude wrote, so only relative paths inside the repo count
const sourcePath = (src) => (src.match(/[\w.-]+(?:\/[\w.-]+)*\.\w+/g) ?? []).map((p) => p.replace(/^\.\//, ''))
  .find((p) => (p.includes('/') || DOC.test(p)) && !p.split('/').includes('..'));
const isFile = (root, p) => fs.statSync(path.join(root, p), { throwIfNoEntry: false })?.isFile();

// D14: an entry the file's HEAD version does not hold, word for word, is unreviewed; outside git, or in a file HEAD
// lacks, every entry is. D16 (reopened 2026-10-25, option b): an entry whose source names a repo file is re-found in it
// now, and one not found says so without claiming a change; any other entry carries its capture date as unverified.
export function labels(root, file) {
  let text;
  // a missing file has nothing to label; any other failure throws, and the read hook labels the file as a whole
  try { text = fs.readFileSync(path.join(root, file), 'utf8'); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; }
  const head = git(root, ['show', `HEAD:./${file}`]);
  const held = new Set(head.status === 0 ? entries(head.stdout) : []);
  const docs = new Map();
  const doc = (p) => { if (!docs.has(p)) docs.set(p, fs.readFileSync(path.join(root, p), 'utf8').toLowerCase()); return docs.get(p); };
  const out = entries(text).flatMap((b, i) => {
    const src = /^- source:(.*)$/m.exec(b)?.[1] ?? '';
    const date = /(\d{4}-\d{2}-\d{2})\s*$/.exec(src)?.[1];
    const quote = b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n');
    const at = sourcePath(src);
    const ls = held.has(b) ? [] : [UNREVIEWED];
    if (!at) ls.push(`unverified quote${date ? `, captured ${date}` : ''}`);
    else {
      // a source that exists but cannot be read gets its own label, so one locked file costs no other entry its label
      let found;
      try { found = isFile(root, at) && foundIn(quote, doc(at)); } catch { found = null; }
      if (found === null) ls.push(`cannot read ${at}; check it${date ? `, captured ${date}` : ''}`);
      else if (!found) ls.push(`not found word for word in ${at}; check it${date ? `, captured ${date}` : ''}`);
    }
    return ls.length ? [`${i + 1}. ${b.split('\n')[0].slice(4)}: ${ls.join('; ')}`] : [];
  });
  return out.length ? `[project map] Labels on the entries of ${file}, in file order:\n${out.join('\n')}\n` : '';
}
