// The field check's scanner (README.md): node field.mjs <out.json> <session.jsonl>...
// Reads main-session transcripts and their subagents; prints counts; the per-unit record goes to <out.json> (raw/,
// gitignored: it holds extracts). Judged checks (C3, C4's yes-lists, C6c's not-found entries) are listed for reading.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const INSTR = 'This project keeps a map of its knowledge in the folder .project-map/.';
const FORCE = 'Before you start: for each directory in this project';
const HEADER = "This project's documents, by directory:";
const NAME = "When you finish, name each of this project's recorded decisions";
const LABEL = '[project map]';
const WRITES = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
const EXCLUDE = [Date.parse('2026-10-26T11:35:00Z'), Date.parse('2026-10-26T12:31:00Z')]; // D22 rethink 4, unreleased
const GITHUB = Date.parse('2026-10-29T00:52:30Z');

const [out, ...files] = process.argv.slice(2);
if (!out || !files.length) throw new Error('usage: node field.mjs <out.json> <session.jsonl>...');

// the plugin commit live at a time: the checkout's history of plugin/ until the GitHub install, the tag after
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/(\w:)/, '$1'));
const log = spawnSync('git', ['log', '--format=%h %cI', '--', ':/plugin/'], { cwd: here, encoding: 'utf8' }).stdout
  .trim().split('\n').map((l) => { const [h, t] = l.split(' '); return [h, Date.parse(t)]; });
const build = (ms) => (ms >= GITHUB ? 'tag v2.0.0-alpha.2' : (log.find(([, t]) => t <= ms) ?? ['?'])[0]);
const excluded = (ms) => ms >= EXCLUDE[0] && ms < EXCLUDE[1];

