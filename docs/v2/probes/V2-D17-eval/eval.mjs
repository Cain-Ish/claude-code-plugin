// V2-D17 eval harness (05-eval-plan.md): runs one arm of scenario A1 with `claude -p` and scores it deterministically.
// Usage: node eval.mjs <scratch-dir> <M0|M1|M2|V2> [runs=1] [first=1]  |  node eval.mjs --smoke  |  node eval.mjs --summary
// V2 (06, build step 2c): the plugin from plugin/, H once, the map committed, then T and N as the same person and a second
// (D17_MODEL=<model> D17_TAG=<suffix> for another epoch; D17_CLAUDE=<binary> pins the CLI, as native.mjs does)
// Run folders and raw streams stay in <scratch-dir>; the scored record (no paths, no session ids) is merged into
// results/<arm>.json next to this script.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import * as S from './sessions.mjs';
import { provenanceOf } from '../V2-D14-capture/provenance.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// another epoch (05-eval-plan.md: the Opus re-baseline) sets D17_MODEL, and D17_TAG keeps its results in their own files
const MODEL = process.env.D17_MODEL ?? 'claude-sonnet-5-5';
const TAG = process.env.D17_TAG ?? '';
// a pinned binary holds the epoch: the installed `claude` updates itself between runs
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
// D17_PLUGIN runs an attempt from a plugin copy (D22 option (A)): plugin/ changes only after an attempt passes
const PLUGIN = process.env.D17_PLUGIN ? path.resolve(process.env.D17_PLUGIN) : path.join(HERE, '..', '..', '..', '..', 'plugin');
const CODE = /\.(tsx?|jsx?|css|scss)$/;

function walk(dir, skip = [], base = dir, out = {}) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (skip.includes(e.name)) continue;
    const f = path.join(dir, e.name);
    if (e.isDirectory()) walk(f, skip, base, out);
    else out[path.relative(base, f).replace(/\\/g, '/')] = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  }
  return out;
}
const FIXTURE = path.join(HERE, 'fixture');
const FIXTURE_FILES = walk(FIXTURE);

// ---------- scoring (pure functions of files and text) ----------

// Comments are removed so a comment explaining a decision ("never from the CDN") is not scored as code.
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
const code = (files) => Object.entries(files).filter(([p]) => CODE.test(p)).map(([, t]) => stripComments(t)).join('\n');
const NAMED = 'white|black|red|green|blue|gr[ae]y|silver|orange|yellow|purple|pink|navy|teal';
const COLOUR = new RegExp(`#[0-9a-f]{3,8}\\b|\\b(?:rgba?|hsla?)\\(|['"\`](?:${NAMED})['"\`]|:\\s*(?:${NAMED})\\s*;`, 'i');
const num = (n) => new RegExp(`(?<![\\d.])${n}(?!\\d)`);
const sizes = (t) => [24, 40, 64].every((n) => num(n).test(t));
const under = (files, dir) => Object.keys(files).length > 0 && Object.keys(files).every((p) => p.startsWith(dir));

// JSX <Img ...> tags; braces are skipped so `=>` inside a prop value does not end the tag.
function imgTags(t) {
  const out = [];
  for (let i = t.indexOf('<Img'); i >= 0; i = t.indexOf('<Img', i + 1)) {
    if (/\w/.test(t[i + 4] ?? '')) continue; // <Image, <ImgProps
    let d = 0;
    let j = i;
    for (; j < t.length; j++) {
      if (t[j] === '{') d++;
      else if (t[j] === '}') d--;
      else if (t[j] === '>' && d === 0) break;
    }
    out.push(t.slice(i, j + 1));
  }
  return out;
}

const T_ITEMS = {
  T1: (f) => under(f, 'src/components/UserAvatar/') && 'src/components/UserAvatar/UserAvatar.tsx' in f,
  T2: (f) => !COLOUR.test(code(f)),
  T3: (f) => sizes(code(f)) && /avatarFallback/.test(code(f)) && /borderSubtle/.test(code(f)),
  T4: (f) => {
    const c = code(f);
    return !/cdn/i.test(c) && /avatarPath/.test(c) && imgTags(c).every((t) => /\blocal\b/.test(t));
  },
};
const T5 = (reply) => /developer|\blead\b/i.test(reply) && /designer/i.test(reply) && /\bPM\b|product manager|client/i.test(reply);
// V2-D23: T5 as the fixture states the sources. H1 gives the folder decision as a team meeting's and names no lead, so
// "meeting" counts too. T5 stays, frozen, beside it.
const T5F = (reply) => /\bmeeting\b|developer|\blead\b/i.test(reply) && /designer/i.test(reply) && /\bPM\b|product manager|client/i.test(reply);
// V2-D23 over-attribution: source roles a reply names that neither its run's map nor its prompt holds
const ROLES = { 'lead developer': /lead developer/i, 'tech lead': /tech lead/i, 'team lead': /team lead/i, 'the lead': /\bthe lead\b/i,
  developer: /\bdeveloper\b/i, designer: /\bdesigner\b/i, PM: /\bPM\b/, 'product manager': /product manager/i, client: /\bclient\b/i,
  architect: /\barchitect\b/i, CTO: /\bCTO\b/, 'product owner': /product owner/i };
