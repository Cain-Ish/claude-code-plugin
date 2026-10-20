// V2-D20 stage 1: Claude in a test-bed repo as it is run today (its own CLAUDE.md, rules, skills and hooks; no
// memory, no plugin). Tasks and rules come from a private config, so this folder holds no private text; per-run
// detail is written next to the config, and only counts come back here (results/summary.json).
//   node native.mjs checks  <config>                   every rule's check against its correct and wrong sample
//   node native.mjs smoke   <config> <task>            one cheap session: checks the plumbing, not the model
//   node native.mjs run     <config> <task> [runs] [first]
//   node native.mjs summary <config>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [mode, cfgArg, taskId, runs = '1', first = '1'] = process.argv.slice(2);
const cfgPath = path.resolve(cfgArg);
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const OUT = path.join(path.dirname(cfgPath), 'd20-stage1');
const task = cfg.tasks.find((t) => t.id === taskId) ?? (mode === 'checks' || mode === 'summary' ? null : process.exit(2));

const env = () => {
  const e = { ...process.env, MSYS_NO_PATHCONV: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k];
  return e;
};
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', env: env(), maxBuffer: 256 << 20, ...opts });
const git = (cwd, ...a) => run('git', ['-c', 'core.longpaths=true', ...a], { cwd });
const slash = (p) => String(p ?? '').replace(/\\/g, '/');
const rel = (dir, p) => {
  const q = slash(p);
  const i = q.toLowerCase().indexOf(`/${path.basename(dir).toLowerCase()}/`);
  return i >= 0 ? q.slice(i + path.basename(dir).length + 2) : q && !path.isAbsolute(q) ? q : null;
};
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const blocks = (ev, role, type) => ev.flatMap((e) => (e.type === role ? (e.message?.content ?? []).filter((c) => c.type === type) : []));
const median = (a) => { const s = a.filter((x) => x != null).sort((x, y) => x - y); return s.length ? s[(s.length - 1) >> 1] : null; };

// ---------- one session in a fresh worktree ----------

function makeRun(dir, log) {
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
  const hook = { hooks: [{ type: 'command', command: `node "${slash(path.join(HERE, 'log.mjs'))}" "${slash(log)}"` }] };
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'),
    `${JSON.stringify({ autoMemoryEnabled: false, hooks: { InstructionsLoaded: [hook] } }, null, 2)}\n`);
}

function claude(cwd, prompt, model, raw) {
  // Skills stay on (they are how these repos hold knowledge); Bash and the web are off: no installs, static scoring.
  const r = run('claude', ['-p', '--model', model, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'Bash,WebFetch,WebSearch', '--permission-mode', 'acceptEdits',
    '--output-format', 'stream-json', '--verbose', '--include-hook-events'], { cwd, input: prompt, timeout: 1_800_000 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
}

function changedFiles(dir) {
  const out = {};
  for (const l of git(dir, 'status', '--porcelain', '-uall').stdout.split('\n')) {
    const p = slash(l.slice(3).trim().replace(/^"|"$/g, ''));
    if (!p || p === '.claude/settings.local.json' || !fs.existsSync(path.join(dir, p))) continue;
    out[p] = fs.readFileSync(path.join(dir, p), 'utf8');
  }
  return out;
}

// ---------- scoring ----------

function check(c, files, reply) {
  const re = (s) => new RegExp(s, c.flags ?? '');
  const sel = c.where === 'reply' ? [reply] : Object.entries(files).filter(([p]) => re(c.path ?? '.').test(p)).map(([, t]) => t);
  if (!sel.length) return false;
  if (c.must && !sel.some((t) => re(c.must).test(t))) return false;
  if (c.mustNot && sel.some((t) => re(c.mustNot).test(t))) return false;
  return true;
}

function facts(ev, dir, logFile) {
  const uses = blocks(ev, 'assistant', 'tool_use');
  const relOf = (u) => rel(dir, u.input?.file_path ?? u.input?.path);
  const isWrite = (u) => ['Write', 'Edit', 'MultiEdit'].includes(u.name) && relOf(u);
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
  for (const u of uses.slice(0, anchor + 1)) if (u.name === 'Write' && relOf(u)) firstWrite[relOf(u)] = u.input.content ?? '';
  return {
    uses, anchor, upTo, loads, firstWrite: anchor < 0 ? null : firstWrite,
    // index of the tool call by which the rule was in context; -1 = at start, Infinity = never
    contextAt(rule) {
      const at = [];
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
  makeRun(dir, log);
  const f = facts(claude(dir, task.prompt, model, path.join(base, 'stream.jsonl')), dir, log);
  const files = changedFiles(dir);
  fs.writeFileSync(path.join(base, 'files.json'), JSON.stringify(files, null, 1));
  const r = f.result;
  const reply = r?.result ?? '';
  const rec = { task: task.id, run: i, date: new Date().toISOString().slice(0, 10), invalid: [], rules: {} };
  if (!r || r.subtype !== 'success' || r.is_error) rec.invalid.push('no success result');
  if (f.init?.model && !f.init.model.startsWith(model)) rec.invalid.push(`ran on ${f.init.model}`);
  for (const rule of task.rules) {
    const at = f.contextAt(rule);
    const final = check(rule.check, files, reply);
    rec.rules[rule.id] = {
      final,
      atFirstWrite: f.firstWrite && rule.check.where !== 'reply' ? check(rule.check, f.firstWrite, '') : null,
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
  task.prompt = 'Create a file named smoke-note.md in the repository root containing the single word ok.';
  const { rec, f } = runOnce(0, cfg.smokeModel ?? 'claude-haiku-5-5');
  task.prompt = saved;
  const ev = parse(fs.readFileSync(path.join(OUT, task.id, 'run0', 'stream.jsonl'), 'utf8'));
  const kinds = {};
  for (const e of ev) kinds[`${e.type}/${e.subtype ?? ''}`] = (kinds[`${e.type}/${e.subtype ?? ''}`] ?? 0) + 1;
  console.log(JSON.stringify({ valid: rec.valid, invalid: rec.invalid, skillsListed: f.init?.skills, plugins: f.init?.plugins,
    mcp: f.init?.mcp_servers, loads: rec.instructionsLoaded, logFields: Object.keys(f.loads[0] ?? {}),
    changed: rec.changed, usage: rec.usage, eventKinds: kinds }, null, 1));
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
    console.log(`${task.id} run ${i}: ${rec.valid ? 'valid' : `INVALID ${rec.invalid}`}; $${rec.usage.costUsd?.toFixed(2)} | ${r}`);
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
      rules: Object.fromEntries(t.rules.map((r) => [r.id, { kind: r.kind, delivery: r.delivery,
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
} else {
  console.error('usage: node native.mjs smoke|run|summary <config> [task] [runs] [first]');
  process.exit(2);
}
