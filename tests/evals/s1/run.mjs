#!/usr/bin/env node
// S1 harness — run orchestrator (build order step 5).
//
// Executes cells from EVAL_ROOT/run-plan.json (written by prepare.mjs)
// against a live `claude` CLI, per SPEC.md "Every run" / "Controls and
// sandbox" / "Metrics per run". Every run: scrubs env, writes a per-run
// settings.json + sandbox copy of the frozen snapshot, spawns `claude` with
// an argv ARRAY (never a shell string), captures the stream-json output,
// derives touch metrics, runs the leak guards, and appends one record to
// EVAL_ROOT/runs.jsonl.
//
// Usage:
//   node run.mjs --smoke  [--eval-root <dir>]
//   node run.mjs --full   [--eval-root <dir>]
//   node run.mjs --resume [--eval-root <dir>]
//
// HARD GUARD: every mode refuses to spawn a single `claude` process while
// config.json's pins.plugin_commit is still "TBD-after-S0-merge" — this is
// not just a dispatch instruction, it's enforced in code (see assertReady())
// so a future invocation of this file can't accidentally run the real
// experiment against an unpinned plugin commit.

import { existsSync, readFileSync, writeFileSync, cpSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import {
  readJSON, ensureDir, appendJSONLine, assertNotLiveBrainPath,
  buildRunEnv, buildSettingsJson, buildClaudeArgv, buildLeakPatterns, buildBrainLeakPatterns, assertNoLeaks,
  computeTouchMetrics, extractToolUseBlocks, postRunLiveLeakCheck, assertSandboxContainsSessionId,
  RunScheduler, shouldRetry, RETRY_DELAY_MS, createRunWorktree, ensureRepoTemplate,
} from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--smoke' || a === '--full' || a === '--resume') args.mode = a.slice(2);
    else if (a === '--eval-root') args.evalRoot = argv[++i];
    else if (a === '--repo-source') args.repoSource = argv[++i];
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  if (!args.mode) { console.error('one of --smoke, --full, --resume is required'); process.exit(2); }
  return args;
}

// Refuses to run against an unpinned plugin/model. Fail loud, no silent
// fallback to "run anyway" — see the file header.
function assertReady(config, mode) {
  if (config.pins.plugin_commit === 'TBD-after-S0-merge') {
    throw new Error('run.mjs refuses to start: config.json pins.plugin_commit is still "TBD-after-S0-merge". Merge S0 and update the pin before running --smoke/--full/--resume.');
  }
  if (mode !== 'smoke' && config.pins.model === 'TBD-after-smoke') {
    throw new Error(`run.mjs refuses to start --${mode}: config.json pins.model is still "TBD-after-smoke". Run --smoke first and pin the model it reports.`);
  }
}

function readExistingRuns(runsPath) {
  if (!existsSync(runsPath)) return [];
  return readFileSync(runsPath, 'utf8').split('\n').filter((l) => l.trim().length > 0).map((l) => JSON.parse(l));
}

function cellKey(c) { return `${c.task_id}\u0000${c.arm}\u0000${c.rep}`; }

// Copies the frozen snapshot into <run>/brain + <run>/knowledge (+ its wiki
// subfolder). Used for every arm (A-D) so C's offline block-render sandbox
// and the live run see the same starting brain; C/D simply never load a
// plugin that would read it.
function seedSandbox(runDir, frozenDir) {
  const brainDst = join(runDir, 'brain');
  const knowledgeDst = join(runDir, 'knowledge');
  assertNotLiveBrainPath(brainDst);
  assertNotLiveBrainPath(knowledgeDst);
  cpSync(join(frozenDir, 'brain'), brainDst, { recursive: true, preserveTimestamps: false });
  ensureDir(knowledgeDst);
  const kgSrc = join(frozenDir, 'knowledge-graph');
  if (existsSync(kgSrc)) cpSync(kgSrc, knowledgeDst, { recursive: true, preserveTimestamps: false });
  const wikiSrc = join(frozenDir, 'wiki');
  if (existsSync(wikiSrc)) cpSync(wikiSrc, join(knowledgeDst, 'wiki'), { recursive: true, preserveTimestamps: false });
}

