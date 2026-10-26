// V2-D22, the scope probe (pre-registered in DECISIONS.md, after the gate's stage 1): can the hook itself find, at a
// gated write, the documents that bind it, with lists short enough that every unread one can be required? Two
// matchers over the plugin's index, applied at every gate event of the saved streams. No model calls; counts and rule
// ids only, to results/scope-probe.json.
//   node scope-probe.mjs <config> <arm dir>...      each arm dir holds <task id>/run<n>/stream.jsonl and <task id>.json
//   node scope-probe.mjs selftest
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const MAP = /(^|\/)\.project-map\//;
const MAX_DOCS = 4;
const MAX_BYTES = 40 * 1024;
const LANG = { cs: ['C#'], ts: ['TypeScript'], tsx: ['TypeScript'], js: ['JavaScript'], mjs: ['JavaScript'], cjs: ['JavaScript'],
  jsx: ['JavaScript'], sh: ['bash', 'shell'], json: ['JSON'], py: ['Python'] };
const slash = (p) => String(p ?? '').replace(/\\/g, '/');
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// The terms for a repo-relative file: its extension as .ext, its language, each folder on its path.
export function terms(file) {
  const parts = slash(file).split('/');
  const ext = (parts.at(-1).match(/\.([^.]+)$/) ?? [])[1]?.toLowerCase();
  return [...(ext ? [`.${ext}`, ...(LANG[ext] ?? [])] : []), ...parts.slice(0, -1)];
}
// Word boundaries that also hold for terms starting with "." or ending with "#".
const hit = (text, ts) => ts.some((t) => new RegExp(`(?<![\\p{L}\\p{N}_])${esc(t)}(?![\\p{L}\\p{N}_])`, 'iu').test(text));

// Front matter (between --- lines at the top) and the body after it.
function split(text) {
  const m = text.replace(/\r/g, '').match(/^---\n([\s\S]*?)\n---\n?/);
  return m ? { fm: m[1], body: text.replace(/\r/g, '').slice(m[0].length) } : { fm: '', body: text.replace(/\r/g, '') };
}
// paths:/globs: patterns from front matter, inline ("a, b" or [a, b]) or as a list.
export function globs(fm) {
  const out = [];
  const lines = fm.split('\n');
  lines.forEach((l, i) => {
    const m = l.match(/^(paths|globs)\s*:\s*(.*)$/);
    if (!m) return;
    if (m[2].trim()) out.push(...m[2].replace(/^\[|\]$/g, '').split(','));
    else for (const x of lines.slice(i + 1)) { const y = x.match(/^\s*-\s*(.+)$/); if (!y) break; out.push(y[1]); }
  });
  return out.map((g) => g.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
}
export function globRe(g) {
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*' && g[i + 1] === '*') { re += g[i + 2] === '/' ? '(?:.*/)?' : '.*'; i += g[i + 2] === '/' ? 2 : 1; }
    else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') { const j = g.indexOf('}', i); re += `(?:${g.slice(i + 1, j).split(',').map(esc).join('|')})`; i = j; }
    else re += esc(c);
  }
  return new RegExp(`^${re}$`);
}
export const matchA = (doc, file) => hit(doc.text, terms(file));
export function matchB(doc, file) {
  const { fm, body } = split(doc.text);
  if (globs(fm).some((g) => globRe(g).test(slash(file)))) return true;
  return hit(body.split('\n').slice(0, 15).join('\n'), terms(file));
}

