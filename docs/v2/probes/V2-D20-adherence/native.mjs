// V2-D20 stage 1: Claude in a test-bed repo as it is run today (its own CLAUDE.md, rules, skills and hooks; no
// memory, no plugin). Tasks and rules come from a private config, so this folder holds no private text; per-run
// detail is written next to the config, and only counts come back here (results/summary.json).
//   node native.mjs checks  <config>                   every rule's check against its correct and wrong sample
//   node native.mjs smoke   <config> <task>            one cheap session: checks the plumbing, not the model
//   node native.mjs run     <config> <task> [runs] [first] [arm]
//   node native.mjs summary <config>
// Stage 2 (arm b: delivery, d: delivery + checks + account; deliver.mjs) writes to d20-stage2/<arm>/:
//   node native.mjs arrival  <config> <task> [runs]   nonce smoke of the three hook channels D12 did not probe
//   node native.mjs summary2 <config>                 writes results/summary-stage2.json (counts only)
// Stage 3 (V2-D20, reopened): one session in turns (investigate, /compact, make the change); arms n, o0, oc, then
// or, od, ow (see SESSION). `run` and `smoke` take these arms like any other.
// Build step 2b: arms sba, sbn and sbmc are the M1 arms a, n and mc plus the v2 plugin, loaded by --plugin-dir.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { check, changedFiles, slash } from './check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, cfgArg, taskId, runs = '1', first = '1', arm = 'a'] = process.argv.slice(2);
const cfgPath = path.resolve(cfgArg);
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
// a pinned binary holds the epoch: the installed `claude` updates itself between runs, auto-updater off or not
const CLAUDE = cfg.claude ?? 'claude';
const PLUGIN = path.join(HERE, '..', '..', '..', '..', 'plugin');
const STAGE1 = path.join(path.dirname(cfgPath), 'd20-stage1');
// cfg.outDir keeps a re-run under another setup (V2-D22: P2 with the web on) apart from the runs it repeats
const OUT = arm === 'a' ? STAGE1 : path.join(path.dirname(cfgPath), cfg.outDir ?? 'd20-stage2', arm);
const task = cfg.tasks.find((t) => t.id === taskId) ?? (['checks', 'summary', 'summary2', 'scale', 'summary3', 'rebase', 'verdict', 'recheck'].includes(mode) ? null : process.exit(2));

const env = (extra = {}) => {
  const e = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1', ...extra };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k];
  return e;
};
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', env: env(), maxBuffer: 256 << 20, ...opts });
const git = (cwd, ...a) => run('git', ['-c', 'core.longpaths=true', ...a], { cwd });
const rel = (dir, p) => {
  const q = slash(p);
  const i = q.toLowerCase().indexOf(`/${path.basename(dir).toLowerCase()}/`);
  return i >= 0 ? q.slice(i + path.basename(dir).length + 2) : q && !path.isAbsolute(q) ? q : null;
};
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
// content is a string on the user turns of a multi-turn session (stage 3)
const blocks = (ev, role, type) => ev.flatMap((e) => (e.type === role && Array.isArray(e.message?.content) ? e.message.content.filter((c) => c.type === type) : []));
const median = (a) => { const s = a.filter((x) => x != null).sort((x, y) => x - y); return s.length ? s[(s.length - 1) >> 1] : null; };

// ---------- one session in a fresh worktree ----------

// hooks: extra hook groups by event, merged into the run's settings beside the InstructionsLoaded logger
function makeRun(dir, log, hooks = {}, mem = null) {
  // force twice: a run cut off inside `worktree add` leaves its worktree locked
  git(task.repo, 'worktree', 'remove', '--force', '--force', dir);
  fs.rmSync(dir, { recursive: true, force: true });
  git(task.repo, 'worktree', 'prune'); // a remove that failed leaves the folder gone but still registered
  // chains on one repo start together (stage 3 on); git's worktree lock then fails one of them, so retry
  let r = git(task.repo, 'worktree', 'add', '-q', '--detach', dir, task.commit);
  for (let k = 0; k < 5 && r.status !== 0; k++) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000 + 2000 * k);
    fs.rmSync(dir, { recursive: true, force: true });
    r = git(task.repo, 'worktree', 'add', '-q', '--detach', dir, task.commit);
  }
  if (r.status !== 0) throw new Error(`worktree: ${r.stderr}`);
  for (const s of task.setup ?? []) { // a review task plants its change, uncommitted
    const f = path.join(dir, s.file);
    const t = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
    if (s.find && !t.includes(s.find)) throw new Error(`setup: text not found in ${s.file}`);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, s.find ? t.replace(s.find, s.replace) : s.content);
  }
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), `${JSON.stringify({ autoMemoryEnabled: !!mem, ...(mem && { autoMemoryDirectory: mem }),
    hooks: { InstructionsLoaded: [{ hooks: [nodeHook('log.mjs', log)] }], ...hooks } }, null, 2)}\n`);
}
const nodeHook = (script, ...args) => ({ type: 'command', command: ['node', path.join(HERE, script), ...args].map((x) => (x === 'node' ? x : `"${slash(x)}"`)).join(' ') });

// Arm (b): prompt arrival and a one-time deny before the first write in an area; (d) adds checks after writes and Stop.
function armHooks(base) {
  if (['a', 'm', 'mc', 'n', 'n0', 'sba', 'sbn', 'sbmc', 'sbv', 'sbc2', 'sbs'].includes(arm)) return {};
  if (['p', 'pf', 'pfc', 'pfr', 'pfrs', 'pfro'].includes(arm)) { // V2-D22 pull: the documents' index with Vercel's instruction, always on from session start
    const hook = path.join('..', 'V2-D21-inventory', 'inventory-hook.mjs');
    fs.copyFileSync(task.index, path.join(base, 'inventory.txt'));
    if (arm !== 'p') fs.writeFileSync(path.join(base, 'force.txt'), FORCE); // attempt 2: a forced decision, once
    // pfc, pfr: the index again after a compaction; pfr: the forced text again at the first prompt after it
    // pfrs, pfro (V2-D20 net): pfr plus a self-review at Stop, or the pattern checks fed back; their cards are the
    // task's pattern rules, for logging (pfrs) or feedback (pfro), never shown at a prompt
    const net = ['pfrs', 'pfro'].includes(arm);
    if (net) fs.writeFileSync(path.join(base, 'cards.json'), JSON.stringify({ arm, cards: task.rules.filter((r) => r.card.cls === 'pattern' && (arm !== 'pfro' || (task.netRules ?? []).includes(r.id))).map((r) => ({ id: r.id, ...r.card, check: r.check })) }, null, 1));
    const d = { hooks: [nodeHook('deliver.mjs', base)] };
    return { SessionStart: [{ matcher: SESSION[arm] ? 'startup|compact' : 'startup', hooks: [nodeHook(hook, base)] }],
      ...(arm !== 'p' ? { UserPromptSubmit: [{ hooks: [nodeHook(hook, base, 'force.txt', ...(['pfr', 'pfrs', 'pfro'].includes(arm) ? ['epoch'] : []))] }] } : {}),
      ...(net ? { Stop: [d] } : {}), ...(arm === 'pfro' ? { PostToolUse: [{ matcher: 'Write|Edit|MultiEdit', ...d }] } : {}) };
  }
  if (arm.startsWith('r')) { // V2-D22, the user's route (r: run 2, r3: keyed to the file read): push, then on read
    fs.copyFileSync(task.route, path.join(base, 'route.json'));
    const h = { hooks: [nodeHook(path.join('..', 'V2-D22-selection', 'onread.mjs'), base)] };
    return { UserPromptSubmit: [h], PostToolUse: [{ matcher: 'Read', ...h }] };
  }
  if (arm === 'i') { // V2-D21 (b): a path inventory, precomputed, delivered as it is when the prompt arrives
    fs.copyFileSync(task.inventory, path.join(base, 'inventory.txt'));
    return { UserPromptSubmit: [{ hooks: [nodeHook(path.join('..', 'V2-D21-inventory', 'inventory-hook.mjs'), base)] }] };
  }
  if (arm === 'ph') { // V2-D22 high-recall push: session i gets pick i's entries (route.mjs highrecall, phcards), at the first prompt
    const pick = JSON.parse(fs.readFileSync(task.phCards, 'utf8'))[Number(path.basename(base).slice(3)) - 1];
    const line = (c) => `- ${c.id} (${c.area}): ${c.text} [source: ${c.source}]\n`;
    const chunks = [];
    for (const [n, c] of pick.map((x, k) => [k, { id: `E${String(k + 1).padStart(3, '0')}`, ...x }])) {
      if (!n || chunks.at(-1).reduce((a, x) => a + line(x).length, 0) + line(c).length > 8500) chunks.push([]);
      chunks.at(-1).push(c);
    }
    fs.writeFileSync(path.join(base, 'cards.json'), JSON.stringify({ arm, cards: [], chunks, delivered: pick.length }, null, 1));
    return { UserPromptSubmit: [{ hooks: chunks.map((_, k) => nodeHook('deliver.mjs', base, String(k))) }] };
  }
  const d ={ hooks: [nodeHook('deliver.mjs', base)] };
  const writes = { matcher: 'Write|Edit|MultiEdit', ...d };
  fs.writeFileSync(path.join(base, 'cards.json'), JSON.stringify({ arm,
    cards: task.rules.map((r) => ({ id: r.id, ...r.card, check: r.check })) }, null, 1));
  if (arm.startsWith('v')) { // V2-D22 volume: binding cards plus the task's filler to ~N KB, neutral ids, seeded order
    const kb = Number(arm.slice(1)) * 1000;
    const line = (c) => `- E000 (${c.area}): ${c.text} [source: ${c.source}]\n`;
    let bytes = task.rules.reduce((a, r) => a + Buffer.byteLength(line(r.card)), 0);
    const fill = [];
    for (const c of task.fill) { if (bytes + Buffer.byteLength(line(c)) > kb) break; bytes += Buffer.byteLength(line(c)); fill.push(c); }
    const seed = path.basename(base);
    const all = [...task.rules.map((r) => ({ ...r.card, rule: r.id })), ...fill]
      .map((c) => ({ c, k: crypto.createHash('sha256').update(`${seed}|${c.rule ?? c.key}`).digest('hex') })).sort((a, b) => a.k.localeCompare(b.k))
      .map(({ c }, n) => ({ id: `E${String(n + 1).padStart(3, '0')}`, area: c.area, text: c.text, source: c.source, ...(c.rule ? { rule: c.rule } : {}) }));
    const chunks = [];
    for (const c of all) { // each hook output stays under the 10,000-character additionalContext cap
      if (!chunks.length || chunks.at(-1).reduce((a, x) => a + line(x).length, 0) + line(c).length > 8500) chunks.push([]);
      chunks.at(-1).push(c);
    }
    fs.writeFileSync(path.join(base, 'cards.json'), JSON.stringify({ arm, cards: [], chunks,
      positions: Object.fromEntries(all.flatMap((c, n) => (c.rule ? [[c.rule, n + 1]] : []))), delivered: all.length }, null, 1));
    return { UserPromptSubmit: [{ hooks: chunks.map((_, k) => nodeHook('deliver.mjs', base, String(k))) }] };
  }
  // stage 3: the cards once, at the first prompt (deliver.mjs); stage 2 of it adds one path to oc
  if (arm.startsWith('o')) return { UserPromptSubmit: [d], ...({ or: { SessionStart: [{ matcher: 'compact', ...d }] },
    od: { PostToolUse: [writes], Stop: [d] }, ow: { PreToolUse: [writes] } }[arm] ?? {}) };
  return { UserPromptSubmit: [d], PreToolUse: [writes], ...(arm === 'd' ? { PostToolUse: [writes], Stop: [d] } : {}) };
}

