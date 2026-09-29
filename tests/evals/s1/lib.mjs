// S1 harness — shared library. Node >=18 built-ins only, no npm deps.
//
// Every function here is pure or takes its I/O paths as explicit arguments —
// nothing in this file reads process.env for a *path* (see the HOME/CWD bug
// class in project_home_cwd_relative_bug_class.md) and nothing here spawns a
// shell (argv arrays only, so MSYS/Git-Bash path conversion cannot rewrite an
// argument — see project_msys_spawn_tax_and_stale_oracles.md).
//
// Sections: env scrub · leak guards · path/touch matching · scoring ·
// decision rules · seeded PRNG/shuffle · run-plan builder · claude argv/
// settings.json builders · a tiny concurrency scheduler · fs helpers.

import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, statSync, existsSync, mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { join, sep, resolve } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const NL = '\n';

// ---------------------------------------------------------------------------
// fs helpers
// ---------------------------------------------------------------------------

export function readJSON(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

export function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function appendJSONLine(path, obj) {
  appendFileSync(path, JSON.stringify(obj) + NL, 'utf8');
}

export function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

// Real HOME-derived paths for the live brain/knowledge base. These are for
// LEAK-CHECKING (read-only) and for the "never touch the live brain" guard —
// they must resolve to the real machine's HOME, never to a redirected env
// var, or a leak into the live brain would go undetected.
export function liveBrainDir() {
  return join(homedir(), '.second-brain');
}
export function liveKnowledgeDir() {
  return join(homedir(), 'knowledge');
}
export function liveClaudeDir() {
  return join(homedir(), '.claude');
}

// Throws if `p` resolves to, or under, ~/.second-brain, ~/knowledge or
// ~/.claude. Call this before any write/rm on a path the harness is about to
// touch (run dirs, sandbox copies) so a misconfigured EVAL_ROOT can never
// fall back onto the live brain. Deliberately does NOT guard the whole of
// HOME — EVAL_ROOT's own default (%LOCALAPPDATA%/sb-evals/s1/<id>) is itself
// under HOME on Windows, so that would reject the spec's own default.
export function assertNotLiveBrainPath(p) {
  const target = resolve(p) + sep;
  const guarded = [liveBrainDir(), liveKnowledgeDir(), liveClaudeDir()];
  for (const g of guarded) {
    const guardedResolved = resolve(g) + sep;
    if (target === guardedResolved || target.toLowerCase().startsWith(guardedResolved.toLowerCase())) {
      throw new Error(`refusing to touch a live-brain path: ${p} (guarded: ${g})`);
    }
  }
}

function walkFiles(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out; // dir may not exist yet — caller decides if that's an error
  }
  for (const e of entries) {
    const full = join(dir, e.name);
    if (e.isDirectory()) walkFiles(full, out);
    else if (e.isFile()) out.push(full);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Env scrub — mandatory on every run (SPEC.md "Every run")
// ---------------------------------------------------------------------------

const SCRUB_PREFIXES = ['CLAUDE', 'SB_', 'ANTHROPIC_'];
const SCRUB_EXACT = ['BRAIN_DIR', 'KNOWLEDGE_DIR', 'MSYS_NO_PATHCONV'];

// Returns a NEW env object: every CLAUDE*, SB_*, ANTHROPIC_*, BRAIN_DIR,
// KNOWLEDGE_DIR, MSYS_NO_PATHCONV key removed from `sourceEnv`, then the
// mandatory run-scoped keys set. Does not mutate sourceEnv.
export function scrubEnv(sourceEnv, runDir) {
  const env = {};
  for (const [k, v] of Object.entries(sourceEnv)) {
    if (SCRUB_EXACT.includes(k)) continue;
    if (SCRUB_PREFIXES.some((p) => k.startsWith(p))) continue;
    env[k] = v;
  }
  env.CLAUDE_CODE_DISABLE_AUTO_MEMORY = '1';
  env.ENABLE_CLAUDEAI_MCP_SERVERS = 'false';
  const brain = join(runDir, 'brain');
  const knowledge = join(runDir, 'knowledge');
  env.BRAIN_DIR = brain;
  env.SB_BRAIN_DIR = brain;
  env.KNOWLEDGE_DIR = knowledge;
  env.SB_KNOWLEDGE_DIR = knowledge;
  return env;
}

// Arm-specific overlay applied AFTER scrubEnv. A and B get the side-effect
// guards; B additionally gets the push-off flags. C and D get neither (no
// plugin is loaded for them, so the flags would be no-ops, but we keep the
// overlay arm-gated to match the pre-registered arm definitions exactly).
export function applyArmEnv(env, arm) {
  const out = { ...env };
  if (arm === 'A' || arm === 'B') {
    out.SB_DISABLE_AUTO_TIMER = '1';
    out.SB_DREAM_AUTOSTAGE = 'off';
    out.SB_EXTRACT = 'off';
    out.SB_PERSONA_THINK = 'off';
  }
  if (arm === 'B') {
    out.SB_JIT = 'off';
    out.SB_SEARCH_FIRST = 'off';
    out.SB_ROLE_CARDS = 'off';
    out.SB_PROTOCOL_CARD = 'off';
    out.SB_COMPACT_REINJECT = 'off';
  }
  return out;
}

export function buildRunEnv({ sourceEnv, runDir, arm }) {
  return applyArmEnv(scrubEnv(sourceEnv, runDir), arm);
}

// Asserts the scrub actually removed the dangerous keys — used by selftest.
// Returns an array of leaked key names (empty = clean). Anything matching
// the scrub prefixes/exact names that ISN'T one of the keys scrubEnv/
// applyArmEnv are explicitly allowed to (re)introduce counts as a leak.
export function assertEnvScrubbed(env) {
  const allowedReintroduced = new Set([
    'CLAUDE_CODE_DISABLE_AUTO_MEMORY', 'SB_BRAIN_DIR', 'SB_KNOWLEDGE_DIR',
    'SB_DISABLE_AUTO_TIMER', 'SB_DREAM_AUTOSTAGE', 'SB_EXTRACT', 'SB_PERSONA_THINK',
    'SB_JIT', 'SB_SEARCH_FIRST', 'SB_ROLE_CARDS', 'SB_PROTOCOL_CARD', 'SB_COMPACT_REINJECT',
  ]);
  const bad = Object.keys(env).filter((k) => {
    if (SCRUB_EXACT.includes(k) && k !== 'BRAIN_DIR' && k !== 'KNOWLEDGE_DIR') return true;
    if (k === 'BRAIN_DIR' || k === 'KNOWLEDGE_DIR') return false; // mandatory re-set, not a leak
    if (SCRUB_PREFIXES.some((p) => k.startsWith(p))) return !allowedReintroduced.has(k);
    return false;
  });
  return bad; // empty array => clean
}

// ---------------------------------------------------------------------------
// Leak guards — mandatory (SPEC.md "Leak guards")
// ---------------------------------------------------------------------------

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Builds the set of leak patterns from the pre-registered tasks.json: the
// canary string, a literal "tasks.json", the "s1-t0"/"s1-c0" id prefixes, and
// the first 40 chars of every task prompt (long enough to be a specific leak,
// short enough to survive minor rewording in a rendered block).
export function buildLeakPatterns(tasksDoc) {
  const patterns = [
    { name: 'canary', re: new RegExp(escapeRegex(tasksDoc.canary), 'i') },
    { name: 'tasks.json', re: /tasks\.json/i },
    { name: 's1-t0-prefix', re: /s1-t0/i },
    { name: 's1-c0-prefix', re: /s1-c0/i },
  ];
  for (const t of tasksDoc.tasks) {
    const prefix = t.prompt.slice(0, 40);
    if (prefix.trim().length < 10) continue; // too short to be specific
    patterns.push({ name: `prompt-prefix:${t.id}`, re: new RegExp(escapeRegex(prefix), 'i') });
  }
  return patterns;
}

export function scanTextForLeaks(text, patterns) {
  const hits = [];
  for (const p of patterns) {
    const m = text.match(p.re);
    if (m) hits.push({ pattern: p.name, match: m[0] });
  }
  return hits;
}

const MAX_SCAN_BYTES = 8 * 1024 * 1024; // skip huge/binary files, e.g. vector index blobs

export function scanDirForLeaks(dir, patterns) {
  const hits = [];
  for (const file of walkFiles(dir)) {
    let size = 0;
    try { size = statSync(file).size; } catch { continue; }
    if (size > MAX_SCAN_BYTES) continue;
    let text;
    try { text = readFileSync(file, 'utf8'); } catch { continue; } // binary/undecodable — skip, not a text leak
    for (const h of scanTextForLeaks(text, patterns)) hits.push({ file, ...h });
  }
  return hits;
}

// Abort-on-hit pre-run guard. Throws (never returns) if the snapshot/sandbox
// directory contains any leak pattern.
export function assertNoLeaks(dir, patterns) {
  const hits = scanDirForLeaks(dir, patterns);
  if (hits.length > 0) {
    const lines = hits.map((h) => `  ${h.file} :: ${h.pattern} :: ${JSON.stringify(h.match)}`).join(NL);
    throw new Error(`leak guard: ${hits.length} hit(s) in ${dir}${NL}${lines}`);
  }
  return true;
}

// Post-run check against the REAL, live brain (read-only). Uses homedir(),
// never an env var, so a redirected BRAIN_DIR/KNOWLEDGE_DIR can't hide a real
// leak. Throws if the run's session id appears anywhere it must not.
export function postRunLiveLeakCheck(sessionId) {
  const hits = [];
  const brainTargets = [
    join(liveBrainDir(), 'audit-log.jsonl'),
    join(liveBrainDir(), 'error-log.jsonl'),
  ];
  for (const f of brainTargets) {
    if (!existsSync(f)) continue;
    let text;
    try { text = readFileSync(f, 'utf8'); } catch { continue; }
    if (text.includes(sessionId)) hits.push(f);
  }
  for (const dirName of ['.injected', 'transcripts']) {
    const dir = join(liveBrainDir(), dirName);
    for (const file of walkFiles(dir)) {
      let text;
      try { text = readFileSync(file, 'utf8'); } catch { continue; }
      if (text.includes(sessionId)) hits.push(file);
    }
  }
  const rawDir = join(liveKnowledgeDir(), 'raw');
  for (const file of walkFiles(rawDir)) {
    let text;
    try { text = readFileSync(file, 'utf8'); } catch { continue; }
    if (text.includes(sessionId)) hits.push(file);
  }
  if (hits.length > 0) {
    throw new Error(`leak guard: session ${sessionId} found in live brain/knowledge: ${hits.join(', ')}`);
  }
  return true;
}

// For A/B runs, the SANDBOX copy (not the live brain) MUST contain the
// session id somewhere in its logs, or the plugin never actually ran/wrote —
// a silent-pass bug this guard is designed to catch. `sandboxBrainDir` is the
// run's own <run>/brain (never the live one).
export function assertSandboxContainsSessionId(sandboxBrainDir, sessionId) {
  const candidates = [
    join(sandboxBrainDir, 'audit-log.jsonl'),
    join(sandboxBrainDir, 'error-log.jsonl'),
    ...walkFiles(join(sandboxBrainDir, '.injected')),
    ...walkFiles(join(sandboxBrainDir, 'transcripts')),
  ];
  for (const f of candidates) {
    if (!existsSync(f)) continue;
    let text;
    try { text = readFileSync(f, 'utf8'); } catch { continue; }
    if (text.includes(sessionId)) return true;
  }
  throw new Error(`sandbox leak guard: expected session ${sessionId} to appear in sandbox brain logs under ${sandboxBrainDir}, found none (arm A/B should log there)`);
}

// ---------------------------------------------------------------------------
// Path normalization + touch matching (tasks.json scoring.touch)
// ---------------------------------------------------------------------------

export function normalizeTouchPath(p, runRoot) {
  if (typeof p !== 'string' || p.length === 0) return p;
  let norm = p.replace(/\\/g, '/');
  const rootNorm = runRoot ? runRoot.replace(/\\/g, '/').replace(/\/+$/, '') : '';
  if (rootNorm && norm.toLowerCase().startsWith(rootNorm.toLowerCase())) {
    norm = norm.slice(rootNorm.length);
    if (!norm.startsWith('/')) norm = '/' + norm;
  }
  return norm;
}

// Extracts candidate "touched path" strings from one tool_use content block,
// per tasks.json scoring.touch. Grep/Glob CONTRIBUTE input.path but never
// input.pattern (patterns never count as a touch).
export function extractTouchedPaths(block, runRoot) {
  const name = block?.name || '';
  const input = block?.input || {};
  const raw = [];
  if (['Read', 'Edit', 'Write', 'MultiEdit'].includes(name)) {
    if (input.file_path) raw.push(input.file_path);
  } else if (['Grep', 'Glob'].includes(name)) {
    if (input.path) raw.push(input.path);
  } else if (name === 'Bash') {
    if (typeof input.command === 'string') {
      for (const tok of input.command.split(/\s+/)) if (tok) raw.push(tok);
    }
  } else if (name.startsWith('mcp__')) {
    for (const key of ['path', 'file', 'file_path']) if (input[key]) raw.push(input[key]);
  }
  return raw.map((p) => normalizeTouchPath(p, runRoot));
}

export function pathTouchesTask(paths, correctFilePatterns) {
  const regs = correctFilePatterns.map((r) => new RegExp(r, 'i'));
  return paths.some((p) => regs.some((re) => re.test(p)));
}

// Walks tool_use blocks (main + subagent, already flattened into stream
// order by the caller) and returns the pre-registered metrics triple.
export function computeTouchMetrics(toolUseBlocks, correctFilePatterns, runRoot) {
  const total = toolUseBlocks.length;
  for (let i = 0; i < total; i++) {
    const paths = extractTouchedPaths(toolUseBlocks[i], runRoot);
    if (pathTouchesTask(paths, correctFilePatterns)) {
      return { calls_before_first_correct: i, reached_correct_file: true, total_tool_calls: total };
    }
  }
  return { calls_before_first_correct: total + 1, reached_correct_file: false, total_tool_calls: total };
}

// Flattens a stream-json event array into an ordered list of tool_use
// content blocks (main-agent and subagent messages both carry
// message.content[]; stream order across both is preserved as emitted).
export function extractToolUseBlocks(streamEvents) {
  const blocks = [];
  for (const ev of streamEvents) {
    if (ev.type !== 'assistant' && ev.type !== 'user') continue;
    const content = ev.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (block?.type === 'tool_use') blocks.push(block);
    }
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Scoring — tasks.json `scoring` block, ported 1:1 from gen-tasks.mjs
// ---------------------------------------------------------------------------

function rx(pattern) {
  return new RegExp(pattern, 'i');
}

// Extracts answer_text per scoring.answer_text: from the LAST line matching
// answer_line to the end of final_text; if none, answer_text = final_text
// and the caller must set the no_answer_line flag.
export function extractAnswerText(finalText, answerLinePattern) {
  const text = String(finalText).replace(/\r/g, '');
  const lines = text.split('\n');
  const re = rx(answerLinePattern);
  let idx = -1;
  lines.forEach((l, i) => { if (re.test(l)) idx = i; });
  if (idx >= 0) return { answerText: lines.slice(idx).join('\n'), noAnswerLine: false };
  return { answerText: text, noAnswerLine: true };
}

// Scores one run's final_text against its task definition. `isError`/a
// missing finalText forces correct=false (tasks.json scoring.final_text).
export function scoreRun(task, scoringDoc, finalText, isError) {
  if (isError || finalText === null || finalText === undefined) {
    return { correct: false, no_answer_line: true, flags: {} };
  }
  const text = String(finalText);
  const { answerText, noAnswerLine } = extractAnswerText(text, scoringDoc.answer_line);
  const requiredAllOk = task.required_all.every((r) => rx(r).test(text));
  const requiredAnyOk = task.required_any.every((group) => group.some((r) => rx(r).test(text)));
  const forbiddenOk = !task.forbidden_answer_line.some((r) => rx(r).test(answerText));
  const correct = requiredAllOk && requiredAnyOk && forbiddenOk;
  const flags = {};
  for (const [flagName, pattern] of Object.entries(task.flags || {})) {
    flags[flagName] = rx(pattern).test(text);
  }
  return { correct, no_answer_line: noAnswerLine, flags };
}

// ---------------------------------------------------------------------------
// Seeded PRNG + shuffle (deterministic, seed = 20260927 per SPEC.md)
// ---------------------------------------------------------------------------

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// In-place Fisher-Yates using a supplied PRNG (so a single PRNG stream can be
// shared across multiple shuffles, as buildRunPlan does across its 3 blocks).
export function seededShuffle(arr, rng) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// Builds the pre-registered run plan: `reps` blocks (one PRNG stream shared
// across all of them, seeded once, per SPEC.md "3 blocks ... shuffled with
// seed 20260927" — read as one continuous shuffled stream rather than 3
// independently-reseeded ones), each a shuffled permutation of the full
// task x arm cell set.
export function buildRunPlan(tasksDoc, arms, seed, reps = 3) {
  const cells = [];
  for (const t of tasksDoc.tasks) for (const arm of arms) cells.push({ task_id: t.id, arm });
  const rng = mulberry32(seed);
  const plan = [];
  for (let rep = 0; rep < reps; rep++) {
    const block = seededShuffle(cells, rng).map((c) => ({ ...c, rep }));
    plan.push(...block);
  }
  return plan;
}

// ---------------------------------------------------------------------------
// Decision rules (SPEC.md "Pre-registered decision rules")
// ---------------------------------------------------------------------------

function median(nums) {
  if (nums.length === 0) return undefined;
  const s = nums.slice().sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

// `scoredRuns`: array of { task_id, arm, rep, correct, calls_before_first_correct }.
// Cells with fewer than `reps` present entries are reported as missing_cells
// (still treated as failures for maj/pass purposes, per SPEC.md).
export function computeDecisionRules(tasksDoc, scoredRuns, { reps = 3 } = {}) {
  const taskIds = tasksDoc.tasks.map((t) => t.id);
  const byTaskArm = new Map();
  for (const r of scoredRuns) {
    const key = `${r.task_id}\u0000${r.arm}`;
    if (!byTaskArm.has(key)) byTaskArm.set(key, []);
    byTaskArm.get(key).push(r);
  }
  const missingCells = [];
  function cellRuns(taskId, arm) {
    const list = byTaskArm.get(`${taskId}\u0000${arm}`) || [];
    if (list.length < reps) missingCells.push({ task_id: taskId, arm, present: list.length, expected: reps });
    return list;
  }
  function correctCount(taskId, arm) {
    return cellRuns(taskId, arm).filter((r) => r.correct).length;
  }
  function pass(taskId, arm) {
    // Missing reps count as failures (not correct), so this uses the raw
    // correct count out of the pre-registered `reps`, never out of only the
    // present count.
    return correctCount(taskId, arm) >= Math.ceil((2 / 3) * reps);
  }
  function rate(taskId, arm) {
    return correctCount(taskId, arm) / reps;
  }
  function medianCalls(taskId, arm) {
    const present = (byTaskArm.get(`${taskId}\u0000${arm}`) || []).map((r) => r.calls_before_first_correct);
    return median(present);
  }

  // Δtasks(A,B)
  let deltaTasksAB = 0;
  for (const t of taskIds) {
    if (pass(t, 'A') && !pass(t, 'B')) deltaTasksAB += 1;
    if (pass(t, 'B') && !pass(t, 'A')) deltaTasksAB -= 1;
  }

  // R = median over tasks of (m_B - m_A)/max(m_B,1); tasks where either
  // median is undefined (whole cell missing) are excluded and reported.
  const rExcluded = [];
  const rTerms = [];
  for (const t of taskIds) {
    const mA = medianCalls(t, 'A');
    const mB = medianCalls(t, 'B');
    if (mA === undefined || mB === undefined) { rExcluded.push(t); continue; }
    rTerms.push((mB - mA) / Math.max(mB, 1));
  }
  const R = median(rTerms);

  const pushFalsified = R !== undefined && deltaTasksAB < 2 && R < 0.10;

  // Native dominates: mean pass(C) >= mean pass(A), over all pre-registered tasks.
  const meanPass = (arm) => taskIds.reduce((acc, t) => acc + (pass(t, arm) ? 1 : 0), 0) / taskIds.length;
  const nativeDominates = meanPass('C') >= meanPass('A');

  // Saturated: B and D both 3/3 (all reps present AND correct).
  const saturatedTasks = taskIds.filter((t) => correctCount(t, 'B') === reps && correctCount(t, 'D') === reps);
  const inconclusive = saturatedTasks.length >= 6;

  // Harm: A's pass RATE is at least 2/3 below D's, on any single task. This
  // is our reading of the terse spec line "A >=2/3 below D on any task" —
  // see tests/evals/README.md "Decision-rule interpretation notes".
  const harmTasks = taskIds.filter((t) => rate(t, 'D') - rate(t, 'A') >= 2 / 3);
  const harm = harmTasks.length > 0;

  return {
    delta_tasks_ab: deltaTasksAB,
    R,
    r_excluded_tasks: rExcluded,
    push_falsified: pushFalsified,
    native_dominates: nativeDominates,
    mean_pass: { A: meanPass('A'), B: meanPass('B'), C: meanPass('C'), D: meanPass('D') },
    saturated_tasks: saturatedTasks,
    inconclusive,
    harm,
    harm_tasks: harmTasks,
    missing_cells: missingCells,
  };
}

// Paired bootstrap over tasks (reported, not gating). Resamples the 12
// task-level Δ(A,B) indicators (+1/-1/0) with replacement, `iterations`
// times, and returns a percentile CI on the resampled Δtasks total.
export function pairedBootstrapDeltaTasks(tasksDoc, scoredRuns, { iterations = 10000, seed = 20260927, reps = 3 } = {}) {
  const taskIds = tasksDoc.tasks.map((t) => t.id);
  const byTaskArm = new Map();
  for (const r of scoredRuns) {
    const key = `${r.task_id}\u0000${r.arm}`;
    if (!byTaskArm.has(key)) byTaskArm.set(key, []);
    byTaskArm.get(key).push(r);
  }
  function correctCount(taskId, arm) {
    return (byTaskArm.get(`${taskId}\u0000${arm}`) || []).filter((r) => r.correct).length;
  }
  function pass(taskId, arm) { return correctCount(taskId, arm) >= Math.ceil((2 / 3) * reps); }
  const indicators = taskIds.map((t) => (pass(t, 'A') && !pass(t, 'B') ? 1 : (pass(t, 'B') && !pass(t, 'A') ? -1 : 0)));
  const rng = mulberry32(seed ^ 0x9E3779B9);
  const totals = [];
  for (let iter = 0; iter < iterations; iter++) {
    let sum = 0;
    for (let i = 0; i < indicators.length; i++) {
      sum += indicators[Math.floor(rng() * indicators.length)];
    }
    totals.push(sum);
  }
  totals.sort((a, b) => a - b);
  const pct = (p) => totals[Math.min(totals.length - 1, Math.max(0, Math.floor(p * totals.length)))];
  return { iterations, point_estimate: indicators.reduce((a, b) => a + b, 0), ci95: [pct(0.025), pct(0.975)] };
}

// Blinded manual audit sample: ~`fraction` of scored runs, deterministically
// selected. Returns a blinded list (task_id + answer text only) plus a
// separate key mapping audit_id -> {arm, rep, session_id} for reconciliation
// AFTER the audit — the auditor is only ever shown the blinded list.
export function buildAuditSample(scoredRuns, { fraction = 0.2, seed = 20260927 } = {}) {
  const rng = mulberry32(seed ^ 0x1234567);
  const shuffled = seededShuffle(scoredRuns, rng);
  const n = Math.round(shuffled.length * fraction);
  const picked = shuffled.slice(0, n);
  const blinded = picked.map((r, i) => ({ audit_id: `audit-${i}`, task_id: r.task_id, answer_text: r.answer_text ?? r.final_text ?? '' }));
  const key = picked.map((r, i) => ({ audit_id: `audit-${i}`, arm: r.arm, rep: r.rep, session_id: r.session_id }));
  return { blinded, key };
}

// ---------------------------------------------------------------------------
// claude CLI argv + settings.json builders (SPEC.md "Every run")
// ---------------------------------------------------------------------------

// Returns an argv ARRAY (never a shell string) for spawning `claude`.
export function buildClaudeArgv({ prompt, model, effort, settingsPath, sessionId, arm, pluginDir, appendSystemPromptFile }) {
  const argv = [
    '-p', prompt,
    '--model', model,
    '--effort', effort,
    '--setting-sources', 'project',
    '--settings', settingsPath,
    '--output-format', 'stream-json',
    '--verbose',
    '--include-hook-events',
    '--no-session-persistence',
    '--permission-prompts', 'none',
    '--session-id', sessionId,
    '--max-turns', '60',
    '--max-budget-usd', '3',
  ];
  if (arm === 'A' || arm === 'B') {
    argv.push('--plugin-dir', pluginDir);
  } else if (arm === 'C') {
    argv.push('--append-system-prompt-file', appendSystemPromptFile);
  }
  // arm D: no plugin, no block — no extra flags.
  return argv;
}

export function buildSettingsJson(allowlist) {
  return {
    permissions: {
      allow: [
        'Read', 'Grep', 'Glob', 'Agent', 'TodoWrite',
        'Bash(git log|show|grep|ls-files|diff|blame|status|rev-parse *)',
        'Bash(grep|rg|ls|cat|head|tail|wc|jq|od *)',
        'Bash(sed -n *)',
        ...(allowlist?.mcp_read_tools || []).map((name) => name),
      ],
      deny: [
        'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'WebFetch', 'WebSearch',
        'Read(~/.second-brain/**)', 'Read(~/knowledge/**)', 'Read(~/.claude/**)',
      ],
    },
  };
}

// ---------------------------------------------------------------------------
// Concurrency scheduler: 3 total, at most 2 of which are A/B (SPEC.md
// "Controls and sandbox" / "Concurrency").
// ---------------------------------------------------------------------------

export class RunScheduler {
  constructor({ maxTotal = 3, maxAB = 2 } = {}) {
    this.maxTotal = maxTotal;
    this.maxAB = maxAB;
    this.active = 0;
    this.activeAB = 0;
    this.waiters = [];
  }

  _tryDrain() {
    while (this.waiters.length > 0) {
      const next = this.waiters[0];
      const isAB = next.arm === 'A' || next.arm === 'B';
      if (this.active >= this.maxTotal) break;
      if (isAB && this.activeAB >= this.maxAB) {
        // An A/B waiter is blocked on the AB cap, but a non-AB waiter behind
        // it may still be schedulable — scan past it instead of head-of-line
        // blocking the whole queue.
        const altIdx = this.waiters.findIndex((w) => w.arm !== 'A' && w.arm !== 'B');
        if (altIdx === -1) break;
        const [alt] = this.waiters.splice(altIdx, 1);
        this.active += 1;
        alt.resolve();
        continue;
      }
      this.waiters.shift();
      this.active += 1;
      if (isAB) this.activeAB += 1;
      next.resolve();
    }
  }

  acquire(arm) {
    return new Promise((resolve) => {
      this.waiters.push({ arm, resolve });
      this._tryDrain();
    });
  }

  release(arm) {
    this.active -= 1;
    if (arm === 'A' || arm === 'B') this.activeAB -= 1;
    this._tryDrain();
  }
}

// ---------------------------------------------------------------------------
// git helpers — argv arrays only, never a shell string (see file header).
// ---------------------------------------------------------------------------

// Runs `git <argv>` with spawnSync (no shell). Throws with stderr attached
// on a nonzero exit — fail loud, never a silent 2>/dev/null-style swallow.
export function runGit(argv, { cwd } = {}) {
  const res = spawnSync('git', argv, { cwd, encoding: 'utf8' });
  if (res.error) throw res.error;
  if (res.status !== 0) {
    throw new Error(`git ${argv.join(' ')} exited ${res.status}: ${res.stderr || res.stdout}`);
  }
  return res.stdout;
}

// One-time template setup (SPEC.md "Controls and sandbox"): clone the task
// repo detached at the pinned commit, strip all refs/history beyond it, and
// assert the resulting rev-list matches the pinned commit's ancestor count.
// NOT called by prepare.mjs's --dry-run path and not called anywhere in this
// dispatch — it needs network access to `originUrl` and is exercised for
// real starting at build-order step 6 (smoke), once plugin_commit is pinned.
export function ensureRepoTemplate({ repoDir, sourcePath, originUrl, commit }) {
  assertNotLiveBrainPath(repoDir);
  if (existsSync(repoDir)) return repoDir; // idempotent — reuse an existing template
  ensureDir(resolve(repoDir, '..'));
  runGit(['clone', '--no-local', sourcePath, repoDir]);
  runGit(['checkout', '--detach', commit], { cwd: repoDir });
  const refs = runGit(['for-each-ref', '--format=%(refname)'], { cwd: repoDir })
    .split('\n').map((l) => l.trim()).filter(Boolean);
  for (const ref of refs) runGit(['update-ref', '-d', ref], { cwd: repoDir });
  runGit(['remote', 'set-url', 'origin', originUrl], { cwd: repoDir });
  runGit(['reflog', 'expire', '--expire=now', '--all'], { cwd: repoDir });
  runGit(['gc', '--prune=now'], { cwd: repoDir });
  const allCount = parseInt(runGit(['rev-list', '--all', '--count'], { cwd: repoDir }).trim(), 10);
  const pinnedCount = parseInt(runGit(['rev-list', '--count', commit], { cwd: repoDir }).trim(), 10);
  if (allCount !== pinnedCount) {
    throw new Error(`repo template ref count mismatch: rev-list --all=${allCount} vs rev-list --count ${commit}=${pinnedCount}`);
  }
  return repoDir;
}

// Per-run sandbox worktree, detached from the template.
export function createRunWorktree(repoDir, worktreeDir) {
  assertNotLiveBrainPath(worktreeDir);
  runGit(['worktree', 'add', '--detach', worktreeDir], { cwd: repoDir });
  return worktreeDir;
}

export function shouldRetry(attempt, record) {
  const isRateLimited = record?.api_error_status === 429 || record?.rate_limit_hit === true;
  return attempt < 1 && (record?.is_error === true || isRateLimited);
}

export const RETRY_DELAY_MS = 60000;