const parse = (s) => s.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
// Gate events: each main-session code write that is the first in its directory in its epoch, with the documents the
// main session Read earlier in that epoch. `root` matches the repo's folder in an absolute path (a run's worktree).
export function events(ev, root) {
  const rel = (p) => { const s = slash(p); const m = s.match(root); return m ? s.slice(m.index + m[0].length) : s.replace(/^\.\//, ''); };
  const out = []; let epoch = 0; let read = new Set(); const seen = new Set();
  for (const e of ev) {
    if (e.type === 'system' && e.subtype === 'compact_boundary') { epoch++; read = new Set(); }
    if (e.type !== 'assistant' || e.parent_tool_use_id || !Array.isArray(e.message?.content)) continue;
    for (const c of e.message.content) {
      if (c.type !== 'tool_use') continue;
      const f = c.input?.file_path;
      if (c.name === 'Read' && f) read.add(rel(f));
      if (!['Write', 'Edit', 'MultiEdit'].includes(c.name) || !f || DOC.test(f) || MAP.test(slash(f))) continue;
      const file = rel(f);
      if (/^[a-z]:\//i.test(file) || file.startsWith('/')) continue; // outside the repo
      const dir = `${epoch}|${file.includes('/') ? file.slice(0, file.lastIndexOf('/')) : '.'}`;
      if (seen.has(dir)) continue;
      seen.add(dir);
      out.push({ file, read: new Set(read) });
    }
  }
  return out;
}

const median = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? (s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null; };

const [mode, ...args] = process.argv.slice(2);
if (mode === 'selftest') {
  const ok = (c, m) => { if (!c) { console.error(`FAIL ${m}`); process.exitCode = 1; } };
  ok(JSON.stringify(terms('src/game/Foo.cs')) === JSON.stringify(['.cs', 'C#', 'src', 'game']), 'terms');
  ok(hit('Use C# here.', ['C#']) && hit('every .cs file', ['.cs']) && !hit('the docs folder', ['.cs']), 'hit');
  ok(!hit('csharp and Csx', ['C#']) && !hit('class.cs2', ['.cs']) && hit('in src/x', ['src']) && !hit('srcs', ['src']), 'boundaries');
  ok(JSON.stringify(globs('paths:\n  - "src/**/*.ts"\n  - lib/*.ts\nname: x')) === JSON.stringify(['src/**/*.ts', 'lib/*.ts']), 'globs list');
  ok(JSON.stringify(globs('globs: a/*.ts, b/**')) === JSON.stringify(['a/*.ts', 'b/**']), 'globs inline');
  ok(globRe('src/**/*.ts').test('src/a/b/c.ts') && globRe('src/**/*.ts').test('src/c.ts') && !globRe('src/*.ts').test('src/a/c.ts'), 'globRe');
  ok(globRe('**/*.{ts,tsx}').test('a/b.tsx') && !globRe('**/*.{ts,tsx}').test('a/b.js'), 'globRe braces');
  const doc = { text: '---\npaths:\n  - "web/**/*.tsx"\n---\n# Title\nline\n'.concat('x\n'.repeat(20), 'C# rules here') };
  ok(matchB(doc, 'web/a/B.tsx') && !matchB(doc, 'api/B.cs') && matchA(doc, 'api/B.cs'), 'matchers');
  const ev = [{ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/r/docs/a.md' } }] } },
    { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Edit', input: { file_path: '/r/src/x.cs' } }, { type: 'tool_use', name: 'Edit', input: { file_path: '/r/src/y.cs' } }] } },
    { type: 'assistant', parent_tool_use_id: 'p', message: { content: [{ type: 'tool_use', name: 'Write', input: { file_path: '/r/lib/z.cs' } }] } },
    { type: 'system', subtype: 'compact_boundary' },
    { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Write', input: { file_path: '/r/src/w.cs' } }, { type: 'tool_use', name: 'Write', input: { file_path: '/r/.project-map/c.md' } }] } }];
  const es = events(ev, /\/r\//);
  ok(es.length === 2 && es[0].file === 'src/x.cs' && es[0].read.has('docs/a.md') && es[1].read.size === 0, 'events');
  if (!process.exitCode) console.log('selftest ok');
} else {
  const [cfgPath, armDirs] = [mode, args];
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  const git = (repo, ...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8', maxBuffer: 1 << 28 });
  const out = { date: new Date().toISOString().slice(0, 10), bar: { maxDocs: MAX_DOCS, maxBytes: MAX_BYTES }, repos: {} };
  for (const t of cfg.tasks.filter((x) => /-build$/.test(x.id))) {
    const docs = git(t.repo, 'ls-tree', '-r', '--name-only', t.commit).split('\n').filter((p) => DOC.test(p) && !/(^|\/)CLAUDE\.md$/.test(p))
      .map((p) => { const text = git(t.repo, 'show', `${t.commit}:${p}`); return { path: p, text, bytes: Buffer.byteLength(text) }; });
    const byPath = new Map(docs.map((d) => [d.path, d]));
    const rules = t.rules.filter((r) => r.check?.path && byPath.has(r.source) && !DOC.test(Object.keys(r.test?.pass ?? {})[0] ?? 'x.code'));
    const evs = [];
    for (const a of armDirs) {
      const sum = path.join(a, `${t.id}.json`);
      if (!fs.existsSync(sum)) continue;
      for (const r of JSON.parse(fs.readFileSync(sum, 'utf8')).runs.filter((x) => x.valid)) {
        const f = path.join(a, t.id, `run${r.run}`, 'stream.jsonl');
        if (fs.existsSync(f)) evs.push(...events(parse(fs.readFileSync(f, 'utf8')), new RegExp(`/wt-${t.id}[^/]*/`)).map((e) => ({ ...e, arm: path.basename(a) })));
      }
    }
    const row = { events: evs.length, arms: [...new Set(evs.map((e) => e.arm))], rules: rules.map((r) => r.id), matchers: {} };
    for (const [name, match] of [['S-a', matchA], ['S-b', matchB]]) {
      const lens = []; const bytes = []; let over = 0; const misses = new Set(); const tested = new Set();
      for (const e of evs) {
        const list = docs.filter((d) => match(d, e.file));
        const unread = list.filter((d) => !e.read.has(d.path));
        const b = unread.reduce((s, d) => s + d.bytes, 0);
        lens.push(unread.length); bytes.push(b);
        if (unread.length > MAX_DOCS || b > MAX_BYTES) over++;
        for (const r of rules) {
          if (!new RegExp(r.check.path, r.check.flags ?? '').test(e.file)) continue;
          tested.add(r.id);
          if (!list.includes(byPath.get(r.source))) misses.add(r.id);
        }
      }
      // a rule whose check path met no event: its check's own passing example paths
      for (const r of rules.filter((x) => !tested.has(x.id))) {
        for (const f of Object.keys(r.test?.pass ?? {})) if (!match(byPath.get(r.source), f)) misses.add(r.id);
      }
      row.matchers[name] = { listMedian: median(lens), listMax: Math.max(0, ...lens), bytesMedian: median(bytes), bytesMax: Math.max(0, ...bytes),
        eventsOverLength: over, recallMisses: [...misses], untested: rules.filter((x) => !tested.has(x.id)).map((x) => x.id),
        pass: over === 0 && misses.size === 0 };
    }
    out.repos[t.id] = row;
  }
  out.verdict = Object.fromEntries(['S-a', 'S-b'].map((m) => [m, Object.values(out.repos).every((r) => r.matchers[m].pass)]));
  out.verdict.pass = out.verdict['S-a'] || out.verdict['S-b'];
  fs.writeFileSync(path.join(HERE, 'results', 'scope-probe.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
}
