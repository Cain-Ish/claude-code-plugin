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
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { check, changedFiles, slash } from './check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, cfgArg, taskId, runs = '1', first = '1', arm = 'a'] = process.argv.slice(2);
const cfgPath = path.resolve(cfgArg);
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const STAGE1 = path.join(path.dirname(cfgPath), 'd20-stage1');
const OUT = arm === 'a' ? STAGE1 : path.join(path.dirname(cfgPath), 'd20-stage2', arm);
const task = cfg.tasks.find((t) => t.id === taskId) ?? (['checks', 'summary', 'summary2'].includes(mode) ? null : process.exit(2));

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
const blocks = (ev, role, type) => ev.flatMap((e) => (e.type === role ? (e.message?.content ?? []).filter((c) => c.type === type) : []));
const median = (a) => { const s = a.filter((x) => x != null).sort((x, y) => x - y); return s.length ? s[(s.length - 1) >> 1] : null; };

// ---------- one session in a fresh worktree ----------

// hooks: extra hook groups by event, merged into the run's settings beside the InstructionsLoaded logger
function makeRun(dir, log, hooks = {}) {
  git(task.repo, 'worktree', 'remove', '--force', dir);
  fs.rmSync(dir, { recursive: true, force: true });
  const r = git(task.repo, 'worktree', 'add', '-q', '--detach', dir, task.commit);
  if (r.status !== 0) throw new Error(`worktree: ${r.stderr}`);
  for (const s of task.setup ?? []) { // a review task plants its change, uncommitted
    const f = path.join(dir, s.file);
    const t = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
    if (s.find && !t.includes(s.find)) throw new Error(`setup: text not found in ${s.file}`);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, s.find ? t.replace(s.find, s.replace) : s.content);
  }
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), `${JSON.stringify({ autoMemoryEnabled: false,
    hooks: { InstructionsLoaded: [{ hooks: [nodeHook('log.mjs', log)] }], ...hooks } }, null, 2)}\n`);
}
const nodeHook = (script, ...args) => ({ type: 'command', command: ['node', path.join(HERE, script), ...args].map((x) => (x === 'node' ? x : `"${slash(x)}"`)).join(' ') });

// Arm (b): prompt arrival and a one-time deny before the first write in an area; (d) adds checks after writes and Stop.
function armHooks(base) {
  if (arm === 'a') return {};
  const d = { hooks: [nodeHook('deliver.mjs', base)] };
  const writes = { matcher: 'Write|Edit|MultiEdit', ...d };
  fs.writeFileSync(path.join(base, 'cards.json'), JSON.stringify({ arm,
    cards: task.rules.map((r) => ({ id: r.id, ...r.card, check: r.check })) }, null, 1));
  return { UserPromptSubmit: [d], PreToolUse: [writes], ...(arm === 'd' ? { PostToolUse: [writes], Stop: [d] } : {}) };
}

function claude(cwd, prompt, model, raw, extraEnv = {}, deny = 'Bash,WebFetch,WebSearch') {
  // Skills stay on (they are how these repos hold knowledge); Bash and the web are off: no installs, static scoring.
  const r = spawnSync('claude', ['-p', '--model', model, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', deny, '--permission-mode', 'acceptEdits',
    '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
  { cwd, input: prompt, timeout: 1_800_000, encoding: 'utf8', env: env(extraEnv), maxBuffer: 256 << 20 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
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
      const src = (rule.source ?? '\0').toLowerCase();
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

function runOnce(i, model = cfg.model) {
  const base = path.join(OUT, task.id, `run${i}`);
  fs.rmSync(base, { recursive: true, force: true });
  fs.mkdirSync(base, { recursive: true });
  const dir = path.join(path.dirname(task.repo), `wt-${task.id}`);
  const log = path.join(base, 'instructions.jsonl');
  makeRun(dir, log, armHooks(base));
  const ev = claude(dir, task.prompt, model, path.join(base, 'stream.jsonl'));
  const f = facts(ev, dir, log, base);
  const { files, fresh } = changedFiles(dir);
  fs.writeFileSync(path.join(base, 'files.json'), JSON.stringify(files, null, 1));
  const r = f.result;
  const { reply, accountHeading } = replyOf(ev);
  const rec = { task: task.id, arm, run: i, date: new Date().toISOString().slice(0, 10), invalid: [], rules: {} };
  if (!r || r.subtype !== 'success' || r.is_error) rec.invalid.push('no success result');
  if (f.init?.model && !f.init.model.startsWith(model)) rec.invalid.push(`ran on ${f.init.model}`);
  const byEv = (e) => f.deliveries.filter((d) => d.ev === e);
  if (arm !== 'a' && !task.rules.every((x) => byEv('UserPromptSubmit').some((d) => d.cards?.includes(x.id)))) rec.invalid.push('cards not delivered at prompt');
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

function epoch() {
  const h = crypto.createHash('sha256').update(JSON.stringify(task));
  const cli = run('claude', ['--version']).stdout.trim();
  return { cli, model: cfg.model, commit: task.commit, inputs: h.digest('hex').slice(0, 12) };
}

// ---------- modes ----------

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
  const { rec, f } = runOnce(0, cfg.smokeModel ?? 'claude-haiku-5-5');
  task.prompt = saved;
  const ev = parse(fs.readFileSync(path.join(OUT, task.id, 'run0', 'stream.jsonl'), 'utf8'));
  const kinds = {};
  for (const e of ev) kinds[`${e.type}/${e.subtype ?? ''}`] = (kinds[`${e.type}/${e.subtype ?? ''}`] ?? 0) + 1;
  console.log(JSON.stringify({ valid: rec.valid, invalid: rec.invalid, skillsListed: f.init?.skills, plugins: f.init?.plugins,
    mcp: f.init?.mcp_servers, loads: rec.instructionsLoaded, logFields: Object.keys(f.loads[0] ?? {}),
    changed: rec.changed, usage: rec.usage, delivery: rec.delivery, rules: rec.rules, eventKinds: kinds }, null, 1));
} else if (mode === 'run') {
  const ep = epoch();
  const file = path.join(OUT, `${task.id}.json`);
  const saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { runs: [] };
  for (let i = Number(first); i < Number(first) + Number(runs); i++) {
    const { rec } = runOnce(i);
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
} else {
  console.error('usage: node native.mjs checks|smoke|run|summary|arrival|summary2 <config> [task] [runs] [first] [arm]');
  process.exit(2);
}
