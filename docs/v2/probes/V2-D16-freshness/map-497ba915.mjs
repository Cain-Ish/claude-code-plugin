// V2-D16 before its re-lock of 2026-10-26 (plugin 497ba915e987), kept so equivalence.mjs can compare against it.
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

// D22's index: the tracked documents, plus the map files not yet committed (D15), by directory. Empty with no
// documents, null outside git. Untracked files are listed for the map folder only: elsewhere they can be a whole
// unignored build tree.
export function index(root) {
  const tracked = git(root, ['ls-files', '-z', '--cached']);
  if (tracked.status !== 0) return null;
  const fresh = git(root, ['ls-files', '-z', '--others', '--exclude-standard', '--', MAP]).stdout ?? '';
  const byDir = new Map();
  for (const p of `${tracked.stdout}\0${fresh}`.split('\0')) {
    if (!DOC.test(p)) continue;
    const i = p.lastIndexOf('/');
    const d = i < 0 ? '.' : p.slice(0, i);
    if (!byDir.has(d)) byDir.set(d, []);
    byDir.get(d).push(p.slice(i + 1));
  }
  return byDir.size ? `${HEADER}\n${[...byDir].map(([d, f]) => `${d}/: ${f.join(', ')}`).join('\n')}\n` : '';
}

// The forced decision's epoch: every session start opens one, the first prompt after it closes it. A marker file in
// the OS temp folder, so nothing is written in the repo.
const marker = (id) => path.join(os.tmpdir(), `project-map-${String(id).replace(/[^\w-]/g, '')}.pending`);
export const openEpoch = (id) => fs.writeFileSync(marker(id), '');
export function takeForce(id) {
  try { fs.unlinkSync(marker(id)); return FORCE; } catch { return ''; }
}

// A map file's entries: each '### ' block that quotes something, up to the next heading, as its text.
const entries = (text) => text.replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b)).map((b) => b.trim());

// D16's re-find (attempt 2's match): every stretch of three or more words between ellipses is in the file's words
const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const foundIn = (quote, text) => {
  const norm = ` ${words(text).join(' ')} `;
  return quote.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3).every((w) => norm.includes(` ${w.join(' ')} `));
};
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
  try { text = fs.readFileSync(path.join(root, file), 'utf8'); } catch { return ''; }
  const head = git(root, ['show', `HEAD:./${file}`]);
  const held = new Set(head.status === 0 ? entries(head.stdout) : []);
  const docs = new Map();
  const doc = (p) => { if (!docs.has(p)) docs.set(p, fs.readFileSync(path.join(root, p), 'utf8')); return docs.get(p); };
  const out = entries(text).flatMap((b, i) => {
    const src = /^- source:(.*)$/m.exec(b)?.[1] ?? '';
    const date = /(\d{4}-\d{2}-\d{2})\s*$/.exec(src)?.[1];
    const quote = b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n');
    const at = sourcePath(src);
    const ls = held.has(b) ? [] : [UNREVIEWED];
    if (!at) ls.push(`unverified quote${date ? `, captured ${date}` : ''}`);
    else if (!isFile(root, at) || !foundIn(quote, doc(at))) ls.push(`not found word for word in ${at}; check it${date ? `, captured ${date}` : ''}`);
    return ls.length ? [`${i + 1}. ${b.split('\n')[0].slice(4)}: ${ls.join('; ')}`] : [];
  });
  return out.length ? `[project map] Labels on the entries of ${file}, in file order:\n${out.join('\n')}\n` : '';
}