// Skills stay on (they are how these repos hold knowledge); Bash and the web are off: no installs, static scoring.
// cfg.web turns the web on, pre-approved, since a headless session cannot answer a permission prompt.
const claudeArgs = (model, deny = cfg.web ? 'Bash' : 'Bash,WebFetch,WebSearch', addDir = null) => ['-p', '--model', model,
  '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', deny, '--permission-mode', 'acceptEdits',
  ...(cfg.web ? ['--allowedTools', 'WebSearch,WebFetch'] : []),
  '--output-format', 'stream-json', '--verbose', '--include-hook-events', ...(addDir ? ['--add-dir', addDir] : []),
  ...(arm.startsWith('sb') ? ['--plugin-dir', PLUGIN] : [])];

function claude(cwd, prompt, model, raw, extraEnv = {}, deny = undefined, addDir = null) {
  const r = spawnSync(CLAUDE, claudeArgs(model, deny, addDir),
    { cwd, input: prompt, timeout: 1_800_000, encoding: 'utf8', env: env(extraEnv), maxBuffer: 256 << 20 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
}

// Stage 3: arm -> whether its session compacts. One session in turns, each sent after the previous result (D12's way).
const SESSION = { n: true, o0: false, oc: true, or: true, od: true, ow: true, v8: false, v32: false, n0: false, p: false, pf: false, ph: false, pfc: true, pfr: true, pfrs: true, pfro: true, mc: true, sbn: true, sbmc: true };
const NO_CARDS = ['n', 'n0', 'p', 'pf', 'pfc', 'pfr', 'pfrs', 'pfro', 'mc', 'sba', 'sbn', 'sbmc', 'sbv', 'sbc2', 'sbs', 'nc2']; // session arms that push no rule card
// V2-D22 pull, attempt 2: fixed before it ran (DECISIONS.md)
const FORCE = 'Before you start: for each directory in this project\'s document index, state in one line whether its '
  + 'documents bear on this task (yes or no). Then read the documents in every directory you marked yes before you '
  + 'change anything.';
const turnsOf = (prompt, compact) => [`${prompt}\n\nBefore changing anything, investigate what this task needs and `
  + 'report what you found. Do not create or edit any file yet.', ...(compact ? ['/compact'] : []), 'Now make the change.'];
// 06, 2e: the added shapes, with the plugin and the build task's own setup (memory where its M1 arm has it). quiet: the
// result up to which no write may happen (the last turn that says not to edit; none in the vague shape)
const SHAPES = {
  sbv: { turns: (t) => [cfg.vague[t.id], t.prompt], quiet: 0, compactions: 0 }, // cfg.vague: kept out of the task, whose JSON is the epoch's input hash
  sbc2: { turns: (t) => [turnsOf(t.prompt, true)[0], '/compact', 'List the files you will change and why. Do not edit anything yet.', '/compact', 'Now make the change.'], quiet: 3, compactions: 2 },
  sbs: { turns: (t) => [cfg.tasks.find((o) => o.repo === t.repo && o.id !== t.id).prompt, ...turnsOf(t.prompt, true)], quiet: 2, quietFrom: 1, compactions: 1 }, // the first task has no no-edit instruction
};
SHAPES.nc2 = { ...SHAPES.sbc2 }; // D22 rethink 4: native (no plugin) in two compactions, the control for P2's R6
const RECHECK = 'If this message asks you to change'; // D22 rethink 4: the plugin's later-prompt text begins so
function claudeTurns(cwd, turns, model, raw, addDir = null) {
  return new Promise((resolve) => {
    const child = spawn(CLAUDE, [...claudeArgs(model, undefined, addDir), '--input-format', 'stream-json'], { cwd, env: env() });
    let out = '';
    let buf = '';
    let i = 0;
    const send = () => {
      if (i < turns.length) child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: turns[i++] } })}\n`);
      else child.stdin.end();
    };
    child.stdout.on('data', (d) => {
      out += d;
      buf += d;
      for (let n = buf.indexOf('\n'); n >= 0; n = buf.indexOf('\n')) {
        const line = buf.slice(0, n);
        buf = buf.slice(n + 1);
        if (parse(line)[0]?.type === 'result') send();
      }
    });
    let err = '';
    child.stderr.on('data', (d) => { err += d; });
    const timer = setTimeout(() => child.kill(), 3_600_000);
    child.on('close', () => { clearTimeout(timer); fs.writeFileSync(raw, out + (err ? `\n#stderr ${err}` : '')); resolve(parse(out)); });
    send();
  });
}

// ---------- scoring ----------

