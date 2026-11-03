// V2-D22, step 17m (registered in DECISIONS.md, D22, 2026-11-03): (S-b) again, on the repo that fired D22's paths:
// trigger, beside Claude Code's own path delivery. Reads the user's main-session transcripts; runs nothing.
//   node field-scope.mjs <repo> <out.json> [--count] <session.jsonl>...   --count prints only events and pairs
//   node field-scope.mjs selftest
// Counts go to stdout; the per-event record goes to <out.json> (research/raw/, gitignored: it holds file paths).
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { matchB, globs, globRe, median } from '../V2-D22-selection/scope-probe.mjs';

const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const MAP = /(^|\/)\.project-map\//;
const WRITES = new Set(['Write', 'Edit', 'MultiEdit']);
const MAX_DOCS = 4, MAX_BYTES = 40 * 1024; // the scope probe's bar
const EXCLUDE = [Date.parse('2026-10-26T11:35:00Z'), Date.parse('2026-10-26T12:31:00Z')]; // D22 rethink 4, unreleased
const slash = (p) => String(p ?? '').replace(/\\/g, '/');

// Front matter, as the scope probe splits it.
const frontMatter = (text) => (text.replace(/\r/g, '').match(/^---\n([\s\S]*?)\n---\n?/) ?? [])[1] ?? '';
// Claude Code's reading of a paths: entry, from its own deliveries in this corpus: a bare folder covers everything
// under it (11 of 97 deliveries are explained only so); a glob matches the file or a folder above it.
export const covers = (g, f) => (!/[*?[{]/.test(g) ? f === g.replace(/\/$/, '') || f.startsWith(`${g.replace(/\/$/, '')}/`)
  : globRe(g).test(f) || globRe(`${g.replace(/\/$/, '')}/**`).test(f));
export const declared = (doc, file) => globs(frontMatter(doc.text)).some((g) => covers(g, file));

// Walk one main-session transcript: gate events as the scope probe defines them (each main-session code write, first
// in its directory in its epoch; documents and the map left out), each with what was Read and what Claude Code
// delivered (nested_memory) earlier in that epoch, the write's kind from its tool result, and the deliveries that
// came with the write (after it, before the next assistant message).
export function walk(recs, rel) {
  const results = new Map();
  for (const r of recs) for (const x of Array.isArray(r.message?.content) ? r.message.content : []) {
    if (x.type === 'tool_result') results.set(x.tool_use_id, typeof x.content === 'string' ? x.content : JSON.stringify(x.content ?? ''));
  }
  const out = []; let epoch = 0, read = new Set(), delivered = new Set(), seen = new Set(), open = [];
  for (const r of recs) {
    if (r.isSidechain) continue;
    if (r.type === 'system' && r.subtype === 'compact_boundary') { epoch++; read = new Set(); delivered = new Set(); open = []; continue; }
    if (r.attachment?.type === 'nested_memory') {
      const p = rel(r.attachment.content?.path ?? r.attachment.path);
      if (p) { delivered.add(p); for (const e of open) e.withWrite.add(p); }
      continue;
    }
    if (r.type !== 'assistant' || !Array.isArray(r.message?.content)) continue;
    const uses = r.message.content.filter((c) => c.type === 'tool_use');
    if (uses.length) open = [];
    for (const c of uses) {
      const f = rel(c.input?.file_path);
      if (c.name === 'Read' && f) read.add(f);
      if (!WRITES.has(c.name) || !f || DOC.test(f) || MAP.test(f)) continue;
      const ms = Date.parse(r.timestamp);
      if (ms >= EXCLUDE[0] && ms < EXCLUDE[1]) continue;
      const dir = `${epoch}|${f.includes('/') ? f.slice(0, f.lastIndexOf('/')) : '.'}`;
      if (seen.has(dir)) continue;
      seen.add(dir);
      const res = results.get(c.id) ?? '';
      const kind = /File created successfully/.test(res) ? 'new' : /has been updated|updated successfully/.test(res) ? 'edit' : 'unknown';
      const e = { at: r.timestamp, epoch, file: f, tool: c.name, kind, read: new Set(read), delivered: new Set(delivered), withWrite: new Set() };
      out.push(e); open.push(e);
    }
  }
  return out;
}

// Per event: the declared set (documents whose paths: cover the file), each pair as D (delivered by Claude Code
// earlier in the epoch), R (not delivered, but Read by Claude earlier in the epoch) or X (neither); and (S-b)'s list.
export function score(e, docs) {
  const key = (p) => p.toLowerCase();
  const del = new Set([...e.delivered].map(key)), rd = new Set([...e.read].map(key)), withW = new Set([...e.withWrite].map(key));
  const P = docs.filter((d) => declared(d, e.file));
  const pairs = P.map((d) => ({ doc: d.path, cls: del.has(key(d.path)) ? 'D' : rd.has(key(d.path)) ? 'R' : 'X', withWrite: withW.has(key(d.path)) }));
  const sb = docs.filter((d) => matchB(d, e.file));
  const unread = sb.filter((d) => !rd.has(key(d.path)));
  const unreadNative = unread.filter((d) => !del.has(key(d.path)));
  const bytes = (l) => l.reduce((s, d) => s + d.bytes, 0);
  return { pairs, sbMisses: P.filter((d) => !sb.includes(d)).map((d) => d.path), unread: unread.length, unreadBytes: bytes(unread),
    unreadNative: unreadNative.length, unreadNativeBytes: bytes(unreadNative) };
}

const parse = (f) => fs.readFileSync(f, 'utf8').split('\n').flatMap((l) => { try { return l ? [JSON.parse(l)] : []; } catch { return []; } });
const [mode, ...rest] = process.argv.slice(2);
if (mode === 'selftest') {
  const ok = (c, m) => { if (!c) { console.error(`FAIL ${m}`); process.exitCode = 1; } };
  ok(covers('packages', 'packages/a/b.ts') && covers('data/results', 'data/results/x.json') && !covers('data/results', 'data/resultsX.json'), 'folder');
  ok(covers('data/*.json', 'data/a.json') && !covers('data/*.json', 'data/sub/a.json') && covers('scripts/*.py', 'scripts/a.py'), 'glob');
  ok(covers('packages/web/src/screens/dream', 'packages/web/src/screens/dream/X.tsx') && !covers('a/b.ts', 'a/b.tsx'), 'file and folder');
  const rel = (p) => slash(p).replace(/^\/r\//, '');
  const t = (name, id, file) => ({ type: 'assistant', timestamp: '2026-11-01T00:00:00Z', message: { content: [{ type: 'tool_use', name, id, input: { file_path: `/r/${file}` } }] } });
  const res = (id, text) => ({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id, content: text }] } });
  const nm = (file) => ({ type: 'attachment', attachment: { type: 'nested_memory', content: { path: `/r/${file}` } } });
  const recs = [t('Read', 'a', 'src/x.ts'), res('a', 'ok'), nm('.claude/rules/src.md'), t('Read', 'b', '.claude/rules/data.md'), res('b', 'ok'),
    t('Edit', 'c', 'src/x.ts'), res('c', 'The file /r/src/x.ts has been updated successfully.'),
    t('Write', 'd', 'data/n.json'), res('d', 'File created successfully at: /r/data/n.json'), nm('.claude/rules/data.md'), nm('.claude/rules/new.md'),
    t('Edit', 'e', 'src/y.ts'), res('e', 'The file has been updated successfully.'),
    { type: 'system', subtype: 'compact_boundary' }, t('Edit', 'f', 'src/x.ts'), res('f', 'The file has been updated successfully.')];
  const es = walk(recs, rel);
  ok(es.length === 3 && es.map((e) => e.kind).join() === 'edit,new,edit' && es[2].epoch === 1, 'events');
  const doc = (p, fm) => ({ path: p, text: `---\npaths:\n${fm.map((g) => `  - ${g}`).join('\n')}\n---\nbody\n`, bytes: 30 });
  const docs = [doc('.claude/rules/src.md', ['src']), doc('.claude/rules/data.md', ['data/*.json']), doc('.claude/rules/new.md', ['data'])];
  const s0 = score(es[0], docs), s1 = score(es[1], docs), s2 = score(es[2], docs);
  ok(s0.pairs.length === 1 && s0.pairs[0].cls === 'D', 'D before an edit');
  ok(s1.pairs.map((p) => `${p.doc}:${p.cls}:${p.withWrite}`).join() === '.claude/rules/data.md:R:true,.claude/rules/new.md:X:true', 'R and X, with the write');
  ok(s2.pairs[0].cls === 'X', 'compaction resets');
  ok(s0.sbMisses.length === 1, 'the scope probe\'s glob reads a bare folder as one path');
  if (!process.exitCode) console.log('selftest ok');
} else {
  const args = process.argv.slice(2);
  const count = args.includes('--count');
  const [repo, out, ...files] = args.filter((a) => a !== '--count');
  if (!repo || !out || !files.length) throw new Error('usage: node field-scope.mjs <repo> <out.json> [--count] <session.jsonl>...');
  const root = `${slash(repo).replace(/\/$/, '').toLowerCase()}/`;
  const rel = (p) => { const s = slash(p); return s.toLowerCase().startsWith(root) ? s.slice(root.length) : null; };
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8', maxBuffer: 1 << 28 });
  const rows = [];
  for (const f of files) {
    const recs = parse(f);
    const start = recs.find((r) => r.timestamp)?.timestamp;
    const commit = git('log', '-1', `--before=${start}`, '--format=%H').trim();
    // the documents at the session start's commit, CLAUDE.md left out as in the scope probe
    const docs = git('ls-tree', '-r', '--name-only', commit).split('\n').filter((p) => DOC.test(p) && !/(^|\/)CLAUDE\.md$/.test(p))
      .map((p) => { const text = git('show', `${commit}:${p}`); return { path: p, text, bytes: Buffer.byteLength(text) }; });
    for (const e of walk(recs, rel)) rows.push({ session: f.split(/[\\/]/).pop().slice(0, 8), commit: commit.slice(0, 7), at: e.at, epoch: e.epoch, file: e.file, kind: e.kind, ...score(e, docs) });
  }
  const pairs = rows.flatMap((r) => r.pairs.map((p) => ({ ...p, kind: r.kind })));
  const n = (a, p) => a.filter(p).length;
  console.log(`sessions ${files.length}; gate events ${rows.length} (new ${n(rows, (r) => r.kind === 'new')}, edit ${n(rows, (r) => r.kind === 'edit')}, unknown ${n(rows, (r) => r.kind === 'unknown')}); with a declared set ${n(rows, (r) => r.pairs.length)}; pairs ${pairs.length} (new ${n(pairs, (p) => p.kind === 'new')}, edit ${n(pairs, (p) => p.kind === 'edit')})`);
  if (!count) {
    for (const k of ['all', 'new', 'edit']) {
      const ps = pairs.filter((p) => k === 'all' || p.kind === k);
      console.log(`  pairs ${k}: D ${n(ps, (p) => p.cls === 'D')}, R ${n(ps, (p) => p.cls === 'R')}, X ${n(ps, (p) => p.cls === 'X')} (X delivered with the write ${n(ps, (p) => p.cls === 'X' && p.withWrite)})`);
    }
    const over = (u, b) => n(rows, (r) => r[u] > MAX_DOCS || r[b] > MAX_BYTES);
    console.log(`  (S-b) as registered: unread median ${median(rows.map((r) => r.unread))}, max ${Math.max(0, ...rows.map((r) => r.unread))}, bytes median ${median(rows.map((r) => r.unreadBytes))}; events over the bar ${over('unread', 'unreadBytes')} of ${rows.length}; declared documents off its list ${rows.reduce((s, r) => s + r.sbMisses.length, 0)} (in ${n(rows, (r) => r.sbMisses.length)} events)`);
    console.log(`  (S-b), Claude Code's deliveries also counted as read: unread median ${median(rows.map((r) => r.unreadNative))}, max ${Math.max(0, ...rows.map((r) => r.unreadNative))}, bytes median ${median(rows.map((r) => r.unreadNativeBytes))}; events over the bar ${over('unreadNative', 'unreadNativeBytes')}`);
    fs.writeFileSync(out, `${JSON.stringify(rows, null, 1)}\n`);
  }
}
