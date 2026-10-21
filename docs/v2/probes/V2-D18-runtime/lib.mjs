// V2-D18 prototype hook library: the cache built from the committed Markdown map, keyed lookup (D22 run 3), and the
// two guards every delivery carries: D16's re-find (stale entries labelled) and D14's label on entries whose map file
// is not yet committed. Hooks spawn only git. A session started with V2_NESTED=1 (the onboarding converter) gets no hook
// work at all.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { keyedFor, tokensOf } from '../V2-D22-selection/keys.mjs';
import { foundIn, normOf } from '../V2-D16-freshness/fresh.mjs';
import { parseMap } from '../V2-D15-onboarding/onboard.mjs';

export const MAP = '.project-map';
export const CAP = 8 * 1024;
const CACHE = path.join(MAP, '.cache');
const shardName = (file) => `${crypto.createHash('sha1').update(file).digest('hex').slice(0, 16)}.json`;

export function nestedExit() { if (process.env.V2_NESTED === '1') process.exit(0); }
export const readInput = () => JSON.parse(fs.readFileSync(0, 'utf8'));
export const rel = (cwd, p) => path.relative(cwd, String(p ?? '')).replace(/\\/g, '/');

// ---- the cache: rebuilt from the Markdown, never the reverse ----

const mapFiles = (root) => {
  const out = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) { if (e.name !== '.cache') walk(f); } else if (f.endsWith('.md')) out.push(f); } };
  if (fs.existsSync(path.join(root, MAP))) walk(path.join(root, MAP));
  return out;
};
export function buildCache(root) {
  const dir = path.join(root, CACHE, 'byfile');
  fs.rmSync(path.join(root, CACHE), { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(root, CACHE, '.gitignore'), '*\n');
  const keys = [];
  for (const f of mapFiles(root)) {
    const mapRel = rel(root, f);
    const source = mapRel.slice(MAP.length + 1, -3);
    const es = parseMap(source, fs.readFileSync(f, 'utf8')).map((e, i) => ({ ...e, map: mapRel, i }));
    fs.writeFileSync(path.join(dir, shardName(source)), JSON.stringify(es));
    es.forEach((e, i) => { for (const t of new Set(e.when.flatMap(tokensOf))) keys.push([`${source}#${i}`, t]); });
  }
  fs.writeFileSync(path.join(root, CACHE, 'keys.json'), JSON.stringify(keys));
  fs.writeFileSync(path.join(root, CACHE, 'stamp'), String(Date.now()));
}
export function cacheStale(root) {
  const stamp = path.join(root, CACHE, 'stamp');
  if (!fs.existsSync(stamp)) return true;
  const t = fs.statSync(stamp).mtimeMs;
  return mapFiles(root).some((f) => fs.statSync(f).mtimeMs > t);
}
export function shard(root, source) {
  const f = path.join(root, CACHE, 'byfile', shardName(source));
  return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : [];
}
export const keys = (root) => JSON.parse(fs.readFileSync(path.join(root, CACHE, 'keys.json'), 'utf8'));

// the entries a read or write of this file brings: a document's own entries, then keyed matches (D22 run 3)
export function entriesFor(root, file) {
  const own = shard(root, file);
  const shards = new Map([[file, own]]);
  const keyed = keyedFor(keys(root).map(([id, t]) => [id, t]), file).map((id) => {
    const [src, i] = [id.slice(0, id.lastIndexOf('#')), Number(id.slice(id.lastIndexOf('#') + 1))];
    if (!shards.has(src)) shards.set(src, shard(root, src));
    return shards.get(src)[i];
  });
  return [...own, ...keyed].filter(Boolean);
}

// ---- the guards ----

// D14: map files with uncommitted changes; their entries are delivered as unreviewed
export function uncommittedMaps(root) {
  const r = spawnSync('git', ['status', '--porcelain', '-uall', '--', MAP], { cwd: root, encoding: 'utf8' });
  return new Set((r.stdout ?? '').split('\n').filter(Boolean).map((l) => l.slice(3).replace(/^"|"$/g, '')));
}
// D16: an entry's quote re-found in its source; stale entries keep their text and say so
export function deliver(root, entries, cap = CAP) {
  const open = uncommittedMaps(root);
  const norms = new Map();
  const text = (f) => { if (!norms.has(f)) { const p = path.join(root, f); const t = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null; norms.set(f, t === null ? null : { t, n: normOf(t) }); } return norms.get(f); };
  const out = [];
  let used = 0;
  for (const e of entries) {
    const src = text(e.file);
    const fresh = src !== null && foundIn(e, src.t, src.n);
    const labels = [...(open.has(e.map) ? ['unreviewed, not yet committed'] : []), ...(fresh ? [] : [`source changed; check ${e.file}`])];
    const block = `${e.file}${e.heads.length ? ` › ${e.heads.join(' › ')}` : ''}${labels.length ? ` [${labels.join('; ')}]` : ''}\n${e.context ? `${e.context}\n` : ''}${e.quote}\n`;
    const b = Buffer.byteLength(block);
    if (used + b > cap) continue;
    out.push({ block, labels });
    used += b;
  }
  return out;
}
export const emit = (ev, text) => { if (text) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: text } })); };
