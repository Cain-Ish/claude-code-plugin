// V2-D22 pull, attempt 3 (arm pk): before the first write in each directory of a session, deny it once and name the
// project documents keyed to the target by rule K (DECISIONS.md). Paths only, no rule text. Every call is logged to
// <run dir>/deliveries.jsonl.
//   node pathkey.mjs <run dir>                        the hook (stdin: PreToolUse input; cwd: the repo)
//   node pathkey.mjs count <config> <arm dir>...      the pre-run count: counts only, to results/pathkey-count.json
//   node pathkey.mjs selftest
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const slash = (p) => String(p ?? '').replace(/\\/g, '/');

// K: the documents ([path, text], in git's order) that name the target, most specific first, at most 10.
export function keyed(target, docs) {
  const parts = slash(target).split('/');
  const dirs = parts.slice(0, -1);
  const levels = [
    [new RegExp(esc(parts.join('/').toLowerCase()))],
    [new RegExp(esc(parts.at(-1).toLowerCase()))],
    dirs.map((_, i) => dirs.slice(i)).filter((s) => s.length >= 2) // longest first
      .map((s) => new RegExp(`(^|[^\\w./-])${esc(s.join('/').toLowerCase())}`)),
  ];
  const lower = docs.map(([p, t]) => [p, slash(t).toLowerCase()]);
  const out = [];
  for (const level of levels) for (const re of level) for (const [p, t] of lower) {
    if (out.length < 10 && p !== parts.join('/') && !out.includes(p) && re.test(t)) out.push(p);
  }
  return out;
}

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, ...args] = process.argv.slice(2);
const git = (cwd, ...a) => execFileSync('git', ['-c', 'core.longpaths=true', '-C', cwd, ...a], { encoding: 'utf8', maxBuffer: 256 << 20 });

if (mode === 'selftest') {
  const docs = [['a.md', 'see `pkg/web/src/components/` for UI'], ['b.md', 'Mobiles/Monsters/ hold monsters'],
    ['c.md', 'other/src/components here'], ['d.md', 'edit Card.tsx carefully'], ['pkg/web/src/components/x.md', 'components/x']];
  const got = keyed('pkg/web/src/components/Card.tsx', docs);
  console.assert(JSON.stringify(got) === '["d.md","a.md"]', got); // c.md names another src/components
  console.assert(JSON.stringify(keyed('S/W/Mobiles/Monsters/M.cs', docs)) === '["b.md"]');
  console.assert(keyed('x.md', [['x.md', 'x.md']]).length === 0); // not keyed to itself
  console.log('selftest done');
} else if (mode === 'count') {
  // For each rule native misses: in the sessions that wrote a file its check covers, is its source named at the first
  // write in that file's directory?
  const [cfgPath, ...armDirs] = args;
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  const out = { date: new Date().toISOString().slice(0, 10), rule: 'K (DECISIONS.md, V2-D22 attempt 3); pass: the source named in at least 80% of covering sessions, for every rule', tasks: {} };
  for (const t of cfg.tasks) {
    const docs = git(t.repo, 'ls-tree', '-r', '--name-only', t.commit).split('\n').filter((p) => DOC.test(p))
      .map((p) => [p, git(t.repo, 'show', `${t.commit}:${p}`)]);
    const rules = t.rules.filter((r) => (cfg.missed ?? {})[t.id]?.includes(r.id));
    const rows = Object.fromEntries(rules.map((r) => [r.id, { sessions: 0, named: 0 }]));
    const lists = [];
    for (const armDir of armDirs) {
      const d = path.join(armDir, t.id);
      if (!fs.existsSync(d)) continue;
      for (const run of fs.readdirSync(d).filter((x) => /^run[1-9]\d*$/.test(x))) {
        const f = path.join(d, run, 'stream.jsonl');
        if (!fs.existsSync(f)) continue;
        const ev = fs.readFileSync(f, 'utf8').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
        const first = new Map(); // directory -> first target written there
        for (const e of ev) if (e.type === 'assistant') for (const c of e.message?.content ?? []) {
          if (c.type !== 'tool_use' || !['Write', 'Edit', 'MultiEdit'].includes(c.name)) continue;
          const m = slash(c.input?.file_path).match(/\/wt-[^/]+\/(.+)$/);
          if (!m) continue;
          const dir = m[1].includes('/') ? m[1].slice(0, m[1].lastIndexOf('/')) : '.';
          if (!first.has(dir)) first.set(dir, m[1]);
        }
        const written = [...first.keys()];
        for (const r of rules) {
          const re = new RegExp(r.check.path ?? '.');
          const files = ev.flatMap((e) => (e.type === 'assistant' ? e.message?.content ?? [] : []))
            .filter((c) => c.type === 'tool_use' && ['Write', 'Edit', 'MultiEdit'].includes(c.name))
            .map((c) => slash(c.input?.file_path).match(/\/wt-[^/]+\/(.+)$/)?.[1]).filter((p) => p && re.test(p));
          if (!files.length) continue;
          const dirs = [...new Set(files.map((p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '.')))].filter((x) => written.includes(x));
          const named = dirs.some((x) => keyed(first.get(x), docs).includes(r.source));
          rows[r.id].sessions++;
          if (named) rows[r.id].named++;
        }
        lists.push([...first.values()].map((p) => keyed(p, docs).length));
      }
    }
    for (const row of Object.values(rows)) row.share = row.sessions ? +(row.named / row.sessions).toFixed(2) : null;
    out.tasks[t.id] = { documents: docs.length, rules: rows, pass: Object.values(rows).every((x) => x.share >= 0.8),
      namedPerFirstWrite: { median: lists.flat().sort((a, b) => a - b)[(lists.flat().length - 1) >> 1] ?? null, zero: lists.flat().filter((n) => !n).length, of: lists.flat().length } };
  }
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'pathkey-count.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else {
  const dir = mode;
  const logPath = path.join(dir, 'deliveries.jsonl');
  const logged = (fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').split('\n') : []).flatMap((l) => (l ? [JSON.parse(l)] : []));
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const cwd = input.cwd ?? '.';
  const file = slash(path.relative(cwd, input.tool_input?.file_path ?? ''));
  const fdir = file.includes('/') ? file.slice(0, file.lastIndexOf('/')) : '.';
  const log = { ev: input.hook_event_name, file, dir: fdir };
  if (file && !file.startsWith('..') && !logged.some((l) => l.dir === fdir && l.asked)) {
    const docs = git(cwd, 'ls-files').split('\n').filter((p) => DOC.test(p) && fs.existsSync(path.join(cwd, p)))
      .map((p) => [p, fs.readFileSync(path.join(cwd, p), 'utf8')]);
    const named = keyed(file, docs);
    log.docs = named;
    if (named.length) {
      log.asked = true;
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
        permissionDecisionReason: `[d20-deny] [d22-pull] Before you write ${file}: these project documents name this file `
          + `or its directory. Read them, then make the write again (asked once per directory).\n${named.map((p) => `- ${p}`).join('\n')}` } }));
    }
  }
  log.ms = Math.round(process.uptime() * 1000);
  fs.appendFileSync(logPath, `${JSON.stringify(log)}\n`);
}
