// V2-D18 hook library, attempt 2: self-contained, with no import of the other probes (production bundles it; bench.mjs
// asserts each copied piece equals its original). The cache is built from the committed Markdown map, never the
// reverse. Every delivery carries D16's re-find and D14's label on uncommitted entries. Hooks spawn only git. A
// session started with V2_NESTED=1 (the onboarding converter) gets no hook work at all.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

export const MAP = '.project-map';
export const CAP = 8 * 1024;
const CACHE = path.join(MAP, '.cache');

export function nestedExit() { if (process.env.V2_NESTED === '1') process.exit(0); }
export const readInput = () => JSON.parse(fs.readFileSync(0, 'utf8'));
export const rel = (cwd, p) => path.relative(cwd, String(p ?? '')).replace(/\\/g, '/');
export const emit = (ev, text) => { if (text) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };

// ---- copied: D14's capture instruction (bench asserts its hash) ----

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

// ---- copied: D16's re-find ----

const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const stretches = (q) => q.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3).map((w) => w.join(' '));
export const normOf = (text) => ` ${words(text).join(' ')} `;
const spanRe = (stretch, flags = 'iu') => new RegExp(stretch.split(' ').map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^\\p{L}\\p{N}]+'), flags);
const headerLineAbove = (text, at) => {
  const lines = text.slice(0, at).split('\n');
  let i = lines.length - 1;
  if (!lines[i].trimStart().startsWith('|')) return null;
  while (i > 0 && lines[i - 1].trimStart().startsWith('|')) i--;
  const start = lines.slice(0, i).join('\n').length + (i ? 1 : 0);
  return { start, line: text.slice(start).split('\n')[0] };
};
const paragraphAt = (text, at) => { const a = text.lastIndexOf('\n\n', at); const b = text.indexOf('\n\n', at); return text.slice(a < 0 ? 0 : a, b < 0 ? text.length : b); };
export function foundIn(e, text, norm) {
  const st = stretches(e.quote);
  if (!st.every((x) => norm.includes(` ${x} `))) return false;
  if (!e.context) return true;
  const m = st.length ? spanRe(st[0]).exec(text) : null;
  if (!m) return false;
  if (e.context.startsWith('|')) return words(headerLineAbove(text, m.index)?.line).join(' ') === words(e.context).join(' ');
  return normOf(paragraphAt(text, m.index)).includes(` ${words(e.context).join(' ')} `);
}

// ---- copied: D22's keys ----

export function tokensOf(term) {
  return (String(term).match(/[\w.*\-/]+/g) ?? [])
    .map((t) => t.replace(/^\.?\/+/, '').replace(/[.]+$/, ''))
    .filter((t) => t.length > 2 && !/^https?/.test(t) && (t.includes('/') || t.includes('*') || /\.[a-z][a-z0-9]{0,5}$/i.test(t)));
}
function tokenMatch(token, file) {
  const base = file.split('/').pop();
  if (token.includes('*')) {
    const re = new RegExp(`^${token.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\/?/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*')}$`);
    return token.includes('/') ? (re.test(file) ? 2 : -1) : (re.test(base) ? 3 : -1);
  }
  if (token.includes('/')) {
    const t = token.replace(/\/$/, '');
    return file === t ? 0 : file.startsWith(`${t}/`) ? 1 : -1;
  }
  return base === token ? 0 : -1;
}
// most specific first; ties keep map order
export function keyedFor(keyed, file) {
  const best = new Map();
  for (const [id, token] of keyed) {
    const s = tokenMatch(token, file);
    if (s >= 0 && (!best.has(id) || s < best.get(id))) best.set(id, s);
  }
  return [...best].sort((a, b) => a[1] - b[1]).map(([id]) => id);
}

// ---- the Markdown map: D15's render and parse, plus D16's verified line and D14's source line ----