function pluginDirFor(config, evalRoot, arm) {
  if (arm !== 'A' && arm !== 'B') return undefined;
  return join(evalRoot, 'plugins', arm.toLowerCase());
}

// Spawns `claude <argv>` (argv array — no shell) and collects the
// stream-json events. Resolves with { events, exitCode, stderr }.
function spawnClaude(argv, { cwd, env }) {
  return new Promise((resolvePromise) => {
    const child = spawn('claude', argv, { cwd, env, shell: false });
    let buf = '';
    const events = [];
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx); buf = buf.slice(idx + 1);
        if (line.trim().length === 0) continue;
        try { events.push(JSON.parse(line)); } catch { /* non-JSON stdout line — ignore, never crash the harness on a stray log line */ }
      }
    });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
    child.on('close', (code) => resolvePromise({ events, exitCode: code, stderr }));
    child.on('error', (err) => resolvePromise({ events, exitCode: null, stderr: String(err) }));
  });
}

async function executeOneRun({ cell, task, config, evalRoot, templateRepoDir, blocksDir }) {
  const sessionId = randomUUID();
  const runDir = join(evalRoot, 'runs', `${cell.task_id}-${cell.arm}-rep${cell.rep}-${sessionId.slice(0, 8)}`);
  assertNotLiveBrainPath(runDir);
  ensureDir(runDir);

  const worktreeDir = join(runDir, 'repo');
  createRunWorktree(templateRepoDir, worktreeDir);

  const frozenDir = join(evalRoot, 'frozen');
  seedSandbox(runDir, frozenDir);

  const tasksDoc = readJSON(join(HERE, 'tasks.json'));
  // Brain gets the extended (redaction-check-inclusive) pattern set since
  // that's where PROJECT.md lives; knowledge (which now includes the wiki)
  // keeps the base set — the frozen wiki snapshot legitimately contains the
  // redaction slug as an auto-created entity stub name (see lib.mjs
  // buildBrainLeakPatterns doc + tests/evals/README.md).
  assertNoLeaks(join(runDir, 'brain'), buildBrainLeakPatterns(tasksDoc));
  assertNoLeaks(join(runDir, 'knowledge'), buildLeakPatterns(tasksDoc));

  const env = buildRunEnv({ sourceEnv: process.env, runDir, arm: cell.arm });
  const settingsPath = join(runDir, 'settings.json');
  writeFileSync(settingsPath, JSON.stringify(buildSettingsJson(config.settings_allowlist), null, 2) + '\n', 'utf8');

  const argv = buildClaudeArgv({
    prompt: task.prompt,
    model: config.pins.model,
    effort: config.pins.effort,
    settingsPath,
    sessionId,
    arm: cell.arm,
    pluginDir: pluginDirFor(config, evalRoot, cell.arm),
    appendSystemPromptFile: cell.arm === 'C' ? join(blocksDir, `${cell.task_id}.md`) : undefined,
  });

  const { events, exitCode, stderr } = await spawnClaude(argv, { cwd: worktreeDir, env });

  const resultEvent = events.find((e) => e.type === 'result');
  const initEvent = events.find((e) => e.type === 'system' && e.subtype === 'init');
  const finalText = resultEvent?.result;
  const isError = Boolean(resultEvent?.is_error) || resultEvent === undefined;

  const toolUseBlocks = extractToolUseBlocks(events);
  const metrics = computeTouchMetrics(toolUseBlocks, task.correct_files, worktreeDir);

  if (cell.arm === 'A' || cell.arm === 'B') {
    assertSandboxContainsSessionId(join(runDir, 'brain'), sessionId);
  }
  postRunLiveLeakCheck(sessionId);

  return {
    task_id: cell.task_id, arm: cell.arm, rep: cell.rep, session_id: sessionId,
    model_reported: initEvent?.model,
    final_text: finalText,
    is_error: isError,
    api_error_status: resultEvent?.api_error_status ?? null,
    calls_before_first_correct: metrics.calls_before_first_correct,
    reached_correct_file: metrics.reached_correct_file,
    total_tool_calls: metrics.total_tool_calls,
    duration_ms: resultEvent?.duration_ms ?? null,
    cost: resultEvent?.total_cost_usd ?? null,
    permission_denials: (resultEvent?.permission_denials ?? []).length,
    used_agent: toolUseBlocks.some((b) => b.name === 'Agent' || b.name === 'Task'),
    exit_code: exitCode,
    stderr_tail: stderr.slice(-2000),
  };
}