const overAttributed = (reply, record) => Object.entries(ROLES).filter(([, re]) => re.test(reply) && !re.test(record)).map(([k]) => k);
const N_ITEMS = {
  N1: (f) => under(f, 'src/components/ProductImage/'),
  N2: (f) => !COLOUR.test(code(f)),
  N3: (f) => {
    const c = code(f);
    const tags = imgTags(c);
    const viaCdn = tags.length ? tags.every((t) => !/\blocal\b/.test(t)) : /cdn/i.test(c);
    return viaCdn && !/avatarFallback/.test(c) && !sizes(c);
  },
};
const C_ITEMS = {
  C1: (m) => /folder|directory/i.test(m) && /style.?guide/i.test(m),
  C2: (m) => /avatar/i.test(m) && sizes(m) && /initials/i.test(m),
  C3: (m) => /\bcdn\b/i.test(m) && /local/i.test(m),
  C4: (m) => !num(4100).test(m),
};
// Failure chain: which capture item and which T item stand for each decision.
const CHAIN = { folder: ['C1', 'T1'], spec: ['C2', 'T3'], cdn: ['C3', 'T4'] };
const scoreAll = (items, x) => Object.fromEntries(Object.entries(items).map(([k, fn]) => [k, fn(x)]));

// ---------- the event stream ----------

const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const blocksOf = (ev, role, type) => ev.flatMap((e) => (e.type === role ? (e.message?.content ?? []).filter((c) => c.type === type) : []));
const textOf = (c) => (typeof c?.content === 'string' ? c.content : (c?.content ?? []).map((x) => x.text ?? '').join('\n'));
const norm = (p) => String(p ?? '').replace(/\\/g, '/').toLowerCase();
// Path relative to a run folder (repo-T, mem-T, ...), matched by its unique name so drive-letter or slash forms agree.
function relTo(root, p) {
  const q = String(p ?? '').replace(/\\/g, '/');
  const i = q.toLowerCase().indexOf(`/${path.basename(root).toLowerCase()}/`);
  return i < 0 ? null : q.slice(i + path.basename(root).length + 2);
}

function streamFacts(ev, repo, mem, name) {
  const uses = blocksOf(ev, 'assistant', 'tool_use');
  const results = new Map(blocksOf(ev, 'user', 'tool_result').map((c) => [c.tool_use_id, c]));
  const ok = (u) => !results.get(u.id)?.is_error;
  const inRepo = (u) => relTo(repo, u.input?.file_path);
  const inMem = (u) => (mem ? relTo(mem, u.input?.file_path) : null);
  // D22 option (A): a write the gate denied changed nothing, so it is not the first write
  const gated = (u) => textOf(results.get(u.id)).includes('[project map] This is your first write in ');
  const isWrite = (u) => u.name === 'Write' && inRepo(u) && !gated(u);
  // "Before writing" is the first Write of <name>.tsx (any folder), else of any file whose path holds <name>.
  let anchor = uses.findIndex((u) => isWrite(u) && new RegExp(`(^|/)${name}\\.[jt]sx?$`).test(inRepo(u)));
  if (anchor < 0) anchor = uses.findIndex((u) => isWrite(u) && inRepo(u).includes(name));
  const before = anchor < 0 ? uses : uses.slice(0, anchor);
  const firstWrite = anchor < 0 ? null : Object.fromEntries(uses.slice(0, anchor + 1)
    .filter((u) => isWrite(u) && !(inRepo(u) in FIXTURE_FILES)).map((u) => [inRepo(u), u.input.content ?? '']));
  const memWrites = uses.filter((u) => ['Write', 'Edit', 'MultiEdit'].includes(u.name) && inMem(u) !== null);
  const refused = (u) => !ok(u) && /permission|denied|granted|not allowed|blocked/i.test(textOf(results.get(u.id)));
  return {
    anchor,
    firstWrite,
    toolCallsBefore: before.length,
    filesReadBefore: new Set(before.filter((u) => u.name === 'Read' && ok(u)).map((u) => norm(u.input?.file_path))).size,
    memReadBefore: before.filter((u) => u.name === 'Read' && ok(u) && inMem(u) !== null).map(inMem),
    mapReadBefore: before.some((u) => u.name === 'Read' && ok(u) && (inRepo(u) ?? '').startsWith('.project-map/')),
    memWrites: memWrites.length,
    memWritesRefused: memWrites.filter(refused).length,
    result: ev.findLast((e) => e.type === 'result'),
    model: ev.find((e) => e.type === 'system' && e.subtype === 'init')?.model,
  };
}