// The reply as scored. With a Stop block (arm d), the answer Claude gave before it plus what it wrote after, with the
// "## Rule account" section cut, so naming a rule's source in the account cannot pass a reply check. A missing heading
// leaves only the answer before the block.
function replyOf(ev) {
  const res = ev.findLast((e) => e.type === 'result')?.result ?? '';
  const at = ev.findIndex((e) => e.type !== 'assistant' && JSON.stringify(e).includes('[d20-stop]'));
  if (at < 0) return { reply: res, accountHeading: null };
  const text = (e) => (e.message?.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
  const pre = text(ev.slice(0, at).findLast((e) => e.type === 'assistant' && text(e)) ?? {});
  const post = ev.slice(at).filter((e) => e.type === 'assistant').map(text).filter(Boolean).join('\n');
  const cut = post.search(/^#+\s*Rule account\b/im);
  return { reply: cut < 0 ? pre : `${pre}\n${post.slice(0, cut)}`, accountHeading: cut >= 0 };
}

function facts(ev, dir, logFile, base) {
  const uses = blocks(ev, 'assistant', 'tool_use');
  const relOf = (u) => rel(dir, u.input?.file_path ?? u.input?.path);
  // A write the delivery hook denied did not happen: it is neither the anchor nor the first write (kept apart below).
  const denied = new Set(blocks(ev, 'user', 'tool_result')
    .filter((c) => c.is_error && JSON.stringify(c.content).includes('[d20-deny]')).map((c) => c.tool_use_id));
  const isWrite = (u) => ['Write', 'Edit', 'MultiEdit'].includes(u.name) && relOf(u) && !denied.has(u.id);
  let anchor = uses.findIndex((u) => isWrite(u) && (!task.anchor || new RegExp(task.anchor).test(relOf(u))));
  if (anchor < 0) anchor = uses.findIndex(isWrite);
  const upTo = anchor < 0 ? uses.length : anchor;
  // What Claude saw (tool results, hook output, system text), each placed at the tool call it followed (-1: none yet).
  const seen = [];
  let last = -1;
  for (const e of ev) {
    if (e.type === 'assistant') {
      for (const c of e.message?.content ?? []) if (c.type === 'tool_use') last = uses.indexOf(c);
    } else if (e.type === 'user' || (e.type === 'system' && e.subtype !== 'init')) seen.push([last, JSON.stringify(e)]);
  }
  const loads = fs.existsSync(logFile) ? parse(fs.readFileSync(logFile, 'utf8')) : [];
  const loadAt = (l) => {
    if (!l.trigger_file_path) return /session_start|nested_traversal|include|compact/.test(l.load_reason ?? '') ? -1 : Infinity;
    const trig = (rel(dir, l.trigger_file_path) ?? '').toLowerCase();
    const i = uses.findIndex((u) => (relOf(u) ?? '').toLowerCase() === trig);
    return i < 0 ? Infinity : i; // a rule loaded by a write arrives with that write, not before it (D12)
  };
  const firstWrite = {};
  for (const u of uses.slice(0, anchor + 1)) if (u.name === 'Write' && isWrite(u)) firstWrite[relOf(u)] = u.input.content ?? '';
  // What Claude meant to write before the pre-write delivery reached it: the first denied Write per file.
  const deniedWrite = {};
  for (const u of uses) if (u.name === 'Write' && denied.has(u.id) && !(relOf(u) in deniedWrite)) deniedWrite[relOf(u)] = u.input.content ?? '';
  const dlog = path.join(base, 'deliveries.jsonl');
  const deliveries = fs.existsSync(dlog) ? parse(fs.readFileSync(dlog, 'utf8')) : [];
  const atPrompt = new Set(deliveries.filter((d) => d.ev === 'UserPromptSubmit').flatMap((d) => d.cards ?? []));
  return {
    uses, anchor, upTo, loads, deliveries, deniedWrite, firstWrite: anchor < 0 ? null : firstWrite,
    // index of the tool call by which the rule was in context; -1 = at start, Infinity = never
    contextAt(rule) {
      const at = atPrompt.has(rule.id) ? [-1] : [];
      // a source may name a heading ("path › heading"); a read is of its file
      const src = (rule.source ?? '\0').split(' › ')[0].toLowerCase();
      for (const l of loads) if ((rel(dir, l.file_path) ?? '').toLowerCase() === src) at.push(loadAt(l));
      uses.forEach((u, i) => {
        if (u.name === 'Read' && (relOf(u) ?? '').toLowerCase() === src) at.push(i);
        if (u.name === 'Skill' && rule.skill && u.input?.skill === rule.skill) at.push(i);
      });
      if (rule.mark) {
        const m = new RegExp(rule.mark, 'i');
        for (const [i, t] of seen) if (m.test(t)) at.push(i);
      }
      return at.length ? Math.min(...at) : Infinity;
    },
    instructionBytes: loads.reduce((a, l) => a + (fs.existsSync(l.file_path ?? '') ? fs.statSync(l.file_path).size : 0), 0),
    skills: uses.filter((u) => u.name === 'Skill').map((u) => u.input?.skill),
    result: ev.findLast((e) => e.type === 'result'),
    init: ev.find((e) => e.type === 'system' && e.subtype === 'init'),
  };
}

async function runOnce(i, model = cfg.model) {
  const base = path.join(OUT, task.id, `run${i}`);
  fs.rmSync(base, { recursive: true, force: true });
  fs.mkdirSync(base, { recursive: true });
  // stage 3 arms run side by side, so each has its own worktree
  const dir = path.join(path.dirname(task.repo), `wt-${task.id}${SESSION[arm] === undefined && !SHAPES[arm] ? '' : `-${arm}`}`);
  const log = path.join(base, 'instructions.jsonl');
  // V2-D19 arm m: the user's own auto memory, a fresh copy per run, writable (as D17's M1); mc: the same in the
  // three-turn session (the Opus re-baseline, 05-eval-plan.md)
  const mem = ['m', 'mc', 'sbmc'].includes(arm) || (SHAPES[arm] && task.m1Arm === 'mc') ? path.join(base, 'memory') : null;
  if (mem) fs.cpSync(task.memory, mem, { recursive: true });
  makeRun(dir, log, armHooks(base), mem);
  const shape = SHAPES[arm];
  const compact = shape ? shape.compactions > 0 : SESSION[arm];
  const ev = compact === undefined ? claude(dir, task.prompt, model, path.join(base, 'stream.jsonl'), {}, undefined, mem)
    : await claudeTurns(dir, shape ? shape.turns(task) : turnsOf(task.prompt, compact), model, path.join(base, 'stream.jsonl'), mem);
  const f = facts(ev, dir, log, base);
  const { files, fresh } = changedFiles(dir);
  fs.writeFileSync(path.join(base, 'files.json'), JSON.stringify(files, null, 1));
  const r = f.result;
  const { reply, accountHeading } = replyOf(ev);
  const rec = { task: task.id, arm, run: i, date: new Date().toISOString().slice(0, 10), invalid: [], rules: {} };
  if (!r || r.subtype !== 'success' || r.is_error) rec.invalid.push('no success result');
  if (f.init?.model && !f.init.model.startsWith(model)) rec.invalid.push(`ran on ${f.init.model}`);
  const byEv = (e) => f.deliveries.filter((d) => d.ev === e);
  if (arm === 'i' && !byEv('UserPromptSubmit').some((d) => d.inventory)) rec.invalid.push('inventory not delivered at prompt');
  if (arm.startsWith('sb')) { // the plugin's own output, once per epoch: startup, and compact in the three-turn arms
    const out = (name, text) => ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === name && String(e.output ?? '').includes(text)).length;
    rec.plugin = { starts: out('SessionStart', 'This project keeps a map'), forced: out('UserPromptSubmit', 'Before you start: for each directory'),
      labelled: out('PostToolUse', '[project map]') };
    const want = shape ? 1 + shape.compactions : compact ? 2 : 1;
    if (!f.init?.plugins?.some((p) => p.name === 'second-brain')) rec.invalid.push('plugin not loaded');
    if (rec.plugin.starts !== want) rec.invalid.push(`plugin session start ${rec.plugin.starts} times`);
    if (rec.plugin.forced !== want) rec.invalid.push(`forced decision ${rec.plugin.forced} times`);
  }
  if (mem) {
    const inMem = (p) => slash(p ?? '').toLowerCase().startsWith(`${slash(mem).toLowerCase()}/`);
    const res = new Map(blocks(ev, 'user', 'tool_result').map((c) => [c.tool_use_id, c]));
    const writes = f.uses.filter((u) => ['Write', 'Edit', 'MultiEdit'].includes(u.name) && inMem(u.input?.file_path));
    const refused = writes.filter((u) => res.get(u.id)?.is_error && /permission|denied|granted|not allowed|blocked/i.test(JSON.stringify(res.get(u.id).content))).length;
    // InstructionsLoaded does not report auto memory (the smoke); the init event names the folder the session reads
    rec.memory = { indexBytes: fs.statSync(path.join(task.memory, 'MEMORY.md')).size, pathIsRunCopy: inMem(`${f.init?.memory_paths?.auto ?? ''}/`),
      reads: f.uses.filter((u) => u.name === 'Read' && inMem(u.input?.file_path)).length, writes: writes.length, refused };
    if (refused) rec.invalid.push(`${refused} memory write(s) refused`);
    if (!rec.memory.pathIsRunCopy) rec.invalid.push('auto memory not the run copy');
  }
  if (compact !== undefined) rec.session = sessionFacts(ev, f, model, compact, rec.invalid, chunksOf(base));
  if (arm.startsWith('v')) ({ positions: rec.positions, delivered: rec.delivered } = JSON.parse(fs.readFileSync(path.join(base, 'cards.json'), 'utf8')));
  if (!['a', 'i', 'm', ...NO_CARDS].includes(arm) && !task.rules.every((x) => byEv('UserPromptSubmit').some((d) => d.cards?.includes(x.id)))) rec.invalid.push('cards not delivered at prompt');
  if (arm === 'd' && !byEv('Stop').length) rec.invalid.push('no Stop hook call');
  rec.delivery = { denies: byEv('PreToolUse').filter((d) => d.cards).length, checkFeedback: byEv('PostToolUse').filter((d) => d.cards).length,
    stopFailing: byEv('Stop')[0]?.cards ?? null, accountHeading, hookMs: f.deliveries.map((d) => d.ms),
    subagents: f.uses.filter((u) => ['Agent', 'Task'].includes(u.name)).length,
    compacted: ev.some((e) => e.type === 'system' && /compact/.test(e.subtype ?? '')) };
  for (const rule of task.rules) {
    const at = f.contextAt(rule);
    const final = check(rule.check, files, reply, fresh);
    rec.rules[rule.id] = {
      final,
      // null when the first write holds no file this rule looks at (e.g. a test written after the component)
      atFirstWrite: f.firstWrite && rule.check.where !== 'reply'
        && Object.keys(f.firstWrite).some((p) => new RegExp(rule.check.path ?? '.').test(p)) ? check(rule.check, f.firstWrite, '') : null,
      // arm b/d: the first attempt at a file the pre-write delivery then denied (rules from prompt arrival only)
      atDeniedWrite: Object.keys(f.deniedWrite).some((p) => rule.check.where !== 'reply' && new RegExp(rule.check.path ?? '.').test(p))
        ? check(rule.check, f.deniedWrite, '') : null,
      inContextBeforeFirstWrite: at < f.upTo,
      inContext: at !== Infinity,
      chain: final ? 'followed' : at === Infinity ? 'not in context' : 'in context, not applied',
    };
  }
  rec.orientation = { toolCallsBeforeFirstWrite: f.anchor < 0 ? null : f.anchor, filesReadBeforeFirstWrite:
    new Set(f.uses.slice(0, f.upTo).filter((u) => u.name === 'Read').map((u) => slash(u.input?.file_path).toLowerCase())).size };
  rec.instructionsLoaded = f.loads.map((l) => ({ reason: l.load_reason, file: rel(dir, l.file_path) }));
  rec.instructionBytes = f.instructionBytes;
  rec.skills = f.skills;
  rec.changed = Object.keys(files);
  rec.usage = { costUsd: r?.total_cost_usd ?? null, inputTokens: r?.usage?.input_tokens ?? null,
    cacheReadTokens: r?.usage?.cache_read_input_tokens ?? null, cacheWriteTokens: r?.usage?.cache_creation_input_tokens ?? null,
    outputTokens: r?.usage?.output_tokens ?? null, turns: r?.num_turns ?? null, durationMs: r?.duration_ms ?? null };
  rec.valid = rec.invalid.length === 0;
  git(task.repo, 'worktree', 'remove', '--force', dir);
  return { rec, f, files, reply };
}

// Stage 3: a session's validity (pushed onto invalid) and measures. Kept rules are read from the compaction summary
// in the session's transcript (local only), by rule id, source path or mark: a lower bound.
// prompt deliveries a session must log: one per chunk in the volume arms (V2-D22), one otherwise
const chunksOf = (base) => { const p = path.join(base, 'cards.json'); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')).chunks?.length ?? 1 : 1; };
function sessionFacts(ev, f, model, compact, invalid, expected = 1) {
  const results = ev.filter((e) => e.type === 'result');
  const first = ev.findIndex((e) => e.type === 'result');
  // the plugin's arms capture into .project-map/ as its instruction says; that is not a change made while investigating
  const isWrite = (c) => c.type === 'tool_use' && ['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(c.name)
    && !(arm.startsWith('sb') && /[\\/]\.project-map[\\/]/.test(String(c.input?.file_path ?? '')));
  const boundary = ev.find((e) => e.type === 'system' && e.subtype === 'compact_boundary');
  const prompts = f.deliveries.filter((d) => d.ev === 'UserPromptSubmit' && d.cards).length;
  // the session's own model: subagents (parent_tool_use_id set) run on theirs, which the pilot showed for Opus
  const main = ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id && e.message?.model && e.message.model !== '<synthetic>');
  const models = [...new Set(main.map((e) => e.message.model))];
  // at least one result per turn sent: a background task Claude started wakes the session again, with its own result
  const shape = SHAPES[arm];
  const nth = (k) => { let c = 0; return ev.findIndex((e) => e.type === 'result' && ++c === k); };
  const quiet = shape ? (shape.quiet ? nth(shape.quiet) : 0) : first;
  const compactions = ev.filter((e) => e.type === 'system' && e.subtype === 'compact_boundary').length;
  if (results.length < (shape ? shape.turns(task).length : compact ? 3 : 2) || results.some((r) => r.subtype !== 'success' || r.is_error)) invalid.push(`turn results: ${results.map((r) => r.subtype)}`);
  // the window: the turns that say not to edit (in the task switch, the build's investigation turn only)
  const from = shape?.quietFrom ? nth(shape.quietFrom) + 1 : 0;
  if (ev.slice(from, quiet).some((e) => e.type === 'assistant' && (e.message?.content ?? []).some(isWrite))) invalid.push('wrote in the investigation turn');
  if (shape ? compactions !== shape.compactions : !!boundary !== compact) invalid.push(shape ? `${compactions} compactions` : compact ? 'no compaction' : 'compacted');
  if (!NO_CARDS.includes(arm) && prompts !== expected) invalid.push(`${prompts} prompt deliveries`);
  if (['p', 'pf', 'pfc', 'pfr'].includes(arm) && !f.deliveries.some((d) => d.ev === 'SessionStart' && d.inventory)) invalid.push('index not delivered at session start');
  if (['pfc', 'pfr', 'pfrs', 'pfro'].includes(arm) && !f.deliveries.some((d) => d.ev === 'SessionStart' && d.inventory && d.source === 'compact')) invalid.push('index not delivered after the compaction');
  if (arm === 'pfrs' && f.deliveries.filter((d) => d.review).length !== 1) invalid.push(`review blocks: ${f.deliveries.filter((d) => d.review).length}`);
  const forced = f.deliveries.filter((d) => d.ev === 'UserPromptSubmit' && d.text).length;
  if (['pf', 'pfc', 'pfr', 'pfrs', 'pfro'].includes(arm) && forced !== (['pfr', 'pfrs', 'pfro'].includes(arm) ? 2 : 1)) invalid.push(`forced text delivered ${forced} times`);
  if (models.some((m) => !m.startsWith(model))) invalid.push(`ran on ${models}`);
  // the web smoke: WebSearch is listed in the main session; WebFetch is reached through a fetch subagent on this CLI
  if (cfg.web && !f.init?.tools?.includes('WebSearch')) invalid.push('web search not listed');
  const ctx = (u) => (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
  const seen = new Map();
  for (const e of ev) if (e.type === 'assistant' && e.message?.usage && !seen.has(e.message.id)) {
    const u = e.message.usage;
    seen.set(e.message.id, u.iterations?.length ? Math.max(...u.iterations.map(ctx)) : ctx(u)); // usage sums a message's calls
  }
  const tp = f.loads.find((l) => l.transcript_path)?.transcript_path;
  const summary = tp && fs.existsSync(tp) ? parse(fs.readFileSync(tp, 'utf8')).filter((e) => e.isCompactSummary)
    .map((e) => JSON.stringify(e.message?.content ?? '')).join('\n') : null;
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return {
    turns: results.length, models, subagentModels: [...new Set(ev.filter((e) => e.type === 'assistant' && e.parent_tool_use_id).map((e) => e.message?.model))], compaction: boundary ? (boundary.compact_metadata ?? boundary.compactMetadata ?? {}) : null,
    webCalls: ev.filter((e) => e.type === 'assistant').flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use' && ['WebSearch', 'WebFetch'].includes(c.name)).length,
    requests: seen.size, contextPerRequest: [...seen.values()], resultCostsUsd: results.map((r) => r.total_cost_usd),
    // a result's usage is its own turn only; its modelUsage, like total_cost_usd, sums the session and its subagents
    tokensAll: Object.values(results.at(-1)?.modelUsage ?? {})
      .reduce((a, u) => a + u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens + u.outputTokens, 0),
    outputTokensAll: Object.values(results.at(-1)?.modelUsage ?? {}).reduce((a, u) => a + u.outputTokens, 0),
    deliveredBytes: f.deliveries.reduce((a, d) => a + (d.bytes ?? 0), 0), redelivered: f.deliveries.filter((d) => d.ev === 'SessionStart' && d.cards).length,
    summaryBytes: summary == null ? null : Buffer.byteLength(summary),
    keptInSummary: summary == null ? null : Object.fromEntries(task.rules.map((r) => [r.id, [`\\b${r.id}\\b`, r.source && esc(r.source), r.mark]
      .filter(Boolean).some((x) => new RegExp(x, 'i').test(summary))])),
  };
}

// the plugin's product files (tests left out), hashed as V2-D17-eval/eval.mjs hashes them, so both name the same plugin
function pluginHash() {
  const files = [];
  const go = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) if (e.name !== 'test') (e.isDirectory() ? go : (f) => files.push(f))(path.join(d, e.name)); };
  go(PLUGIN);
  const h = crypto.createHash('sha256');
  for (const f of files.map((f) => slash(path.relative(PLUGIN, f))).sort()) h.update(f).update(fs.readFileSync(path.join(PLUGIN, f), 'utf8').replace(/\r\n/g, '\n'));
  return h.digest('hex').slice(0, 12);
}

function epoch() {
  const h = crypto.createHash('sha256').update(JSON.stringify(task));
  const cli = run(CLAUDE, ['--version']).stdout.trim();
  return { cli, model: cfg.model, commit: task.commit, inputs: h.digest('hex').slice(0, 12), ...(arm.startsWith('sb') ? { plugin: pluginHash() } : {}) };
}

// ---------- modes ----------

// rebase and verdict: a task's valid runs in an arm, and the measures the thresholds are set on
const dirOf = (a) => (a === 'a' ? STAGE1 : path.join(path.dirname(cfgPath), cfg.outDir ?? 'd20-stage2', a));
const load = (a, id) => {
  const file = path.join(dirOf(a), `${id}.json`);
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')).runs.filter((r) => r.valid) : [];
};
const spread = (a) => { const v = a.filter((x) => x != null); return v.length ? Math.max(...v) - Math.min(...v) : null; };
// sessions: every turn and subagent (the last result's modelUsage); one-turn runs: that turn's own usage
const MEASURES = { toolCallsBeforeFirstWrite: (r) => r.orientation.toolCallsBeforeFirstWrite, filesReadBeforeFirstWrite: (r) => r.orientation.filesReadBeforeFirstWrite,
  tokensAll: (r) => r.session?.tokensAll ?? (r.usage.inputTokens + r.usage.cacheReadTokens + r.usage.cacheWriteTokens + r.usage.outputTokens),
  outputTokens: (r) => r.session?.outputTokensAll ?? r.usage.outputTokens, costUsd: (r) => r.usage.costUsd };

if (mode === 'checks') {
  // Each rule's check must pass its correct sample and fail its wrong one (rule.test: { pass, fail }, each a map of
  // path -> content, or a string for a check on the reply).
  let bad = 0;
  for (const t of cfg.tasks) for (const r of t.rules) {
    const ok = (x) => (typeof x === 'string' ? check(r.check, {}, x) : check(r.check, x ?? {}, ''));
    const res = r.test ? [ok(r.test.pass), ok(r.test.fail)] : null;
    const good = res && res[0] === true && res[1] === false;
    if (!good) bad++;
    console.log(`${t.id} ${r.id} ${r.kind}: ${good ? 'ok' : res ? `pass ${res[0]}, fail ${res[1]}` : 'no samples'}`);
  }
  console.log(bad ? `${bad} check(s) not ok` : 'all checks ok');
  process.exit(bad ? 1 : 0);
} else if (mode === 'smoke') {
  // Plumbing only: a cheap model writes one file. Shows the init listing, instruction loads and hook output.
  const saved = task.prompt;
  // arm b/d keep the task's prompt: their hooks only act on a write in a card's area
  if (arm === 'a') task.prompt = 'Create a file named smoke-note.md in the repository root containing the single word ok.';
  // arm m: the memory index arrived if Claude quotes its first line without opening it (V2-D19's pre-registered smoke)
  // arms v*: every chunk arrived if Claude names the last card of the last chunk without a tool (V2-D22 volume smoke)
  if (arm.startsWith('v')) task.prompt = 'Without using any tool, reply with only the id of the last project rule listed in your context, then stop.';
  // arm p: the index arrived if Claude quotes its first sentence without a tool (V2-D22 pull smoke)
  if (arm === 'p' || arm.startsWith('sb')) task.prompt = 'Without using any tool, quote the sentence in your context that begins "IMPORTANT: Prefer retrieval-led", then stop.';
  if (arm === 'm') task.prompt = 'Without using any tool, quote the first line of your auto memory index verbatim. Then create a file named smoke-note.md in the repository root containing the single word ok.';
  const { rec, f } = await runOnce(0, cfg.smokeModel ?? 'claude-haiku-5-5');
  task.prompt = saved;
  const ev = parse(fs.readFileSync(path.join(OUT, task.id, 'run0', 'stream.jsonl'), 'utf8'));
  const kinds = {};
  for (const e of ev) kinds[`${e.type}/${e.subtype ?? ''}`] = (kinds[`${e.type}/${e.subtype ?? ''}`] ?? 0) + 1;
  console.log(JSON.stringify({ valid: rec.valid, invalid: rec.invalid, skillsListed: f.init?.skills, plugins: f.init?.plugins,
    mcp: f.init?.mcp_servers, loads: rec.instructionsLoaded, logFields: Object.keys(f.loads[0] ?? {}),
    changed: rec.changed, usage: rec.usage, delivery: rec.delivery, rules: rec.rules, eventKinds: kinds, memory: rec.memory, session: rec.session, plugin: rec.plugin,
    memoryQuoted: arm === 'm' ? blocks(ev, 'assistant', 'text').map((c) => c.text).join('\n').includes(fs.readFileSync(path.join(task.memory, 'MEMORY.md'), 'utf8').split('\n')[0].trim()) : undefined,
    lastCard: arm.startsWith('v') ? { delivered: rec.delivered, chunks: chunksOf(path.join(OUT, task.id, 'run0')),
      named: blocks(ev, 'assistant', 'text').map((c) => c.text).join('\n').match(/E\d{3}/g) } : undefined }, null, 1));
} else if (mode === 'run') {
  const ep = epoch();
  const file = path.join(OUT, `${task.id}.json`);
  const saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { runs: [] };
  for (let i = Number(first); i < Number(first) + Number(runs); i++) {
    const { rec } = await runOnce(i);
    rec.epoch = ep;
    saved.runs = saved.runs.filter((x) => x.run !== i).concat(rec);
    fs.writeFileSync(file, `${JSON.stringify(saved, null, 1)}\n`);
    const r = Object.entries(rec.rules).map(([k, v]) => `${k}${v.final ? '+' : '-'}${v.final ? '' : v.chain === 'not in context' ? '(absent)' : '(ignored)'}`).join(' ');
    const d = rec.delivery && arm !== 'a' ? ` | denies ${rec.delivery.denies}, check feedback ${rec.delivery.checkFeedback}, stop failing ${rec.delivery.stopFailing}, account ${rec.delivery.accountHeading}` : '';
    console.log(`${task.id} ${arm} run ${i}: ${rec.valid ? 'valid' : `INVALID ${rec.invalid}`}; $${rec.usage.costUsd?.toFixed(2)} | ${r}${d}`);
  }
} else if (mode === 'summary') {
  // Public: task ids, rule ids, kinds and how the native setup delivers each; counts only, no rule text or paths.
  const out = { date: new Date().toISOString().slice(0, 10), tasks: {} };
  for (const t of cfg.tasks) {
    const file = path.join(OUT, `${t.id}.json`);
    if (!fs.existsSync(file)) continue;
    const rs = JSON.parse(fs.readFileSync(file, 'utf8')).runs.filter((r) => r.valid);
    const count = (id, k, v) => rs.filter((r) => r.rules[id]?.[k] === v).length;
    out.tasks[t.id] = {
      kind: t.kind, validRuns: rs.length, epoch: rs[0]?.epoch && { cli: rs[0].epoch.cli, model: rs[0].epoch.model },
      rules: Object.fromEntries(t.rules.map((r) => [r.id, { kind: r.kind, delivery: r.delivery, caughtLaterBy: r.caughtLater ?? null,
        followed: count(r.id, 'final', true), followedAtFirstWrite: count(r.id, 'atFirstWrite', true),
        inContextBeforeFirstWrite: count(r.id, 'inContextBeforeFirstWrite', true),
        notInContext: count(r.id, 'chain', 'not in context'), inContextNotApplied: count(r.id, 'chain', 'in context, not applied') }])),
      median: { costUsd: median(rs.map((r) => r.usage.costUsd)), inputTokensAll: median(rs.map((r) => r.usage.inputTokens + r.usage.cacheReadTokens + r.usage.cacheWriteTokens)),
        turns: median(rs.map((r) => r.usage.turns)), toolCallsBeforeFirstWrite: median(rs.map((r) => r.orientation.toolCallsBeforeFirstWrite)),
        instructionBytes: median(rs.map((r) => r.instructionBytes)) },
      totalCostUsd: rs.reduce((a, r) => a + (r.usage.costUsd ?? 0), 0),
    };
  }
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'summary.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'arrival') {
  // A channel arrived in a run when its nonce is quoted in any reply or written into the file (D12's rule): arrival,
  // not compliance (a first trial showed Claude decline an unrequested file edit it had been asked for).
  const A = path.join(path.dirname(cfgPath), 'd20-stage2', 'arrival');
  const res = [];
  for (let i = 1; i <= Number(runs); i++) {
    const base = path.join(A, `run${i}`);
    fs.rmSync(base, { recursive: true, force: true });
    fs.mkdirSync(base, { recursive: true });
    const dir = path.join(path.dirname(task.repo), `wt-${task.id}`);
    const n = Object.fromEntries(['D20_N1', 'D20_N2', 'D20_N3'].map((k) => [k, `NONCE-${crypto.randomBytes(4).toString('hex')}`]));
    const h = { hooks: [nodeHook('nonce.mjs', path.join(base, 'state.json'))] };
    const w = { matcher: 'Write|Edit|MultiEdit', ...h };
    makeRun(dir, path.join(base, 'instructions.jsonl'), { PreToolUse: [w], PostToolUse: [w], Stop: [h] });
    const ev = claude(dir, 'Create a file named smoke-note.md in the repository root containing the single word ok.',
      cfg.smokeModel ?? 'claude-haiku-5-5', path.join(base, 'stream.jsonl'), n, 'Bash,WebFetch,WebSearch,Grep,Glob');
    const note = fs.existsSync(path.join(dir, 'smoke-note.md')) ? fs.readFileSync(path.join(dir, 'smoke-note.md'), 'utf8') : '';
    const said = blocks(ev, 'assistant', 'text').map((c) => c.text).join('\n');
    const end = ev.findLast((e) => e.type === 'result');
    // null: the channel's hook never fired in this run, so the run says nothing about it
    const fired = fs.existsSync(path.join(base, 'state.json')) ? JSON.parse(fs.readFileSync(path.join(base, 'state.json'), 'utf8')) : {};
    const got = (e, x) => (fired[e] ? note.includes(x) || said.includes(x) : null);
    const r = { run: i, valid: end?.subtype === 'success' && !end.is_error, preToolUseDeny: got('PreToolUse', n.D20_N1),
      postToolUseBlock: got('PostToolUse', n.D20_N2), stopBlock: got('Stop', n.D20_N3), costUsd: end?.total_cost_usd };
    res.push(r);
    console.log(JSON.stringify(r));
    git(task.repo, 'worktree', 'remove', '--force', dir);
  }
  fs.writeFileSync(path.join(A, 'arrival.json'), JSON.stringify({ cli: epoch().cli, runs: res }, null, 1));
} else if (mode === 'summary2') {
  // Public: per task and rule, the followed count in arm a (the stage 1 runs; reply rules re-scored with this config's
  // checks), b and d, the outcome against a, and per arm the medians and hook time. Counts only, no rule text or paths.
  const S2 = path.join(path.dirname(cfgPath), 'd20-stage2');
  const load = (d, id) => {
    const f = path.join(d, `${id}.json`);
    return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid) : null;
  };
  const p95 = (a) => { const s = a.filter((x) => x != null).sort((x, y) => x - y); return s.length ? s[Math.ceil(0.95 * s.length) - 1] : null; };
  const out = { date: new Date().toISOString().slice(0, 10), tasks: {}, arms: {} };
  const all = { a: [], b: [], d: [] };
  for (const t of cfg.tasks) {
    const arms = { a: load(STAGE1, t.id), b: load(path.join(S2, 'b'), t.id), d: load(path.join(S2, 'd'), t.id) };
    for (const r of arms.a ?? []) {
      const ev = parse(fs.readFileSync(path.join(STAGE1, t.id, `run${r.run}`, 'stream.jsonl'), 'utf8'));
      for (const rule of t.rules) if (rule.check.where === 'reply') r.rules[rule.id].final = check(rule.check, {}, replyOf(ev).reply);
    }
    const got = Object.entries(arms).filter(([, rs]) => rs?.length);
    for (const [k, rs] of got) all[k].push(...rs);
    const n = (rs, id, f) => rs.filter((r) => f(r.rules[id])).length;
    out.tasks[t.id] = {
      rules: Object.fromEntries(t.rules.map((rule) => {
        const row = { kind: rule.kind, cls: rule.card.cls, namesCounterPattern: rule.card.ncp };
        for (const [k, rs] of got) {
          const followed = n(rs, rule.id, (x) => x.final);
          row[k] = { followed, of: rs.length, atFirstWrite: n(rs, rule.id, (x) => x.atFirstWrite === true),
            ...(k === 'a' ? { notInContext: n(rs, rule.id, (x) => x.chain === 'not in context') }
              : { atDeniedWrite: n(rs, rule.id, (x) => x.atDeniedWrite === true), deniedWrites: n(rs, rule.id, (x) => x.atDeniedWrite != null) }) };
          if (k !== 'a' && row.a && rs.length >= 5) { // a pilot run alone gets no outcome
            const missedA = row.a.of - row.a.followed >= 2;
            row[k].outcome = missedA ? (rs.length - followed <= 1 ? 'fixed' : 'still missed')
              : (rs.length - followed >= 2 ? 'regressed' : 'held');
          }
        }
        return [rule.id, row];
      })),
      median: Object.fromEntries(got.map(([k, rs]) => [k, { costUsd: median(rs.map((r) => r.usage.costUsd)),
        inputTokensAll: median(rs.map((r) => r.usage.inputTokens + r.usage.cacheReadTokens + r.usage.cacheWriteTokens)),
        outputTokens: median(rs.map((r) => r.usage.outputTokens)), turns: median(rs.map((r) => r.usage.turns)) }])),
    };
  }
  for (const [k, rs] of Object.entries(all)) if (rs.length) out.arms[k] = { validRuns: rs.length, epochs: [...new Set(rs.map((r) => r.epoch?.cli))],
    totalCostUsd: rs.reduce((a, r) => a + (r.usage.costUsd ?? 0), 0), hookCalls: rs.flatMap((r) => r.delivery?.hookMs ?? []).length,
    hookMsP95: p95(rs.flatMap((r) => r.delivery?.hookMs ?? [])), subagentRuns: rs.filter((r) => r.delivery?.subagents).length,
    compactedRuns: rs.filter((r) => r.delivery?.compacted).length, accountHeadingMissing: rs.filter((r) => r.delivery?.accountHeading === false).length };
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'summary-stage2.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'scale') {
  // V2-D19 (A2): per task, M1 (arm m where the task has the user's memory, else native: stage 1's runs 1-5 plus D19's
  // 6-10, reply rules re-scored with this config) and the thresholds by D17's rule. Counts only, no rule text.
  const load = (d, id) => {
    const f = path.join(d, `${id}.json`);
    return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid).map((r) => ({ ...r, dir: path.join(d, id, `run${r.run}`) })) : [];
  };
  const spread = (a) => { const s = a.filter((x) => x != null); return s.length ? Math.max(...s) - Math.min(...s) : null; };
  const measures = { toolCallsBeforeFirstWrite: (r) => r.orientation.toolCallsBeforeFirstWrite, filesReadBeforeFirstWrite: (r) => r.orientation.filesReadBeforeFirstWrite,
    tokensAll: (r) => r.usage.inputTokens + r.usage.cacheReadTokens + r.usage.cacheWriteTokens + r.usage.outputTokens,
    outputTokens: (r) => r.usage.outputTokens, costUsd: (r) => r.usage.costUsd };
  const out = { date: new Date().toISOString().slice(0, 10), rule: 'D17: counts and tokens, v2 median below M1 median minus M1 spread; pass items, v2 in no fewer runs than M1', tasks: {} };
  for (const t of cfg.tasks) {
    const arms = { native: [...load(path.join(path.dirname(cfgPath), '..', 'd20-stage1'), t.id), ...load(STAGE1, t.id)], m: t.memory ? load(path.join(path.dirname(cfgPath), 'd20-stage2', 'm'), t.id) : [] };
    for (const r of [...arms.native, ...arms.m]) {
      const ev = parse(fs.readFileSync(path.join(r.dir, 'stream.jsonl'), 'utf8'));
      for (const rule of t.rules) if (rule.check.where === 'reply') r.rules[rule.id].final = check(rule.check, {}, replyOf(ev).reply);
    }
    const m1 = t.memory ? 'm' : 'native';
    const got = Object.entries(arms).filter(([, rs]) => rs.length);
    out.tasks[t.id] = {
      m1, runs: Object.fromEntries(got.map(([k, rs]) => [k, rs.length])), epochs: [...new Set(got.flatMap(([, rs]) => rs.map((r) => r.epoch?.cli)))],
      rules: Object.fromEntries(t.rules.map((rule) => [rule.id, { kind: rule.kind, ...Object.fromEntries(got.map(([k, rs]) => [k,
        { followed: rs.filter((r) => r.rules[rule.id].final).length, atFirstWrite: rs.filter((r) => r.rules[rule.id].atFirstWrite === true).length }])),
      threshold: arms[m1].filter((r) => r.rules[rule.id].final).length }])),
      measures: Object.fromEntries(Object.entries(measures).map(([k, f]) => {
        const row = Object.fromEntries(got.map(([a, rs]) => [a, { median: median(rs.map(f)), spread: spread(rs.map(f)) }]));
        const b = row[m1];
        return [k, { ...row, threshold: b.median == null ? null : b.median - b.spread }];
      })),
      recorded: Object.fromEntries(got.map(([k, rs]) => [k, { instructionBytes: median(rs.map((r) => r.instructionBytes)), memoryIndexBytes: rs[0].memory?.indexBytes ?? 0,
        subagentRuns: rs.filter((r) => r.delivery?.subagents).length, compactedRuns: rs.filter((r) => r.delivery?.compacted).length,
        memoryReads: rs.reduce((a, r) => a + (r.memory?.reads ?? 0), 0), memoryWrites: rs.reduce((a, r) => a + (r.memory?.writes ?? 0), 0),
        costUsd: rs.reduce((a, r) => a + (r.usage.costUsd ?? 0), 0) }])),
    };
  }
  const dir = path.join(HERE, '..', 'V2-D19-scale', 'results');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'a2.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'rebase') {
  // The Opus re-baseline (05-eval-plan.md): per task, its M1 arm (task.m1Arm) and the thresholds by D17's rule with
  // the gap-target forms (D17, D19): a rule M1 never follows needs 8 of 10; a cell whose spread is at least its median
  // claims no gain and gets a no-worse ceiling instead. Counts only.
  const measures = MEASURES;
  const out = { date: new Date().toISOString().slice(0, 10), model: cfg.model,
    rule: 'D17 against M1; at floor 0 a rule needs 8 of 10; where the spread is at least the median, no gain is claimed and v2 must stay at or below median plus spread', tasks: {} };
  for (const t of cfg.tasks) {
    const rs = load(t.m1Arm, t.id);
    if (!rs.length) continue;
    out.tasks[t.id] = {
      m1Arm: t.m1Arm, validRuns: rs.length, epochs: [...new Set(rs.map((r) => r.epoch?.cli))], // a task scored on its reply writes nothing by design, so stopping is not counted for it
      stopped: t.rules.some((r) => r.check.where !== 'reply') ? rs.filter((r) => !r.changed?.length).length : null,
      rules: Object.fromEntries(t.rules.map((rule) => {
        const n = rs.filter((r) => r.rules[rule.id].final).length;
        return [rule.id, { kind: rule.kind, m1: n, target: n === 0 ? 8 : n }];
      })),
      measures: Object.fromEntries(Object.entries(measures).map(([k, fn]) => {
        const v = rs.map(fn).filter((x) => x != null);
        const med = median(v); const sp = spread(v);
        if (med == null) return [k, null];
        return [k, med - sp > 0 ? { median: med, spread: sp, below: med - sp } : { median: med, spread: sp, noGain: true, ceiling: med + sp }];
      })),
      totalCostUsd: rs.reduce((a, r) => a + (r.usage.costUsd ?? 0), 0),
    };
  }
  const dir = path.join(HERE, '..', 'V2-D19-scale', 'results');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `rebase-${cfg.summaryName ?? 'opus'}.json`), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'verdict') {
  // 06, 2d: A2's v2 arm (sb + the task's M1 arm) against the Opus thresholds that `rebase` set, per task and cell, by
  // D17's rule with the same median; 05's expected-miss list marked; stopped sessions counted both ways. Counts only.
  const dir = path.join(HERE, '..', 'V2-D19-scale', 'results');
  const th = JSON.parse(fs.readFileSync(path.join(dir, `rebase-${cfg.summaryName ?? 'opus'}.json`), 'utf8'));
  const LIST = { 'P1-build': ['R2'], 'P2-build': ['R4', 'outputTokens'], 'P2-plan': ['outputTokens'], 'R0-knowledge': ['filesReadBeforeFirstWrite'] };
  const out = { date: new Date().toISOString().slice(0, 10), model: cfg.model, list: LIST, tasks: {} };
  for (const t of cfg.tasks) {
    const m1 = th.tasks[t.id];
    const v2Arm = `sb${t.m1Arm}`;
    const rs = load(v2Arm, t.id);
    if (!m1 || !rs.length) continue;
    const listed = LIST[t.id] ?? [];
    const rules = Object.fromEntries(t.rules.map((rule) => {
      const n = rs.filter((r) => r.rules[rule.id].final).length;
      return [rule.id, { v2: n, target: m1.rules[rule.id].target, pass: n >= m1.rules[rule.id].target, listed: listed.includes(rule.id) }];
    }));
    const measures = Object.fromEntries(Object.entries(MEASURES).map(([k, fn]) => {
      const c = m1.measures[k];
      const med = median(rs.map(fn).filter((x) => x != null));
      return [k, !c || med == null ? null : { v2: med, pass: c.noGain ? med <= c.ceiling : med < c.below, listed: listed.includes(k) }];
    }));
    out.tasks[t.id] = { arm: v2Arm, validRuns: rs.length, epochs: [...new Set(rs.map((r) => `${r.epoch?.cli} ${r.epoch?.plugin}`))],
      stopped: m1.stopped === null ? null : { v2: rs.filter((r) => !r.changed?.length).length, m1: m1.stopped },
      rules, measures,
      misses: [...Object.entries(rules), ...Object.entries(measures)].filter(([, c]) => c && !c.pass && !c.listed).map(([k]) => k),
      // 2e: a rule the standard arm held (8 of 10) is missed in a shape when it fails in 2 or more of the shape's runs
      shapes: Object.fromEntries(Object.keys(SHAPES).flatMap((s) => {
        const ss = load(s, t.id);
        const inScope = Object.entries(rules).filter(([, c]) => c.v2 >= 8).map(([id]) => id);
        return ss.length ? [[s, { validRuns: ss.length, stopped: ss.filter((r) => !r.changed?.length).length, inScope,
          missed: inScope.filter((id) => ss.filter((r) => !r.rules[id].final).length >= 2) }]] : [];
      })),
      totalCostUsd: rs.reduce((a, r) => a + (r.usage.costUsd ?? 0), 0) };
  }
  fs.writeFileSync(path.join(dir, `verdict-${cfg.summaryName ?? 'opus'}.json`), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'recheck') {
  // D22 rethink 4 (DECISIONS.md): the attempt's cells (this config: the changed plugin, its own outDir) against their
  // reference cells in cfg.ref (2e's shapes; 2d's standard arm). Counts only.
  const ref = (a, id) => { const f = path.join(path.dirname(cfgPath), cfg.ref, a, `${id}.json`); return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid) : []; };
  const LISTED = { 'P1-build': ['R2'], 'P2-build': ['R4'] }; // 05's expected misses: reported, not in the no-loss set
  const fails = (rs, id) => rs.filter((r) => !r.rules[id].final).length;
  const write = (c) => ['Edit', 'Write', 'MultiEdit'].includes(c.name) && !/[\\/]\.project-map[\\/]/.test(String(c.input?.file_path ?? ''));
  // per run: the epoch (compactions so far) of the first code write, and whether the rule's source was Read in it
  const streamOf = (a, id, n) => parse(fs.readFileSync(path.join(dirOf(a), id, `run${n}`, 'stream.jsonl'), 'utf8'));
  const epochRead = (ev, src) => {
    let epoch = 0; let at = null; const read = new Set();
    for (const e of ev) {
      if (e.type === 'system' && e.subtype === 'compact_boundary') epoch++;
      for (const c of e.type === 'assistant' && Array.isArray(e.message?.content) ? e.message.content : []) {
        if (c.type !== 'tool_use') continue;
        if (c.name === 'Read' && slash(c.input?.file_path).endsWith(src)) read.add(epoch);
        if (at === null && write(c)) at = epoch;
      }
    }
    return at !== null && read.has(at);
  };
  const ups = (ev, text) => ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === 'UserPromptSubmit' && (!text || String(e.output ?? '').includes(text))).length;
  const out = { date: new Date().toISOString().slice(0, 10), model: cfg.model, cells: {} };
  for (const t of cfg.tasks) {
    const std = ref(`sb${t.m1Arm}`, t.id);
    const inScope = t.rules.filter((r) => std.length && std.filter((x) => x.rules[r.id].final).length >= 8).map((r) => r.id);
    for (const a of [`sb${t.m1Arm}`, ...Object.keys(SHAPES)]) {
      const rs = load(a, t.id);
      if (!rs.length) continue;
      const base = a.startsWith('sb') ? (a === `sb${t.m1Arm}` ? std : ref(a, t.id)) : [];
      const held = a === `sb${t.m1Arm}` ? inScope : inScope.filter((id) => base.length && fails(base, id) <= 1);
      const evs = rs.map((r) => streamOf(a, t.id, r.run));
      const cell = { runs: rs.length, epochs: [...new Set(rs.map((r) => `${r.epoch?.cli} ${r.epoch?.plugin ?? '-'}`))],
        fails: Object.fromEntries(t.rules.map((r) => [r.id, fails(rs, r.id)])),
        refFails: base.length ? Object.fromEntries(t.rules.map((r) => [r.id, fails(base, r.id)])) : null,
        lost: held.filter((id) => !(LISTED[t.id] ?? []).includes(id) && fails(rs, id) >= 2),
        // the later-prompt text on every UserPromptSubmit after the epoch's forced decision; a run without it is invalid
        textMissing: a.startsWith('sb') ? rs.filter((r, k) => ups(evs[k], RECHECK) !== ups(evs[k]) - ups(evs[k], 'Before you start: for each directory')).map((r) => r.run) : [],
        costMedian: median(rs.map((r) => r.usage.costUsd)), refCostMedian: base.length ? median(base.map((r) => r.usage.costUsd)) : null };
      if (t.id === 'P2-build' && a === 'sbv') {
        const src = t.rules.find((r) => r.id === 'R5').source;
        // the main session's first text after the text arrived: did the named documents include R5's?
        const named = (ev) => { const k = ev.findIndex((e) => e.subtype === 'hook_response' && e.hook_event === 'UserPromptSubmit' && String(e.output ?? '').includes(RECHECK));
          const txt = ev.slice(k + 1).find((e) => e.type === 'assistant' && !e.parent_tool_use_id && e.message?.content?.some((c) => c.type === 'text'));
          return k >= 0 && !!txt && txt.message.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n').includes(path.posix.basename(src)); };
        cell.fix = { id: 'R5', fails: cell.fails.R5, readInWriteEpoch: evs.filter((ev) => epochRead(ev, src)).length, namedOnTextLine: evs.filter(named).length };
      }
      out.cells[`${t.id} ${a}`] = cell;
    }
  }
  const p2 = (a) => out.cells[`P2-build ${a}`];
  const fix = p2('sbv')?.fix;
  const ceiling = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'V2-D19-scale', 'results', 'rebase-opus.json'), 'utf8')).tasks['P2-build'].measures.costUsd.ceiling;
  out.verdict = {
    fix: fix ? fix.fails <= 1 && fix.readInWriteEpoch >= 4 : null,
    noLoss: Object.values(out.cells).every((c) => !c.lost.length),
    textMissing: Object.fromEntries(Object.entries(out.cells).filter(([, c]) => c.textMissing.length).map(([k, c]) => [k, c.textMissing])),
    // R6 (rethink 4): listed as an expected miss only if native misses it too in two compactions (2e: v2 2 of 5)
    r6Listed: p2('nc2') ? p2('nc2').fails.R6 >= 2 : null,
    p2StandardCost: p2('sbn') ? { median: p2('sbn').costMedian, ceiling, above: p2('sbn').costMedian > ceiling } : null,
  };
  out.verdict.pass = out.verdict.fix === true && out.verdict.noLoss && out.verdict.r6Listed === true && !Object.keys(out.verdict.textMissing).length;
  fs.writeFileSync(path.join(HERE, 'results', 'd22-recheck.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out.verdict, null, 1));
} else if (mode === 'revalidate') {
  // Stage 3: re-apply the session checks to a task and arm's saved logs after a correction to them (recorded in
  // DECISIONS.md); everything else in the record stays as run.
  const file = path.join(OUT, `${task.id}.json`);
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
  const dir = path.join(path.dirname(task.repo), `wt-${task.id}-${arm}`);
  const mine = /^(turn results|wrote in the investigation turn|no compaction|compacted|\d+ prompt deliveries|ran on)/;
  for (const rec of saved.runs) {
    const base = path.join(OUT, task.id, `run${rec.run}`);
    const ev = parse(fs.readFileSync(path.join(base, 'stream.jsonl'), 'utf8'));
    rec.invalid = rec.invalid.filter((x) => !mine.test(x));
    rec.session = sessionFacts(ev, facts(ev, dir, path.join(base, 'instructions.jsonl'), base), cfg.model, SESSION[arm], rec.invalid, chunksOf(base));
    rec.valid = rec.invalid.length === 0;
    console.log(`${task.id} ${arm} run ${rec.run}: ${rec.valid ? 'valid' : `INVALID ${rec.invalid}`}`);
  }
  fs.writeFileSync(file, `${JSON.stringify(saved, null, 1)}\n`);
} else if (mode === 'summary3') {
  // Stage 3, public: per task and rule, followed counts per session arm, held or missed by D20's rule, the rules lost
  // to the compaction (held in o0, missed in oc) and which stage 2 path restored them; per arm, the session measures.
  const S = path.join(path.dirname(cfgPath), cfg.outDir ?? 'd20-stage2');
  const load = (a, id) => {
    const f = path.join(S, a, `${id}.json`);
    return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid) : [];
  };
  const status = (rs, id) => (rs.length < 5 ? null : rs.filter((r) => !r.rules[id].final).length >= 2 ? 'missed' : 'held');
  const out = { date: new Date().toISOString().slice(0, 10), model: cfg.model, tasks: {} };
  for (const t of cfg.tasks) {
    const arms = Object.fromEntries(Object.keys(SESSION).map((a) => [a, load(a, t.id)]).filter(([, rs]) => rs.length));
    out.tasks[t.id] = {
      runs: Object.fromEntries(Object.entries(arms).map(([a, rs]) => [a, rs.length])),
      epochs: [...new Set(Object.values(arms).flat().map((r) => r.epoch?.cli))],
      rules: Object.fromEntries(t.rules.map((rule) => {
        const row = { kind: rule.kind, cls: rule.card.cls };
        for (const [a, rs] of Object.entries(arms)) {
          // stopped: the session wrote no file (it stopped to ask); the second reading leaves those out (DECISIONS.md)
          const wrote = rs.filter((r) => r.changed?.length);
          row[a] = { followed: rs.filter((r) => r.rules[rule.id].final).length, of: rs.length, status: status(rs, rule.id),
            stopped: rs.length - wrote.length, statusWithoutStopped: wrote.length && wrote.filter((r) => !r.rules[rule.id].final).length >= 2 ? 'missed' : wrote.length ? 'held' : null,
            keptInSummary: rs.filter((r) => r.session?.keptInSummary?.[rule.id]).length,
            // the rule's source read or loaded before the first write (V2-D22 pull: the mechanism)
            readBefore: rs.filter((r) => r.rules[rule.id].inContextBeforeFirstWrite).length };
        }
        row.lost = row.o0?.status === 'held' && row.oc?.status === 'missed';
        row.lostWithoutStopped = row.o0?.statusWithoutStopped === 'held' && row.oc?.statusWithoutStopped === 'missed';
        // V2-D22 volume: lost at a level = held in o0, missed there ([as registered, without stopped sessions])
        // V2-D22 pull (p, then pf): reached = held there where n0 misses it; holds = holds what o0 holds ([as registered, without stopped])
        for (const a of ['p', 'pf', 'ph']) if (row[a] && row.n0) {
          row[`reachedBy_${a}`] = [row.n0.status === 'missed' && row[a].status === 'held', row.n0.statusWithoutStopped === 'missed' && row[a].statusWithoutStopped === 'held'];
          row[`holds_${a}`] = [row.o0?.status !== 'held' || row[a].status === 'held', row.o0?.statusWithoutStopped !== 'held' || row[a].statusWithoutStopped === 'held'];
        }
        for (const v of ['v8', 'v32']) if (row[v]) row[`lostAt${v}`] = [row.o0?.status === 'held' && row[v].status === 'missed', row.o0?.statusWithoutStopped === 'held' && row[v].statusWithoutStopped === 'missed'];
        // V2-D22 forced route across a compaction: holds what oc (push, compacted) holds ([as registered, without stopped])
        for (const a of ['pfc', 'pfr']) if (row[a]) row[`holds_${a}`] = [row.oc?.status !== 'held' || row[a].status === 'held', row.oc?.statusWithoutStopped !== 'held' || row[a].statusWithoutStopped === 'held'];
        // V2-D20 net: holds what pfr holds ([as registered, without stopped])
        for (const a of ['pfrs', 'pfro']) if (row[a] && row.pfr) row[`holds_${a}`] = [row.pfr.status !== 'held' || row[a].status === 'held', row.pfr.statusWithoutStopped !== 'held' || row[a].statusWithoutStopped === 'held'];
        if (row.lost || row.lostWithoutStopped) row.restoredBy = ['or', 'od', 'ow'].filter((a) => row[a]?.status === 'held');
        return [rule.id, row];
      })),
      sessions: Object.fromEntries(Object.entries(arms).map(([a, rs]) => [a, {
        maxContextPerRequest: median(rs.map((r) => Math.max(...r.session.contextPerRequest))), requests: median(rs.map((r) => r.session.requests)),
        compactionPreTokens: median(rs.map((r) => r.session.compaction?.pre_tokens ?? null)), compactionPostTokens: median(rs.map((r) => r.session.compaction?.post_tokens ?? null)),
        deliveredBytes: median(rs.map((r) => r.session.deliveredBytes)), costUsd: median(rs.map((r) => r.usage.costUsd)),
        costSpread: Math.max(...rs.map((r) => r.usage.costUsd)) - Math.min(...rs.map((r) => r.usage.costUsd)),
        tokensAll: median(rs.map((r) => r.session.tokensAll)),
        stopped: rs.filter((r) => !r.changed?.length).length, webSessions: rs.filter((r) => r.session.webCalls).length, totalCostUsd: rs.reduce((x, r) => x + (r.usage.costUsd ?? 0), 0) }])),
    };
  }
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', `summary-${cfg.summaryName ?? 'stage3'}.json`), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else {
  console.error('usage: node native.mjs checks|smoke|run|summary|arrival|summary2|scale|summary3 <config> [task] [runs] [first] [arm]');
  process.exit(2);
}