export const render = (file, es) => {
  let out = `# Map entries from ${file}\n`;
  let last = null;
  for (const e of es) {
    const h = e.heads.join(' › ') || '(top)';
    if (h !== last) { out += `\n## ${h}\n`; last = h; }
    out += `\n### ${e.area}\n${e.quote.split('\n').map((l) => `> ${l}`).join('\n')}\n\n${e.context ? `- context: ${e.context}\n` : ''}- when: ${JSON.stringify(e.when)}\n- blocks: ${e.blocks.join(', ')}\n- verified: ${e.verified ? 'yes' : 'no'}, ${e.date}\n`;
  }
  return out;
};
// an entry without a verified line (D14's captured entries, from no repo file) is unverified, dated by its source line
export function parseMap(file, text) {
  const out = [];
  let heads = [];
  let cur = null;
  for (const l of text.replace(/\r/g, '').split('\n')) {
    if (l.startsWith('## ')) heads = l.slice(3) === '(top)' ? [] : l.slice(3).split(' › ');
    else if (l.startsWith('### ')) out.push(cur = { file, heads, area: l.slice(4), quote: null, when: [], blocks: [], verified: false, date: null });
    else if (cur && /^> ?/.test(l)) cur.quote = cur.quote === null ? l.replace(/^> ?/, '') : `${cur.quote}\n${l.replace(/^> ?/, '')}`;
    else if (cur && l.startsWith('- context: ')) cur.context = l.slice(11);
    else if (cur && l.startsWith('- when: ')) { try { cur.when = JSON.parse(l.slice(8)); } catch { cur.when = []; } }
    else if (cur && l.startsWith('- blocks: ')) cur.blocks = l.slice(10).split(', ').map(Number);
    else if (cur && l.startsWith('- verified: ')) { const [v, d] = l.slice(12).split(', '); cur.verified = v === 'yes'; cur.date = d ?? null; }
    else if (cur && l.startsWith('- source: ')) cur.date = l.match(/(\d{4}-\d{2}-\d{2})\s*$/)?.[1] ?? cur.date;
  }
  return out.filter((e) => e.quote !== null);
}

// ---- the cache ----
// A build writes a new version folder and then points `current` at it, so a hook reading during a concurrent build
// sees one whole version. Versions older than a minute are removed; no hook runs that long.

const shardName = (source) => `${crypto.createHash('sha1').update(source).digest('hex').slice(0, 16)}.json`;
const writeAtomic = (f, s) => { const t = `${f}.${process.pid}.tmp`; fs.writeFileSync(t, s); fs.renameSync(t, f); };
function walk(root) {
  const files = [];
  let newest = 0;
  const go = (d) => {
    newest = Math.max(newest, fs.statSync(d).mtimeMs);
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) { if (e.name !== '.cache') go(f); } else if (f.endsWith('.md')) { files.push(f); newest = Math.max(newest, fs.statSync(f).mtimeMs); }
    }
  };
  if (fs.existsSync(path.join(root, MAP))) go(path.join(root, MAP));
  return { files, newest };
}
const current = (root) => { try { return path.join(root, CACHE, fs.readFileSync(path.join(root, CACHE, 'current'), 'utf8')); } catch { return null; } };

export function buildCache(root, files = walk(root).files) {
  const started = Date.now();
  const name = `v${started}-${process.pid}`;
  const dir = path.join(root, CACHE, name);
  fs.mkdirSync(path.join(dir, 'byfile'), { recursive: true });
  if (!fs.existsSync(path.join(root, CACHE, '.gitignore'))) writeAtomic(path.join(root, CACHE, '.gitignore'), '*\n');
  const keyed = [];
  for (const f of files) {
    const mapRel = rel(root, f);
    const source = mapRel.slice(MAP.length + 1, -3);
    const es = parseMap(source, fs.readFileSync(f, 'utf8')).map((e, i) => ({ ...e, map: mapRel, i }));
    fs.writeFileSync(path.join(dir, 'byfile', shardName(source)), JSON.stringify(es));
    es.forEach((e, i) => { for (const t of new Set(e.when.flatMap(tokensOf))) keyed.push([`${source}#${i}`, t]); });
  }
  fs.writeFileSync(path.join(dir, 'keys.json'), JSON.stringify(keyed));
  fs.writeFileSync(path.join(dir, 'open.json'), JSON.stringify(uncommitted(root)));
  const stamp = path.join(root, CACHE, 'stamp');
  try {
    writeAtomic(path.join(root, CACHE, 'current'), name);
    writeAtomic(stamp, name);
    fs.utimesSync(stamp, new Date(started), new Date(started));
  } catch { /* a concurrent build won the pointer; its version is complete too */ }
  for (const v of fs.readdirSync(path.join(root, CACHE))) {
    const m = /^v(\d+)-/.exec(v);
    if (m && v !== name && Number(m[1]) < started - 60_000) try { fs.rmSync(path.join(root, CACHE, v), { recursive: true, force: true }); } catch { /* in use; the next build retries */ }
  }
}
// The cache (and the uncommitted set with it) is rebuilt when a map file or folder is newer than the stamp: a new or
// edited entry changes its file, a deleted file its folder. A commit changes neither, so its entries stay labelled
// until the next session start, which always rebuilds the uncommitted set (the safe direction).
export function refresh(root, sessionStart = false) {
  let stamp = -1;
  try { stamp = fs.statSync(path.join(root, CACHE, 'stamp')).mtimeMs; } catch { /* no cache yet */ }
  const w = walk(root);
  if (stamp < 0 || w.newest > stamp || !current(root)) buildCache(root, w.files);
  else if (sessionStart) writeAtomic(path.join(current(root), 'open.json'), JSON.stringify(uncommitted(root)));
}
export function shard(root, source) {
  try { return JSON.parse(fs.readFileSync(path.join(current(root), 'byfile', shardName(source)), 'utf8')); } catch { return []; }
}
const keys = (root) => { try { return JSON.parse(fs.readFileSync(path.join(current(root), 'keys.json'), 'utf8')); } catch { return []; } };