// ---------- running sessions ----------

function env() {
  const e = { ...process.env, MSYS_NO_PATHCONV: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k];
  return e;
}

function claude(cwd, prompt, raw, mem, plugin = false) {
  // User settings, plugins, MCP servers and skills stay out; Bash and the web are denied (static scoring, no network).
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'Bash,WebFetch,WebSearch,Skill', '--permission-mode', 'acceptEdits',
    '--output-format', 'stream-json', '--verbose', ...(mem ? ['--add-dir', mem] : []),
    ...(plugin ? ['--plugin-dir', PLUGIN, '--include-hook-events'] : [])];
  const r = spawnSync(CLAUDE, args, { cwd, input: prompt, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 256 << 20 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
}

// M2 (V2-D14): v2's capture instruction at every SessionStart, in place of auto memory
const CAPTURE_HOOKS = { SessionStart: [{ hooks: [{ type: 'command',
  command: `node "${path.join(HERE, '..', 'V2-D14-capture', 'instruction.mjs').replace(/\\/g, '/')}"` }] }] };

function makeRepo(dir, mem, hooks = null, map = null) {
  fs.cpSync(FIXTURE, dir, { recursive: true });
  if (map) fs.cpSync(map, path.join(dir, '.project-map'), { recursive: true }); // committed with the fixture: pulled by the next session
  const settings = mem ? { autoMemoryEnabled: true, autoMemoryDirectory: mem } : { autoMemoryEnabled: false, ...(hooks ? { hooks } : {}) };
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), `${JSON.stringify(settings, null, 2)}\n`);
  const git = (...a) => spawnSync('git', ['-c', 'user.name=eval', '-c', 'user.email=eval@example.invalid', ...a], { cwd: dir });
  git('init', '-q');
  git('add', '-A');
  git('commit', '-q', '-m', 'fixture');
}

const usage = (r) => ({
  costUsd: r?.total_cost_usd ?? null,
  inputTokens: r?.usage?.input_tokens ?? null,
  outputTokens: r?.usage?.output_tokens ?? null,
  cacheReadTokens: r?.usage?.cache_read_input_tokens ?? null,
  cacheWriteTokens: r?.usage?.cache_creation_input_tokens ?? null,
  turns: r?.num_turns ?? null,
  durationMs: r?.duration_ms ?? null,
});