const read = (f) => fs.readFileSync(f, 'utf8').split('\n').flatMap((l) => { try { return l ? [JSON.parse(l)] : []; } catch { return []; } });
const text = (c) => (typeof c === 'string' ? c : Array.isArray(c) ? c.map((x) => x.text ?? (typeof x.content === 'string' ? x.content : Array.isArray(x.content) ? text(x.content) : '')).join('\n') : '');
// C6c's comparison: case, whitespace and Markdown markup ignored
const norm = (s) => s.toLowerCase().replace(/[*_`>#]|\[|\]/g, ' ').replace(/\s+/g, ' ').trim();

function kind(r) {
  if (r.type !== 'user' || r.toolUseResult || r.isCompactSummary) return null;
  const t = text(r.message?.content);
  if (!t.trim()) return null;
  const o = r.origin?.kind;
  if (o === 'human') return 'human';
  if (o) return 'machine';
  if (r.isMeta || /^\s*<(command-name|local-command|task-notification|agent-message|cross-session|system-reminder)/.test(t)) return 'machine';
  return /^This session is being continued from a previous conversation/.test(t) ? null : 'human';
}

// entries in a capture write: "### area" blocks
const entries = (s) => s.split(/^(?=### )/m).filter((b) => b.startsWith('### ')).map((b) => ({
  area: b.split('\n')[0].slice(4).trim(),
  quote: b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^>\s?/, '')).join(' ').trim(),
  source: (b.match(/^- source:\s*(.*)$/m) ?? [])[1] ?? null,
  when: (b.match(/^- when:\s*(.*)$/m) ?? [])[1] ?? null,
  forbidden: [/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, /[\w.+-]+@[\w-]+\.[\w.]+/, /\b[A-Za-z]:[\\/]|\/(Users|home)\//]
    .filter((re) => re.test(b)).map(String),
}));

function scan(file) {
  const recs = read(file).filter((r) => r.timestamp).sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
  const cwd = recs.find((r) => r.cwd)?.cwd;
  const S = { epochs: [], writes: [], mapReads: [], mapOther: [], entries: [], named: [], hookErrors: [], sources: [] };
  const corpus = []; // [ms, normalized text] of human prompts, tool results and hook contexts, for C6c
  const results = new Map(); // tool_use id -> result text
  const ctxByTool = new Map(); // tool_use id -> PostToolUse contexts
  let ep = null; let turn = null; let pendingStart = null;
  const commits = [];
  for (const r of recs) {
    const ms = Date.parse(r.timestamp);
    const a = r.attachment;
    // epoch starts: a SessionStart hook success (any plugin's) or a compaction boundary opens one
    if (a?.type === 'hook_success' && a.hookEvent === 'SessionStart') {
      const src = a.hookName.split(':')[1] ?? '?';
      if (!ep || ep.source !== src || ms - ep.ms > 5000) {
        ep = { ms, at: r.timestamp, source: src, build: build(ms), excluded: excluded(ms), pluginStart: false, ctx: false, index: [], forces: [], turns: [] };
        S.epochs.push(ep); turn = null;
      }
      if (/hook\.mjs.*session-start/.test(a.command ?? '')) {
        ep.pluginStart = (a.stdout ?? '').includes(INSTR);
        ep.pluginExit = a.exitCode;
        if (/project map needs Node/.test(a.stdout ?? '') || a.exitCode) S.hookErrors.push({ at: r.timestamp, hook: a.hookName, exit: a.exitCode });
      }
      continue;
    }
    if (r.type === 'system' && r.subtype === 'compact_boundary') { pendingStart = ms; continue; }
    if (a?.type === 'hook_additional_context') {
      const c = (a.content ?? []).join('\n');
      corpus.push([ms, norm(c)]);
      if (a.hookEvent === 'SessionStart' && c.includes(INSTR) && ep) {
        ep.ctx = true;
        const lines = c.split('\n'); const h = lines.findIndex((l) => l.includes(HEADER));
        if (h >= 0) ep.index = lines.slice(h + 1).filter((l) => /^[^\s].*\/: /.test(l)).map((l) => ({ dir: l.split('/: ')[0], docs: l.split('/: ')[1].split(', ') }));
      }
      if (a.hookEvent === 'UserPromptSubmit' && c.startsWith(FORCE) && ep) ep.forces.push({ at: r.timestamp, parent: r.parentUuid, onTurn: null });
      if (a.hookEvent === 'PostToolUse') { const l = ctxByTool.get(a.toolUseID) ?? []; l.push(c); ctxByTool.set(a.toolUseID, l); }
      continue;
    }
    if (a && /hook_(error|non_blocking_error|blocking_error|cancelled|timeout)/.test(a.type) && /hook\.mjs/.test(a.command ?? JSON.stringify(a))) {
      S.hookErrors.push({ at: r.timestamp, type: a.type, hook: a.hookName }); continue;
    }
    // a rule file Claude Code loads on a matching path: C4's broad reading counts it as read
    if (a?.type === 'nested_memory') { if (turn) turn.tools.push({ at: r.timestamp, ms, name: 'NestedMemory', file: a.path }); continue; }
    if (a?.type === 'queued_command') {
      const human = a.origin?.kind === 'human';
      if (ep) ep.turns.push(turn = { at: r.timestamp, uuid: r.uuid, kind: human ? 'human' : 'machine', queued: true, origin: a.origin?.kind, prompt: String(a.prompt ?? '').slice(0, 300), forced: false, texts: [], tools: [] });
      if (human) corpus.push([ms, norm(String(a.prompt ?? ''))]);
      continue;
    }
    const k = kind(r);
    if (k) {
      const t = text(r.message.content);
      if (k === 'human') corpus.push([ms, norm(t)]);
      if (ep) ep.turns.push(turn = { at: r.timestamp, uuid: r.uuid, kind: k, origin: r.origin?.kind ?? null, prompt: t.slice(0, 300), forced: false, texts: [], tools: [] });
      continue;
    }
    if (r.type === 'user' && Array.isArray(r.message?.content)) {
      for (const x of r.message.content) if (x.type === 'tool_result') { const t = text(x.content); results.set(x.tool_use_id, t); corpus.push([ms, norm(t)]); }
      continue;
    }
    if (r.type === 'assistant' && Array.isArray(r.message?.content)) {
      for (const x of r.message.content) {
        if (x.type === 'text' && turn) turn.texts.push({ at: r.timestamp, text: x.text, afterTools: turn.tools.length });
        if (x.type !== 'tool_use') continue;
        const tool = { at: r.timestamp, ms, id: x.id, name: x.name, file: x.input?.file_path ?? x.input?.notebook_path ?? null, cmd: x.name === 'Bash' ? String(x.input?.command ?? '').slice(0, 200) : null, input: x.input };
        if (turn) turn.tools.push(tool);
        if (x.name === 'Bash' && /git\s+commit/.test(x.input?.command ?? '')) commits.push(ms);
        const f = (tool.file ?? '').replace(/\\/g, '/');
        if (WRITES.has(x.name) && f) S.writes.push({ at: r.timestamp, file: f, build: build(ms), excluded: excluded(ms) });
        if (f.includes('/.project-map/') || f.startsWith('.project-map/')) {
          if (x.name === 'Read') S.mapReads.push({ at: r.timestamp, ms, id: x.id, file: f, build: build(ms) });
          if (WRITES.has(x.name)) for (const e of entries(String(x.input?.content ?? x.input?.new_string ?? (x.input?.edits ?? []).map((d) => d.new_string).join('\n'))))
            S.entries.push({ at: r.timestamp, ms, file: f, ...e, build: build(ms), excluded: excluded(ms), by: 'main' });
        } else if (/\.project-map/.test(JSON.stringify(x.input ?? {})) && ['Grep', 'Glob', 'Bash'].includes(x.name)) {
          const cmd = String(x.input?.command ?? '');
          // an append through Bash (cat >> map file <<'EOF' ... EOF) is a capture write too (C6)
          const here = cmd.match(/>>\s*\S*\.project-map\/\S+\.md\s*<<-?\s*'?(\w+)'?\n([\s\S]*?)\n\1/);
          if (here) for (const e of entries(here[2])) S.entries.push({ at: r.timestamp, ms, file: '.project-map (bash)', ...e, build: build(ms), excluded: excluded(ms), by: 'bash' });
          // a read names the map folder in the read command's own words, not elsewhere in the line (corrected after the run)
          const kindOf = here ? 'append' : /python|>\s*\S*\.project-map/.test(cmd) ? 'other-write' : /\b(cat|tail|head|sed|grep|less|more|type)\b[^|;&\n]*\.project-map/.test(cmd) || x.name === 'Grep' ? 'read' : 'other';
          S.mapOther.push({ at: r.timestamp, name: x.name, kind: kindOf });
        }
      }
    }
  }
  // link each force to the turn it came with (its parent record), then judge-ready extracts
  for (const e of S.epochs) for (const f of e.forces) {
    const t = e.turns.find((u) => u.uuid === f.parent) ?? e.turns.filter((u) => Date.parse(u.at) <= Date.parse(f.at)).at(-1);
    if (t) { t.forced = true; f.onTurn = t.kind + (t.queued ? '/queued' : '') + (t.origin ? `/${t.origin}` : ''); }
  }
  // C5: reads of a map file after an in-session write to it, with no commit between
  for (const rd of S.mapReads) {
    const w = S.entries.filter((e) => e.file === rd.file && e.ms < rd.ms).at(-1);
    rd.ctx = (ctxByTool.get(rd.id) ?? []).filter((c) => c.startsWith(LABEL));
    rd.mustLabel = !!w && !commits.some((c) => c > w.ms && c < rd.ms);
    rd.labelledUnreviewed = rd.ctx.some((c) => /unreviewed/.test(c));
  }
  // C6c: each entry's quote, verbatim before its write
  for (const e of S.entries) e.found = !!e.quote && corpus.some(([m, t]) => m < e.ms && t.includes(norm(e.quote)));
  // C7: paths named after a file change, in a turn's later texts
  const tracked = new Set(cwd ? spawnSync('git', ['ls-files'], { cwd, encoding: 'utf8' }).stdout.split('\n') : []);
  const written = new Set(S.writes.map((w) => w.file));
  for (const e of S.epochs) for (const t of e.turns) {
    const firstWrite = t.tools.findIndex((x) => WRITES.has(x.name));
    if (firstWrite < 0) continue;
    for (const x of t.texts.filter((y) => y.afterTools > firstWrite))
      for (const p of new Set(x.text.match(/[\w.@/-]*[\w-]+\.(md|mdx|markdown|txt|rst)\b/g) ?? [])) {
        const rel = p.replace(/^\.\//, '');
        // tracked, written in the session, or on disk now (an untracked map file is a source too)
        const ok = tracked.has(rel) || [...written].some((w) => w.endsWith('/' + rel) || w === rel) || [...tracked].some((tf) => tf.endsWith('/' + rel))
          || (cwd && fs.existsSync(path.join(cwd, rel)));
        S.named.push({ at: x.at, path: rel, exists: ok });
      }
  }
  return { file: path.basename(file), cwd: cwd ? '<repo>' : null, ...S, commits: commits.length };
}

function subagents(file) {
  const dir = path.join(path.dirname(file), path.basename(file, '.jsonl'), 'subagents');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')).map((f) => {
    const recs = read(path.join(dir, f));
    const tools = recs.flatMap((r) => (r.type === 'assistant' && Array.isArray(r.message?.content) ? r.message.content.filter((x) => x.type === 'tool_use') : []));
    const ws = tools.filter((x) => WRITES.has(x.name)).map((x) => String(x.input?.file_path ?? '').replace(/\\/g, '/'));
    const mapEntries = tools.filter((x) => WRITES.has(x.name) && /\.project-map\//.test(String(x.input?.file_path ?? '').replace(/\\/g, '/')))
      .flatMap((x) => entries(String(x.input?.content ?? x.input?.new_string ?? '')));
    const first = recs.find((r) => r.timestamp)?.timestamp;
    return { at: first, build: first ? build(Date.parse(first)) : '?', index: recs.some((r) => JSON.stringify(r).includes(HEADER)),
      writes: ws.length, repoWrites: ws.filter((w) => !/\/(tmp|temp)\//i.test(w) && !/AppData/i.test(w)).length, mapEntries };
  });
}

const all = files.map((f) => ({ ...scan(f), subagents: subagents(f) }));
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(all, null, 1));

// counts, per session; units in the excluded hour are left out
for (const s of all) {
  const E = s.epochs.filter((e) => !e.excluded);
  const forced = E.flatMap((e) => e.forces.map((f) => ({ e, f })));
  const firstHuman = (e) => e.turns.find((t) => t.kind === 'human');
  console.log(`\n${s.file.slice(0, 8)}: ${E.length} epochs (${s.epochs.length - E.length} excluded), sources ${JSON.stringify(E.reduce((m, e) => ({ ...m, [e.source]: (m[e.source] ?? 0) + 1 }), {}))}`);
  console.log(`  builds: ${JSON.stringify(E.reduce((m, e) => ({ ...m, [e.build]: (m[e.build] ?? 0) + 1 }), {}))}`);
  console.log(`  C1 arrival: plugin start ${E.filter((e) => e.pluginStart).length}/${E.length}, context recorded ${E.filter((e) => e.ctx).length}/${E.length}; index dirs ${E.map((e) => e.index.length).join(',')}`);
  console.log(`  C2 forces: ${forced.length} in ${E.filter((e) => e.forces.length).length} epochs; on ${JSON.stringify(forced.reduce((m, { f }) => ({ ...m, [f.onTurn]: (m[f.onTurn] ?? 0) + 1 }), {}))}; epochs with a human prompt and no force ${E.filter((e) => firstHuman(e) && !e.forces.length).length}; epochs with >1 force ${E.filter((e) => e.forces.length > 1).length}; force not on the first human prompt ${E.filter((e) => e.forces.length && firstHuman(e) && !firstHuman(e).forced).length}`);
  console.log(`  C5 map reads: ${s.mapReads.length} (must label ${s.mapReads.filter((r) => r.mustLabel).length}, labelled unreviewed ${s.mapReads.filter((r) => r.mustLabel && r.labelledUnreviewed).length}; any label ${s.mapReads.filter((r) => r.ctx.length).length}); map via Grep/Glob/Bash ${JSON.stringify(s.mapOther.reduce((m, o) => ({ ...m, [o.kind]: (m[o.kind] ?? 0) + 1 }), {}))}`);
  const en = s.entries.filter((e) => !e.excluded);
  console.log(`  C6 entries (main): ${en.length} (${en.filter((e) => e.by === 'bash').length} by Bash); format ok ${en.filter((e) => e.area && e.quote && e.source && e.when).length}; forbidden ${en.filter((e) => e.forbidden.length).length}; verbatim ${en.filter((e) => e.found).length}`);
  console.log(`  C7 named paths after a change: ${s.named.length}, not found ${s.named.filter((n) => !n.exists).length}`);
  console.log(`  C8 hook errors: ${s.hookErrors.length}`);
  const sa = s.subagents;
  console.log(`  C9 subagents: ${sa.length}; with index ${sa.filter((x) => x.index).length}; writing repo files ${sa.filter((x) => x.repoWrites).length} (${sa.reduce((n, x) => n + x.repoWrites, 0)} writes); map entries ${sa.reduce((n, x) => n + x.mapEntries.length, 0)}`);
  console.log(`  writes (main): ${s.writes.filter((w) => !w.excluded).length}; git commits ${s.commits}`);
}