// the entries a read or write of this file brings: a document's own entries, then keyed matches (D22 run 3)
export function entriesFor(root, file) {
  const own = shard(root, file);
  const shards = new Map([[file, own]]);
  const keyed = keyedFor(keys(root), file).map((id) => {
    const at = id.lastIndexOf('#');
    const src = id.slice(0, at);
    if (!shards.has(src)) shards.set(src, shard(root, src));
    return shards.get(src)[Number(id.slice(at + 1))];
  });
  return [...own, ...keyed].filter(Boolean);
}

// ---- the guards ----

const keyOf = (e) => `${e.area}\n${e.quote}`;
// D14: per uncommitted map file, the entries its HEAD version holds (null for a file HEAD does not have). An entry is
// unreviewed when its file is listed here and HEAD does not hold it.
export function uncommitted(root) {
  const r = spawnSync('git', ['status', '--porcelain=v1', '-z', '-uall', '--', MAP], { cwd: root, encoding: 'utf8' });
  const parts = (r.stdout ?? '').split('\0');
  const out = {};
  for (let i = 0; i < parts.length; i++) {
    const [xy, p] = [parts[i].slice(0, 2), parts[i].slice(3)];
    if (/[RC]/.test(xy)) i++;
    if (!p.endsWith('.md') || p.includes('/.cache/') || xy.includes('D')) continue;
    const head = spawnSync('git', ['show', `HEAD:${p}`], { cwd: root, encoding: 'utf8' });
    out[p] = head.status === 0 ? parseMap('', head.stdout).map(keyOf) : null;
  }
  return out;
}
const openOf = (root) => { try { return JSON.parse(fs.readFileSync(path.join(current(root), 'open.json'), 'utf8')); } catch { return null; } };

// D16: verified entries are re-found in their own file, then in the map's other sources (moved: delivered as current,
// re-anchored); changed and gone are labelled with their date. Unverified entries carry their date and never read as stale.
// shortcut: "other sources" are the files the map has entries for; a quote moved into a document the map never
// converted reads as changed. Upgrade when onboarding keeps its own list of converted files.
export function deliver(root, entries, cap = CAP) {
  const open = openOf(root);
  const docs = new Map();
  const doc = (f) => {
    if (!docs.has(f)) { let t = null; try { t = fs.readFileSync(path.join(root, f), 'utf8'); } catch { /* gone */ } docs.set(f, t === null ? null : { t, n: normOf(t) }); }
    return docs.get(f);
  };
  let sources = null;
  const movedTo = (e) => {
    if (!sources) sources = walk(root).files.map((f) => rel(root, f).slice(MAP.length + 1, -3));
    return sources.find((s) => { if (s === e.file) return false; const d = doc(s); return d && foundIn(e, d.t, d.n); });
  };
  const out = [];
  let used = 0;
  for (const e of entries) {
    if (used + Buffer.byteLength(e.quote) > cap) continue;
    const labels = [];
    // without the uncommitted set every entry is labelled: never delivered unlabelled by a missing cache
    if (!open || (e.map in open && !(open[e.map] ?? []).includes(keyOf(e)))) labels.push('unreviewed, not yet committed');
    let file = e.file;
    if (!e.verified) labels.push(`unverified quote${e.date ? `, captured ${e.date}` : ''}`);
    else {
      const d = doc(e.file);
      if (!(d && foundIn(e, d.t, d.n))) {
        const m = movedTo(e);
        if (m) file = m;
        else labels.push(`source changed since ${e.date}; check ${e.file}`);
      }
    }
    const block = `${file}${e.heads.length ? ` › ${e.heads.join(' › ')}` : ''}${labels.length ? ` [${labels.join('; ')}]` : ''}\n${e.context ? `${e.context}\n` : ''}${e.quote}\n`;
    const b = Buffer.byteLength(block);
    if (used + b > cap) continue;
    out.push({ block, labels });
    used += b;
  }
  return out;
}