async function runCells(cells, ctx) {
  const scheduler = new RunScheduler(ctx.config.pins.concurrency);
  const runsPath = join(ctx.evalRoot, 'runs.jsonl');
  await Promise.all(cells.map(async (cell) => {
    await scheduler.acquire(cell.arm);
    try {
      let attempt = 0;
      let record;
      for (;;) {
        record = await executeOneRun({ cell, task: ctx.taskById.get(cell.task_id), ...ctx });
        if (!shouldRetry(attempt, record)) break;
        attempt += 1;
        console.log(`retrying ${cell.task_id}/${cell.arm}/rep${cell.rep} after ${RETRY_DELAY_MS}ms (attempt ${attempt})`);
        await new Promise((r) => setTimeout(r, RETRY_DELAY_MS));
      }
      appendJSONLine(runsPath, record);
      console.log(`done: ${cell.task_id}/${cell.arm}/rep${cell.rep} correct-pending-score is_error=${record.is_error}`);
    } finally {
      scheduler.release(cell.arm);
    }
  }));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const evalRoot = resolve(args.evalRoot || process.env.SB_EVAL_ROOT || '');
  if (!evalRoot) { console.error('--eval-root (or SB_EVAL_ROOT) is required; run prepare.mjs first'); process.exit(2); }
  const planPath = join(evalRoot, 'run-plan.json');
  if (!existsSync(planPath)) { console.error(`${planPath} missing — run prepare.mjs first`); process.exit(2); }

  const config = readJSON(join(HERE, 'config.json'));
  const tasksDoc = readJSON(join(HERE, 'tasks.json'));
  assertReady(config, args.mode);

  const taskById = new Map(tasksDoc.tasks.map((t) => [t.id, t]));
  const templateRepoDir = join(evalRoot, 'repo-template');
  if (!existsSync(templateRepoDir) && !args.repoSource) {
    console.error(`${templateRepoDir} does not exist yet and no --repo-source was given (the local checkout to \`git clone --no-local\` from)`);
    process.exit(2);
  }
  ensureRepoTemplate({
    repoDir: templateRepoDir,
    sourcePath: args.repoSource,
    originUrl: config.repo_template.origin_url,
    commit: config.pins.task_repo_commit,
  });

  const fullPlan = readJSON(planPath);
  const blocksDir = join(evalRoot, 'blocks');

  let cells;
  if (args.mode === 'smoke') {
    // build order step 6: t09 + c01 x A-D x 1 rep, plus one D calibration run
    // forcing an Explore subagent, concurrency 1 (handled by the scheduler
    // config override below).
    cells = [];
    for (const taskId of ['s1-t09', 's1-c01']) {
      for (const arm of ['A', 'B', 'C', 'D']) cells.push({ task_id: taskId, arm, rep: 0 });
    }
    cells.push({ task_id: 's1-t09', arm: 'D', rep: 'calibration-explore' });
    config.pins.concurrency = { max_total: 1, max_ab: 1 };
  } else if (args.mode === 'full') {
    cells = fullPlan;
  } else {
    const existing = readExistingRuns(join(evalRoot, 'runs.jsonl'));
    const done = new Set(existing.map(cellKey));
    cells = fullPlan.filter((c) => !done.has(cellKey(c)));
    console.log(`resume: ${existing.length} run(s) already recorded, ${cells.length} remaining`);
  }

  await runCells(cells, { config, taskById, evalRoot, templateRepoDir, blocksDir });
  console.log(`\n${args.mode} complete: ${cells.length} cell(s) executed -> ${join(evalRoot, 'runs.jsonl')}`);
}

main().catch((err) => {
  console.error(`run.mjs failed: ${err.message}`);
  process.exit(1);
});