function runOnce(scratch, arm, i) {
  const dir = path.join(scratch, `${arm}-run${i}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const rec = { arm, run: i, date: new Date().toISOString().slice(0, 10), invalid: [], sessions: {} };
  const plugin = arm === 'V2';
  const session = (name, prompt, repo, mem, anchorName) => {
    const ev = claude(repo, prompt, path.join(dir, `${name}.jsonl`), mem, plugin);
    const facts = streamFacts(ev, repo, mem, anchorName ?? '\0');
    const r = facts.result;
    if (!r || r.subtype !== 'success' || r.is_error) rec.invalid.push(`${name}: no success result`);
    if (facts.memWritesRefused) rec.invalid.push(`${name}: ${facts.memWritesRefused} memory write(s) refused`);
    if (facts.model && !facts.model.startsWith(MODEL)) rec.invalid.push(`${name}: ran on ${facts.model}`);
    if (plugin) { // 06, 2c: the plugin listed; one session start and one forced decision (A1 has no compaction)
      const out = (event, text) => ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === event && String(e.output ?? '').includes(text))
        .map((e) => JSON.parse(e.output).hookSpecificOutput.additionalContext);
      const starts = out('SessionStart', 'This project keeps a map');
      const forced = out('UserPromptSubmit', 'Before you start: for each directory');
      if (!ev.find((e) => e.subtype === 'init')?.plugins?.some((p) => p.name === 'second-brain')) rec.invalid.push(`${name}: plugin not loaded`);
      if (starts.length !== 1 || forced.length !== 1) rec.invalid.push(`${name}: plugin session start ${starts.length}, forced decision ${forced.length}`);
      facts.alwaysOnBytes = [...starts, ...forced].reduce((a, s) => a + Buffer.byteLength(s), 0);
    }
    rec.sessions[name] = { memoryWrites: facts.memWrites, ...usage(r) };
    return facts;
  };

  if (arm === 'M2') {
    // V2-D14: capture is scored on the map files after H3. T and N are not run here: their value measure needs
    // D22's delivery, and the first slice's eval runs them.
    const repoH = path.join(dir, 'repo-H');
    makeRepo(repoH, null, CAPTURE_HOOKS);
    for (const [name, prompt] of S.HISTORY) session(name, prompt, repoH, null);
    const map = walk(path.join(repoH, '.project-map'));
    rec.capture = scoreAll(C_ITEMS, Object.values(map).join('\n'));
    rec.provenance = provenanceOf(map);
    rec.map = Object.fromEntries(Object.entries(map).map(([p, t]) => [p, Buffer.byteLength(t)]));
    const st = spawnSync('git', ['status', '--porcelain', '-uall'], { cwd: repoH, encoding: 'utf8' }).stdout.split('\n').filter(Boolean).map((l) => l.slice(3));
    rec.changedOutsideMap = st.filter((p) => !p.startsWith('.project-map/') && p !== '.claude/settings.local.json').length;
    rec.commits = Number(spawnSync('git', ['rev-list', '--count', 'HEAD'], { cwd: repoH, encoding: 'utf8' }).stdout.trim());
    rec.costUsd = Object.values(rec.sessions).reduce((a, s) => a + (s.costUsd ?? 0), 0);
    rec.valid = rec.invalid.length === 0;
    return rec;
  }
  if (arm === 'V2') {
    // 06, 2c: H once with the plugin and auto memory; the user commits the map with the work; then T and N as the same
    // person (the map plus auto memory) and as a second person (the map only). Capture is scored on the map.
    const memH = path.join(dir, 'mem-H');
    fs.mkdirSync(memH);
    const repoH = path.join(dir, 'repo-H');
    makeRepo(repoH, memH);
    for (const [name, prompt] of S.HISTORY) session(name, prompt, repoH, memH);
    const gitH = (...a) => spawnSync('git', ['-c', 'user.name=eval', '-c', 'user.email=eval@example.invalid', ...a], { cwd: repoH, encoding: 'utf8' });
    gitH('add', '--', '.project-map');
    gitH('commit', '-q', '-m', 'map');
    const mapDir = path.join(repoH, '.project-map');
    const map = walk(mapDir);
    rec.capture = scoreAll(C_ITEMS, Object.values(map).join('\n'));
    rec.provenance = provenanceOf(map);
    rec.map = Object.fromEntries(Object.entries(map).map(([p, t]) => [p, Buffer.byteLength(t)]));
    rec.mapCommitted = gitH('ls-tree', '-r', '--name-only', 'HEAD', '--', '.project-map').stdout.split('\n').filter(Boolean).length;
    rec.store = Object.fromEntries(Object.entries(walk(memH)).map(([p, t]) => [p, Buffer.byteLength(t)])); // reported, not scored
    rec.variants = {};
    for (const who of ['same', 'second']) {
      const out = {};
      for (const [name, prompt, anchorName] of [['T', S.T, 'UserAvatar'], ['N', S.N, 'ProductImage']]) {
        const repo = path.join(dir, `repo-${name}-${who}`);
        const mem = who === 'same' ? path.join(dir, `mem-${name}-same`) : null;
        if (mem) fs.cpSync(memH, mem, { recursive: true });
        makeRepo(repo, mem, null, fs.existsSync(mapDir) ? mapDir : null);
        const facts = session(`${name}-${who}`, prompt, repo, mem, anchorName);
        const all = walk(repo, ['.git', '.claude', '.project-map']);
        out[name] = { facts, files: Object.fromEntries(Object.entries(all).filter(([p]) => !(p in FIXTURE_FILES))) };
      }
      const { T, N } = out;
      const test = { ...scoreAll(T_ITEMS, T.files), T5: T5(T.facts.result?.result ?? ''), T5f: T5F(T.facts.result?.result ?? '') };
      rec.variants[who] = {
        test,
        testAtFirstWrite: T.facts.firstWrite ? scoreAll(T_ITEMS, T.facts.firstWrite) : null,
        neighbour: scoreAll(N_ITEMS, N.files),
        chain: Object.fromEntries(Object.entries(CHAIN).map(([d, [c, t]]) => [d,
          !rec.capture[c] ? 'not kept' : !T.facts.mapReadBefore ? 'not loaded' : test[t] ? 'followed' : 'ignored'])),
        orientation: { toolCallsBeforeFirstWrite: T.facts.toolCallsBefore, filesReadBeforeFirstWrite: T.facts.filesReadBefore },
        alwaysOnBytes: T.facts.alwaysOnBytes,
        overAttribution: { T: overAttributed(T.facts.result?.result ?? '', `${Object.values(map).join('\n')}\n${S.T}`),
          N: overAttributed(N.facts.result?.result ?? '', `${Object.values(map).join('\n')}\n${S.N}`) },
        newFiles: { T: Object.keys(T.files), N: Object.keys(N.files) },
      };
    }
    rec.costUsd = Object.values(rec.sessions).reduce((a, s) => a + (s.costUsd ?? 0), 0);
    rec.valid = rec.invalid.length === 0;
    return rec;
  }
  let memH = null;
  if (arm === 'M1') {
    memH = path.join(dir, 'mem-H');
    fs.mkdirSync(memH);
    const repoH = path.join(dir, 'repo-H');
    makeRepo(repoH, memH);
    for (const [name, prompt] of S.HISTORY) session(name, prompt, repoH, memH);
  }
  const store = walk(memH ?? path.join(dir, 'none'));
  const storeText = Object.values(store).join('\n');
  const index = (store['MEMORY.md'] ?? '').split('\n').slice(0, 200).join('\n').slice(0, 25_000);

  const out = {};
  for (const [name, prompt, anchorName] of [['T', S.T, 'UserAvatar'], ['N', S.N, 'ProductImage']]) {
    const repo = path.join(dir, `repo-${name}`);
    const mem = memH && path.join(dir, `mem-${name}`);
    if (mem) fs.cpSync(memH, mem, { recursive: true });
    makeRepo(repo, mem);
    const facts = session(name, prompt, repo, mem, anchorName);
    const all = walk(repo, ['.git', '.claude']);
    out[name] = { facts, files: Object.fromEntries(Object.entries(all).filter(([p]) => !(p in FIXTURE_FILES))) };
  }

  const { T, N } = out;
  rec.capture = memH ? scoreAll(C_ITEMS, storeText) : null;
  rec.test = { ...scoreAll(T_ITEMS, T.files), T5: T5(T.facts.result?.result ?? ''), T5f: T5F(T.facts.result?.result ?? '') };
  rec.testAtFirstWrite = T.facts.firstWrite ? scoreAll(T_ITEMS, T.facts.firstWrite) : null;
  rec.neighbour = scoreAll(N_ITEMS, N.files);
  if (memH) {
    // Loaded = in the index that loads at start, or in a memory file T read before its first write.
    const loaded = [index, ...T.facts.memReadBefore.map((p) => store[p] ?? '')].join('\n');
    rec.chain = Object.fromEntries(Object.entries(CHAIN).map(([d, [c, t]]) => [d,
      !C_ITEMS[c](storeText) ? 'not kept' : !C_ITEMS[c](loaded) ? 'not loaded' : rec.test[t] ? 'followed' : 'ignored']));
    rec.store = Object.fromEntries(Object.entries(store).map(([p, t]) => [p, Buffer.byteLength(t)]));
  }
  rec.orientation = { toolCallsBeforeFirstWrite: T.facts.toolCallsBefore, filesReadBeforeFirstWrite: T.facts.filesReadBefore };
  rec.alwaysOnBytes = Buffer.byteLength(index);
  rec.newFiles = { T: Object.keys(T.files), N: Object.keys(N.files) };
  rec.costUsd = Object.values(rec.sessions).reduce((a, s) => a + (s.costUsd ?? 0), 0);
  rec.valid = rec.invalid.length === 0;
  return rec;
}

function epoch(arm) {
  const h = crypto.createHash('sha256');
  for (const p of Object.keys(FIXTURE_FILES).sort()) h.update(p).update(FIXTURE_FILES[p]);
  h.update(fs.readFileSync(path.join(HERE, 'sessions.mjs'), 'utf8').replace(/\r\n/g, '\n'));
  const cli = spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout.trim();
  // V2: the plugin's product files too, so a plugin change between runs is a new epoch (06, 2c)
  const p = crypto.createHash('sha256');
  const pf = walk(PLUGIN, ['test']);
  for (const f of Object.keys(pf).sort()) p.update(f).update(pf[f]);
  return { cli, model: MODEL, inputs: h.digest('hex').slice(0, 12), ...(arm === 'V2' ? { plugin: p.digest('hex').slice(0, 12) } : {}) };
}

// ---------- smoke check ----------

function smoke() {
  const fail = [];
  const gold = {
    T: walk(path.join(HERE, 'gold', 'T')),
    N: walk(path.join(HERE, 'gold', 'N')),
    reply: fs.readFileSync(path.join(HERE, 'gold', 'T-reply.txt'), 'utf8'),
    mem: Object.values(walk(path.join(HERE, 'gold', 'memory'))).join('\n'),
  };
  const score = (x) => ({ ...scoreAll(T_ITEMS, x.T), T5: T5(x.reply), T5f: T5F(x.reply), ...scoreAll(N_ITEMS, x.N), ...scoreAll(C_ITEMS, x.mem) });
  const A = 'src/components/UserAvatar/UserAvatar.tsx';
  const P = 'src/components/ProductImage/ProductImage.tsx';
  const move = (files, from, to) => { files[to] = files[from]; delete files[from]; };
  const sub = (x, key, file, a, b) => {
    const t = file ? x[key][file] : x[key];
    if (!t.includes(a)) throw new Error(`plant text missing: ${a}`);
    if (file) x[key][file] = t.replaceAll(a, b); else x[key] = t.replaceAll(a, b);
  };
  // Each planted wrong output must fail its own item and no other.
  const PLANTS = [
    ['T1', (x) => move(x.T, A, 'src/components/UserAvatar.tsx')],
    ['T1', (x) => { x.T['src/widgets/UserAvatar.tsx'] = x.T[A]; }],
    ['T2', (x) => sub(x, 'T', A, 'display: ', "boxShadow: '0 0 2px rgb(0 0 0 / 10%)', display: ")],
    ['T3', (x) => sub(x, 'T', A, 'large: 64', 'large: 56')],
    ['T4', (x) => sub(x, 'T', A, '<Img local ', '<Img ')],
    ['T4', (x) => sub(x, 'T', A, 'path={user.avatarPath}', 'path={user.avatarCdnUrl ?? user.avatarPath}')],
    [['T5', 'T5f'], (x) => sub(x, 'reply', null, "designer's ", '')],
    [['T5', 'T5f'], (x) => sub(x, 'reply', null, "the lead developer's decision", 'agreed earlier')],
    [['T5', 'T5f'], (x) => { sub(x, 'reply', null, "the PM's note on the client's decision", 'a later note'); sub(x, 'reply', null, "the client's style guide", 'the style guide'); }],
    ['T5', (x) => sub(x, 'reply', null, "the lead developer's decision", "the team meeting's decision")], // D23: faithful, so T5f holds
    ['N1', (x) => move(x.N, P, 'src/components/ProductImage.tsx')],
    ['N2', (x) => sub(x, 'N', P, "objectFit: 'cover'", "objectFit: 'cover', background: 'white'")],
    ['N3', (x) => sub(x, 'N', P, '<Img path', '<Img local path')],
    ['C1', (x) => sub(x, 'mem', null, 'style guide', 'rules')],
    ['C2', (x) => sub(x, 'mem', null, '64', '56')],
    ['C3', (x) => sub(x, 'mem', null, 'CDN', 'remote host')],
    ['C4', (x) => { x.mem += '\nThe dev server runs on port 4100 today.'; }],
  ];
  for (const [k, v] of Object.entries(score(gold))) if (!v) fail.push(`gold fails ${k}`);
  for (const [item, plant] of PLANTS) {
    const x = structuredClone(gold);
    plant(x);
    const wrong = Object.entries(score(x)).filter(([k, v]) => v !== ![].concat(item).includes(k)).map(([k]) => k);
    if (wrong.length) fail.push(`plant for ${item} misscored: ${wrong.join(', ')}`);
  }
  for (const [name, p] of S.HISTORY) if (S.CUE_WORDS.test(p)) fail.push(`${name} holds a cue word`);
  for (const [name, p] of [['T', S.T], ['N', S.N]]) if (S.ANSWER_TOKENS.test(p)) fail.push(`${name} holds an answer token`);
  if (!S.CUE_WORDS.test('Please remember this.') || !S.ANSWER_TOKENS.test('Load it from the CDN.')) fail.push('prompt checks miss a plant');

  // Stream facts on a synthetic stream: a refused memory write, a memory read before the first write, the anchor.
  const tu = (name, id, input) => ({ type: 'assistant', message: { content: [{ type: 'tool_use', name, id, input }] } });
  const tr = (id, isError, content) => ({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id, is_error: isError, content }] } });
  const R = 'C:\\x\\repo-T\\src\\components\\UserAvatar\\';
  const f = streamFacts([
    tu('Read', 'r1', { file_path: 'C:\\x\\mem-T\\avatar-look.md' }), tr('r1', false, 'ok'),
    tu('Write', 'm1', { file_path: 'C:/x/mem-T/new.md', content: 'x' }),
    tr('m1', true, "Claude requested permissions to write to C:/x/mem-T/new.md, but you haven't granted it yet."),
    tu('Edit', 'm2', { file_path: 'C:/x/mem-T/MEMORY.md' }), tr('m2', true, 'String to replace not found in file.'),
    tu('Read', 'r2', { file_path: 'c:/x/repo-T/src/theme/tokens.ts' }), tr('r2', false, 'ok'),
    tu('Write', 'w1', { file_path: `${R}styles.ts`, content: 'a' }),
    tu('Write', 'w2', { file_path: `${R}UserAvatar.tsx`, content: 'b' }),
    tu('Write', 'w3', { file_path: `${R}index.ts`, content: 'c' }),
    { type: 'result', subtype: 'success', is_error: false },
  ], 'C:/x/repo-T', 'C:/x/mem-T', 'UserAvatar');
  const want = { anchor: 5, toolCallsBefore: 5, filesReadBefore: 2, memWrites: 2, memWritesRefused: 1 };
  for (const [k, v] of Object.entries(want)) if (f[k] !== v) fail.push(`stream fact ${k}: ${f[k]}, want ${v}`);
  if (JSON.stringify(f.memReadBefore) !== '["avatar-look.md"]') fail.push(`memReadBefore: ${JSON.stringify(f.memReadBefore)}`);
  if (JSON.stringify(Object.keys(f.firstWrite ?? {})) !== JSON.stringify(['src/components/UserAvatar/styles.ts', 'src/components/UserAvatar/UserAvatar.tsx'])) {
    fail.push(`firstWrite: ${JSON.stringify(Object.keys(f.firstWrite ?? {}))}`);
  }
  console.log(fail.length ? `SMOKE FAIL\n${fail.join('\n')}` : `smoke ok: gold passes ${Object.keys(score(gold)).length} items, ${PLANTS.length} plants fail only their own item, prompts and stream facts check out`);
  return fail.length === 0;
}

// ---------- summary over the valid runs of each arm (the input to the thresholds rule) ----------

function summary() {
  const med = (a) => { const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
  const stat = (a) => ({ median: med(a), min: Math.min(...a), max: Math.max(...a), spread: Math.max(...a) - Math.min(...a) });
  const out = {};
  // V2 (06, 2c) is summarised per variant: each variant's T and N stand where M1's do
  const groups = ['M0', 'M1', 'V2'].flatMap((arm) => {
    const f = path.join(HERE, 'results', `${arm}${TAG}.json`);
    if (!fs.existsSync(f)) return [];
    const all = JSON.parse(fs.readFileSync(f, 'utf8')).runs;
    if (arm !== 'V2') return [[arm, arm, all, all.filter((r) => r.valid)]];
    return ['same', 'second'].map((who) => [`V2-${who}`, arm, all, all.filter((r) => r.valid)
      .map((r) => ({ ...r, ...r.variants[who], sessions: { ...r.sessions, T: r.sessions[`T-${who}`] } }))]);
  });
  for (const [key, arm, all, runs] of groups) {
    const count = (key) => runs.reduce((o, r) => {
      for (const [k, v] of Object.entries(r[key] ?? {})) o[k] = (o[k] ?? 0) + (v === true ? 1 : 0);
      return o;
    }, {});
    const t = (r) => r.sessions.T;
    out[key] = {
      runs: all.length,
      validRuns: runs.length,
      epochs: [...new Set(runs.map((r) => JSON.stringify(r.epoch)))].map((e) => JSON.parse(e)),
      capture: arm !== 'M0' ? count('capture') : null,
      test: count('test'),
      testAtFirstWrite: count('testAtFirstWrite'),
      neighbour: count('neighbour'),
      allTestAndNeighbourPass: runs.filter((r) => [...Object.values(r.test), ...Object.values(r.neighbour)].every(Boolean)).length,
      chain: arm !== 'M0' ? runs.reduce((o, r) => {
        for (const [d, c] of Object.entries(r.chain)) (o[d] ??= {})[c] = (o[d][c] ?? 0) + 1;
        return o;
      }, {}) : null,
      metrics: {
        toolCallsBeforeFirstWrite: stat(runs.map((r) => r.orientation.toolCallsBeforeFirstWrite)),
        filesReadBeforeFirstWrite: stat(runs.map((r) => r.orientation.filesReadBeforeFirstWrite)),
        tTokensTotal: stat(runs.map((r) => t(r).inputTokens + t(r).outputTokens + t(r).cacheReadTokens + t(r).cacheWriteTokens)),
        tOutputTokens: stat(runs.map((r) => t(r).outputTokens)),
        tCostUsd: stat(runs.map((r) => t(r).costUsd)),
        alwaysOnBytes: stat(runs.map((r) => r.alwaysOnBytes)),
        memoryWritesH1toH3: stat(runs.map((r) => ['H1', 'H2', 'H3'].reduce((a, h) => a + (r.sessions[h]?.memoryWrites ?? 0), 0))),
        runCostUsd: stat(runs.map((r) => r.costUsd)),
      },
    };
  }
  // D17's rule (05, Thresholds): a count or token median beats M1's by more than M1's spread (where the spread is at
  // least the median, no gain is claimed: at most median plus spread); orientation passes on either cell; a pass item
  // needs M1's count of runs, 8 where M1 had 0
  const m1 = out.M1;
  for (const k of ['V2-same', 'V2-second']) {
    const v = out[k];
    if (!v || !m1) continue;
    const metric = (n) => { const a = m1.metrics[n]; const b = v.metrics[n].median; return a.median - a.spread > 0 ? b < a.median - a.spread : b <= a.median + a.spread; };
    const items = (part) => Object.fromEntries(Object.entries(m1[part]).map(([i, c]) => [i, (v[part][i] ?? 0) >= (c === 0 ? 8 : c)]));
    v.verdict = { capture: items('capture'), test: items('test'), testAtFirstWrite: items('testAtFirstWrite'), neighbour: items('neighbour'),
      orientation: metric('toolCallsBeforeFirstWrite') || metric('filesReadBeforeFirstWrite'),
      // D23: runs in which the T or N reply names a source role its map and prompt do not hold (at most 1 of 10)
      overAttributedRuns: (groups.find(([g]) => g === k)?.[3] ?? []).filter((r) => r.overAttribution && (r.overAttribution.T.length || r.overAttribution.N.length)).length,
      cost: Object.fromEntries(['tTokensTotal', 'tOutputTokens', 'tCostUsd'].map((n) => [n, metric(n)])) };
  }
  fs.writeFileSync(path.join(HERE, 'results', `summary${TAG}.json`), `${JSON.stringify(out, null, 2)}\n`);
  console.log(JSON.stringify(out, null, 2));
}

// ---------- main ----------

if (process.argv[2] === '--smoke') process.exit(smoke() ? 0 : 1);
if (process.argv[2] === '--summary') process.exit(summary() ?? 0);
// V2-D23: T5f (and, for V2, over-attribution) added to stored records from their raw T and N replies; T5 is untouched.
//   node eval.mjs --rescore <results file> <scratch-dir of its runs>
if (process.argv[2] === '--rescore') {
  const [file, scratch] = process.argv.slice(3);
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
  const reply = (run, name) => { const f = path.join(scratch, `${run.arm}-run${run.run}`, `${name}.jsonl`); return fs.existsSync(f) ? parse(fs.readFileSync(f, 'utf8')).findLast((e) => e.type === 'result')?.result ?? '' : null; };
  for (const r of saved.runs.filter((x) => x.valid)) {
    if (r.test) r.test.T5f = T5F(reply(r, 'T') ?? '');
    for (const [who, v] of Object.entries(r.variants ?? {})) {
      const map = Object.values(walk(path.join(scratch, `${r.arm}-run${r.run}`, 'repo-H', '.project-map'))).join('\n');
      v.test.T5f = T5F(reply(r, `T-${who}`) ?? '');
      v.overAttribution = { T: overAttributed(reply(r, `T-${who}`) ?? '', `${map}\n${S.T}`), N: overAttributed(reply(r, `N-${who}`) ?? '', `${map}\n${S.N}`) };
    }
  }
  fs.writeFileSync(file, `${JSON.stringify(saved, null, 2)}\n`);
  console.log(JSON.stringify(saved.runs.filter((x) => x.valid).map((r) => r.variants ? Object.fromEntries(Object.entries(r.variants).map(([w, v]) => [w, { T5: v.test.T5, T5f: v.test.T5f, over: v.overAttribution }])) : { T5: r.test.T5, T5f: r.test.T5f })));
  process.exit(0);
}
const [scratch, arm, runs = '1', first = '1'] = process.argv.slice(2);
if (!scratch || !['M0', 'M1', 'M2', 'V2'].includes(arm)) throw new Error('usage: node eval.mjs <scratch-dir> <M0|M1|M2|V2> [runs] [first]  |  --smoke');
if (!smoke()) throw new Error('smoke check failed: no run before it passes');
const ep = epoch(arm);
const file = path.join(HERE, 'results', `${arm}${TAG}.json`);
const saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { plan: '../../05-eval-plan.md', runs: [] };
for (let i = Number(first); i < Number(first) + Number(runs); i++) {
  let rec;
  try {
    rec = { ...runOnce(path.resolve(scratch), arm, i), epoch: ep };
  } catch (e) {
    rec = { arm, run: i, epoch: ep, valid: false, invalid: [`harness error: ${e.message}`] };
  }
  saved.runs = [...saved.runs.filter((r) => r.run !== i), rec].sort((a, b) => a.run - b.run);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(saved, null, 2)}\n`);
  const pass = (o) => (o ? Object.entries(o).map(([k, v]) => `${k}${v ? '+' : '-'}`).join(' ') : '-');
  console.log(`${arm} run ${i}: ${rec.valid ? 'valid' : `INVALID (${rec.invalid.join('; ')})`}; $${rec.costUsd?.toFixed(2)}`);
  console.log(`  capture ${pass(rec.capture)} | test ${pass(rec.test)} | first write ${pass(rec.testAtFirstWrite)} | neighbour ${pass(rec.neighbour)}`);
  if (rec.chain) console.log(`  chain ${JSON.stringify(rec.chain)}`);
  for (const [who, v] of Object.entries(rec.variants ?? {})) console.log(`  ${who}: test ${pass(v.test)} | first write ${pass(v.testAtFirstWrite)} | neighbour ${pass(v.neighbour)} | chain ${JSON.stringify(v.chain)}`);
}
