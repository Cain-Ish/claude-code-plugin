#!/usr/bin/env node
// S1 harness — scoring + pre-registered decision rules.
//
// Usage:
//   node score.mjs selftest                 run the built-in self-test, exit 0/1
//   node score.mjs run <runs.jsonl> [--out results.json]
//                                            score a runs.jsonl produced by run.mjs
//                                            and apply the decision rules
//
// runs.jsonl (one JSON object per line, written by run.mjs) is expected to
// carry at least: task_id, arm, rep, session_id, final_text, is_error,
// calls_before_first_correct, reached_correct_file, total_tool_calls.
// This script derives `correct`/`flags`/`no_answer_line` from final_text
// using tasks.json (never trusts a precomputed `correct` field), then
// applies the SPEC.md decision rules over the derived results.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  readJSON, scoreRun, computeDecisionRules, pairedBootstrapDeltaTasks,
  buildAuditSample, scrubEnv, applyArmEnv, assertEnvScrubbed,
  computeTouchMetrics, extractToolUseBlocks, buildLeakPatterns, buildBrainLeakPatterns, scanTextForLeaks,
  buildArmBHooks, redactLines, REDACTION_PATTERNS,
} from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TASKS_PATH = join(HERE, 'tasks.json');
const CONFIG_PATH = join(HERE, 'config.json');
const REPO_ROOT = resolve(HERE, '..', '..', '..');

function loadTasksDoc() {
  return readJSON(TASKS_PATH);
}

function scoreRunsAgainstTasks(tasksDoc, rawRuns) {
  const byId = new Map(tasksDoc.tasks.map((t) => [t.id, t]));
  const out = [];
  for (const raw of rawRuns) {
    const task = byId.get(raw.task_id);
    if (!task) throw new Error(`runs.jsonl references unknown task_id: ${raw.task_id}`);
    const { correct, no_answer_line, flags } = scoreRun(task, tasksDoc.scoring, raw.final_text, raw.is_error);
    out.push({
      ...raw,
      correct,
      no_answer_line,
      flags,
      answer_text: raw.final_text, // kept for the audit sample; not re-derived here
    });
  }
  return out;
}

function cmdRun(runsPath, outPath) {
  const tasksDoc = loadTasksDoc();
  const lines = readFileSync(runsPath, 'utf8').split('\n').filter((l) => l.trim().length > 0);
  const rawRuns = lines.map((l) => JSON.parse(l));
  const scored = scoreRunsAgainstTasks(tasksDoc, rawRuns);
  const decision = computeDecisionRules(tasksDoc, scored);
  const bootstrap = pairedBootstrapDeltaTasks(tasksDoc, scored);
  const audit = buildAuditSample(scored);
  const result = { decision, bootstrap_reported_not_gating: bootstrap, audit_sample_reported_not_gating: audit.blinded, n_runs_scored: scored.length };
  const text = JSON.stringify(result, null, 2) + '\n';
  if (outPath) {
    writeFileSync(outPath, text, 'utf8');
    if (audit.key.length > 0) writeFileSync(outPath.replace(/\.json$/, '') + '.audit-key.json', JSON.stringify(audit.key, null, 2) + '\n', 'utf8');
    console.log(`wrote ${outPath}`);
  } else {
    process.stdout.write(text);
  }
}

// ---------------------------------------------------------------------------
// selftest
// ---------------------------------------------------------------------------

function assertEqual(actual, expected, label, failures) {
  if (actual !== expected) failures.push(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function runSelftest() {
  const tasksDoc = loadTasksDoc();
  const failures = [];
  let cases = 0;

  // 1. Every gold answer scores correct.
  for (const t of tasksDoc.tasks) {
    cases++;
    const { correct } = scoreRun(t, tasksDoc.scoring, t.gold_answer, false);
    if (!correct) failures.push(`gold answer for ${t.id} did not score correct`);
  }

  // 2. Every wrong answer in tasks.json fails.
  for (const t of tasksDoc.tasks) {
    for (const w of t.wrong_answers) {
      cases++;
      const { correct } = scoreRun(t, tasksDoc.scoring, w, false);
      if (correct) failures.push(`wrong answer for ${t.id} scored correct: ${JSON.stringify(w)}`);
    }
  }

  // 3. is_error / missing final_text always score incorrect with no_answer_line.
  {
    cases++;
    const t = tasksDoc.tasks[0];
    const r1 = scoreRun(t, tasksDoc.scoring, t.gold_answer, true); // is_error=true even with a gold-shaped answer
    if (r1.correct !== false || r1.no_answer_line !== true) failures.push('is_error=true did not force correct=false/no_answer_line=true');
    const r2 = scoreRun(t, tasksDoc.scoring, undefined, false);
    if (r2.correct !== false || r2.no_answer_line !== true) failures.push('missing final_text did not force correct=false/no_answer_line=true');
  }

  // 4. Decision-rule arithmetic on a synthetic runs.jsonl: falsified, not
  //    falsified, inconclusive (saturated), and harm cases, each isolated on
  //    its own 12-task set so the four scenarios can't interact.
  const taskIds = tasksDoc.tasks.map((t) => t.id); // 12 ids: s1-t01..09, s1-c01..03
  function makeRuns(perTaskArmCorrect) {
    // perTaskArmCorrect: fn(taskId, arm) -> number of correct reps out of 3
    const runs = [];
    for (const t of taskIds) {
      for (const arm of ['A', 'B', 'C', 'D']) {
        const nCorrect = perTaskArmCorrect(t, arm);
        for (let rep = 0; rep < 3; rep++) {
          runs.push({
            task_id: t, arm, rep,
            correct: rep < nCorrect,
            calls_before_first_correct: rep < nCorrect ? 5 : 20,
            reached_correct_file: rep < nCorrect,
            session_id: `synthetic-${t}-${arm}-${rep}`,
          });
        }
      }
    }
    return runs;
  }

  // 4a. "Not falsified": A clearly beats B on every task (large Δtasks, large
  // R) — decision rule must NOT declare push falsified.
  {
    cases++;
    const runs = makeRuns((t, arm) => (arm === 'A' ? 3 : arm === 'B' ? 0 : 1));
    const d = computeDecisionRules(tasksDoc, runs);
    if (d.delta_tasks_ab < 2) failures.push(`not-falsified case: expected delta_tasks_ab >= 2, got ${d.delta_tasks_ab}`);
    if (d.push_falsified) failures.push('not-falsified case: push_falsified was true');
  }

  // 4b. "Falsified": A and B pass/fail identically on every task and take the
  // same number of calls — Δtasks=0, R=0, both below threshold.
  {
    cases++;
    const runs = makeRuns((t, arm) => (arm === 'A' || arm === 'B' ? 3 : 1));
    const d = computeDecisionRules(tasksDoc, runs);
    assertEqual(d.delta_tasks_ab, 0, 'falsified case: delta_tasks_ab', failures);
    assertEqual(d.R, 0, 'falsified case: R', failures);
    if (!d.push_falsified) failures.push('falsified case: push_falsified was false');
  }

  // 4c. "Inconclusive": B and D both saturate (3/3) on >=6 of the 12 tasks.
  {
    cases++;
    const runs = makeRuns((t, arm) => {
      const idx = taskIds.indexOf(t);
      const saturated = idx < 7; // 7 of 12 tasks saturated
      if (arm === 'B' || arm === 'D') return saturated ? 3 : 1;
      return 2;
    });
    const d = computeDecisionRules(tasksDoc, runs);
    if (d.saturated_tasks.length < 6) failures.push(`inconclusive case: expected >=6 saturated tasks, got ${d.saturated_tasks.length}`);
    if (!d.inconclusive) failures.push('inconclusive case: inconclusive was false');
  }

  // 4d. "Harm": A's pass rate is >=2/3 below D's on at least one task.
  {
    cases++;
    const runs = makeRuns((t, arm) => {
      if (taskIds.indexOf(t) !== 0) return 2; // every other task: no harm signal
      if (arm === 'A') return 0; // rate 0/3
      if (arm === 'D') return 3; // rate 3/3, diff = 1 >= 2/3
      return 2;
    });
    const d = computeDecisionRules(tasksDoc, runs);
    if (!d.harm) failures.push('harm case: harm was false');
    if (!d.harm_tasks.includes(taskIds[0])) failures.push('harm case: harm_tasks missing the harmed task');
  }

  // 4e. Missing cells count as failures and are reported as excluded/missing.
  {
    cases++;
    const runs = makeRuns((t, arm) => (arm === 'A' ? 3 : arm === 'B' ? 0 : 1));
    // Drop all 3 reps for one task's B arm entirely.
    const dropped = runs.filter((r) => !(r.task_id === taskIds[1] && r.arm === 'B'));
    const d = computeDecisionRules(tasksDoc, dropped);
    const missingForTask = d.missing_cells.find((m) => m.task_id === taskIds[1] && m.arm === 'B');
    if (!missingForTask || missingForTask.present !== 0) failures.push('missing-cells case: dropped cell not reported as missing');
    // pass(taskIds[1], 'B') must be false (failure), so A should still count
    // as a Δtasks win on that task (A passes, B — missing — does not).
    if (!(d.delta_tasks_ab >= 2)) failures.push('missing-cells case: missing B cell was not treated as a failure in delta_tasks_ab');
  }

  // 5. Env scrub: SB_NESTED_SPAWN and CLAUDE* are removed by scrubEnv.
  {
    cases++;
    const dirty = {
      SB_NESTED_SPAWN: '1', CLAUDE_PROJECT_DIR: '/somewhere', CLAUDECODE: '1',
      ANTHROPIC_API_KEY: 'sk-x', BRAIN_DIR: '/old/brain', MSYS_NO_PATHCONV: '1',
      PATH: '/usr/bin', HOME: '/home/dev',
    };
    const scrubbed = scrubEnv(dirty, '/eval-root/runs/r1');
    if ('SB_NESTED_SPAWN' in scrubbed) failures.push('env scrub: SB_NESTED_SPAWN survived');
    for (const k of Object.keys(dirty)) {
      if (k.startsWith('CLAUDE') && k in scrubbed) failures.push(`env scrub: ${k} survived`);
    }
    if (!('PATH' in scrubbed) || !('HOME' in scrubbed)) failures.push('env scrub: unrelated vars were dropped');
    const leaks = assertEnvScrubbed(scrubbed);
    if (leaks.length > 0) failures.push(`env scrub: assertEnvScrubbed found leaks ${JSON.stringify(leaks)}`);
    const withArmB = applyArmEnv(scrubbed, 'B');
    assertEqual(withArmB.SB_JIT, 'off', 'env scrub: arm B SB_JIT', failures);
  }

  // 6. Leak guard: canary text in a fixture is caught.
  {
    cases++;
    const patterns = buildLeakPatterns(tasksDoc);
    const hits = scanTextForLeaks(`some notes... ${tasksDoc.canary} ...more notes`, patterns);
    if (!hits.some((h) => h.pattern === 'canary')) failures.push('leak guard: canary not detected in fixture text');
    const clean = scanTextForLeaks('nothing sensitive here at all', patterns);
    if (clean.length > 0) failures.push('leak guard: false positive on clean text');
  }

  // 7. Touch matching + calls_before_first_correct on a synthetic tool_use stream.
  {
    cases++;
    const runRoot = 'C:\\eval\\run1';
    const streamEvents = [
      { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'C:\\eval\\run1\\repo\\scripts\\lib.sh' } }] } },
      { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Grep', input: { path: 'repo/scripts', pattern: 'foo' } }] } },
      { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'C:\\eval\\run1\\repo\\scripts\\validate-plugin.sh' } }] } },
    ];
    const blocks = extractToolUseBlocks(streamEvents);
    assertEqual(blocks.length, 3, 'touch matching: block count', failures);
    const metrics = computeTouchMetrics(blocks, ['(^|/)scripts/validate-plugin\\.sh$'], runRoot);
    assertEqual(metrics.calls_before_first_correct, 2, 'touch matching: calls_before_first_correct', failures);
    assertEqual(metrics.reached_correct_file, true, 'touch matching: reached_correct_file', failures);
    assertEqual(metrics.total_tool_calls, 3, 'touch matching: total_tool_calls', failures);
    const censored = computeTouchMetrics(blocks, ['(^|/)nope\\.sh$'], runRoot);
    assertEqual(censored.calls_before_first_correct, 4, 'touch matching: censored calls_before_first_correct (total+1)', failures);
    assertEqual(censored.reached_correct_file, false, 'touch matching: censored reached_correct_file', failures);
    // Grep's pattern must never count as a touch even if it matches the regex.
    const grepPatternBlocks = extractToolUseBlocks([{ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Grep', input: { path: 'repo', pattern: 'validate-plugin.sh' } }] } }]);
    const grepMetrics = computeTouchMetrics(grepPatternBlocks, ['(^|/)validate-plugin\\.sh$'], runRoot);
    assertEqual(grepMetrics.reached_correct_file, false, 'touch matching: Grep pattern must not count as a touch', failures);
  }

  // 8. Arm B hook removal against the REAL hooks.json at origin/main (`git
  //    show origin/main:hooks/hooks.json`, read-only). Proves
  //    config.json's hook_removal_b actually matches the live file's
  //    structure — not just a synthetic fixture — and that everything
  //    outside the removal list survives byte-identical ("guards and MCP
  //    pull stay", SPEC.md).
  {
    cases++;
    const config = readJSON(CONFIG_PATH);
    const gitShow = spawnSync('git', ['show', 'origin/main:hooks/hooks.json'], { cwd: REPO_ROOT, encoding: 'utf8' });
    if (gitShow.status !== 0) {
      failures.push(`arm-B hook removal: \`git show origin/main:hooks/hooks.json\` failed: ${gitShow.stderr}`);
    } else {
      const realHooks = JSON.parse(gitShow.stdout);
      const bHooks = buildArmBHooks(realHooks, config.hook_removal_b);

      // Removed entirely.
      for (const event of ['UserPromptSubmit', 'SubagentStart', 'PostCompact']) {
        if (event in bHooks.hooks) failures.push(`arm-B hook removal: ${event} should be removed entirely, still present`);
      }
      // SessionStart "compact" group removed; "startup|resume|clear|fork" group survives minus the two named commands.
      const sessionStart = bHooks.hooks.SessionStart || [];
      if (sessionStart.some((g) => g.matcher === 'compact')) failures.push('arm-B hook removal: SessionStart compact group should be removed entirely');
      const startupGroup = sessionStart.find((g) => g.matcher === 'startup|resume|clear|fork');
      if (!startupGroup) failures.push('arm-B hook removal: SessionStart startup group should survive');
      else {
        const cmds = startupGroup.hooks.map((h) => h.command);
        if (cmds.some((c) => c.includes('session-load.sh'))) failures.push('arm-B hook removal: session-load.sh should be stripped from the startup group');
        if (cmds.some((c) => c.includes('protocol-guard.sh" card'))) failures.push('arm-B hook removal: protocol-guard.sh card should be stripped from the startup group');
        for (const survivor of ['ensure-dirs.sh', 'discover-installed.sh', 'discover-doc-sources.sh', 'dream-autostage.sh']) {
          if (!cmds.some((c) => c.includes(survivor))) failures.push(`arm-B hook removal: ${survivor} should survive in the startup group ("guards and MCP pull stay")`);
        }
      }
      // Everything else untouched, byte-identical.
      const originalStart = realHooks.hooks.SessionStart.find((g) => g.matcher === 'startup|resume|clear|fork');
      const untouchedEvents = Object.keys(realHooks.hooks).filter((e) => !['SessionStart', 'UserPromptSubmit', 'SubagentStart', 'PostCompact'].includes(e));
      for (const event of untouchedEvents) {
        if (JSON.stringify(bHooks.hooks[event]) !== JSON.stringify(realHooks.hooks[event])) {
          failures.push(`arm-B hook removal: ${event} should be byte-identical to A, was rewritten`);
        }
      }
      if (originalStart && startupGroup) {
        const survivingOriginal = originalStart.hooks.filter((h) => !h.command.includes('session-load.sh') && !h.command.includes('protocol-guard.sh" card'));
        if (JSON.stringify(startupGroup.hooks) !== JSON.stringify(survivingOriginal)) {
          failures.push('arm-B hook removal: surviving startup-group hooks should be byte-identical to A minus the two removed commands');
        }
      }
    }
  }

  // 9. PROJECT.md redaction covers BOTH the line-67 experiment-meta sentence
  //    AND the line ~96 `[[context-injection-falsification-test]]` wiki-link
  //    (tests/evals/README.md Gaps — SPEC.md's own redaction list only
  //    named line 67). Also proves the extended pattern set fails a future
  //    mention in a <run>/brain-scoped pre-run scan, without false-flagging
  //    unrelated wiki content on the base (non-brain) pattern set.
  {
    cases++;
    const tasksDoc = loadTasksDoc();
    const fixture = [
      '## Decisions',
      "- [2026-09-27] Proposed a pre-registered A/B/C falsification test (12 known-pitfall tasks x3 runs) with fixed kill criteria to decide whether context-injection layers should be cut.",
      '- [2026-09-27] An unrelated decision line that must survive untouched.',
      '## Cross-references',
      '- [[per-repo-key-fragility]]',
      '- [[context-injection-falsification-test]]',
      '- [[repo-overview-docs-dont-help-agents-pointers-do]]',
    ].join('\n');

    const { text: redacted, hits } = redactLines(fixture, REDACTION_PATTERNS);
    const hitNames = new Set(hits.map((h) => h.pattern));
    if (!hitNames.has('experiment-meta-line67')) failures.push('PROJECT.md redaction: line-67 pattern did not fire');
    if (!hitNames.has('experiment-meta-line96-wikilink')) failures.push('PROJECT.md redaction: line-96 wikilink pattern did not fire');
    if (redacted.includes('Proposed a pre-registered A/B/C falsification test')) failures.push('PROJECT.md redaction: line-67 text survived redaction');
    if (redacted.includes('[[context-injection-falsification-test]]')) failures.push('PROJECT.md redaction: line-96 wikilink survived redaction');
    if (!redacted.includes('An unrelated decision line that must survive untouched.')) failures.push('PROJECT.md redaction: an unrelated line was altered');
    if (!redacted.includes('[[per-repo-key-fragility]]')) failures.push('PROJECT.md redaction: an unrelated cross-reference was altered');

    // Pre-redaction: the brain-scoped pattern set must catch a future
    // mention (this is the "pre-run scan" the task asked to extend).
    const brainHitsBefore = scanTextForLeaks(fixture, buildBrainLeakPatterns(tasksDoc));
    if (!brainHitsBefore.some((h) => h.pattern === 'experiment-meta-line67')) failures.push('PROJECT.md redaction: brain-scoped pre-run scan missed the un-redacted line-67 text');
    if (!brainHitsBefore.some((h) => h.pattern === 'experiment-meta-line96-wikilink')) failures.push('PROJECT.md redaction: brain-scoped pre-run scan missed the un-redacted line-96 wikilink');

    // Post-redaction: the same scan must be clean (proves redaction actually removes what the scan looks for).
    const brainHitsAfter = scanTextForLeaks(redacted, buildBrainLeakPatterns(tasksDoc));
    if (brainHitsAfter.length > 0) failures.push(`PROJECT.md redaction: brain-scoped scan still flags the redacted text: ${JSON.stringify(brainHitsAfter)}`);

    // The base (non-brain) pattern set — used for <run>/knowledge/wiki — must
    // NOT flag this content even before redaction: the frozen wiki snapshot
    // legitimately contains "context-injection-falsification-test" as an
    // auto-created entity stub name among 377 unrelated entities, and that
    // must never abort a real run.
    const baseHits = scanTextForLeaks(fixture, buildLeakPatterns(tasksDoc));
    if (baseHits.length > 0) failures.push(`PROJECT.md redaction: base (wiki-safe) pattern set false-positived on experiment-meta text: ${JSON.stringify(baseHits)}`);
  }

  console.log(failures.length === 0
    ? `selftest OK: ${cases} cases passed`
    : `selftest FAILED: ${failures.length}/${cases} case(s) failed:\n  ${failures.join('\n  ')}`);
  return failures.length === 0;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function main() {
  const [, , cmd, ...rest] = process.argv;
  if (cmd === 'selftest') {
    process.exit(runSelftest() ? 0 : 1);
  } else if (cmd === 'run') {
    const runsPath = rest[0];
    if (!runsPath) { console.error('usage: node score.mjs run <runs.jsonl> [--out results.json]'); process.exit(2); }
    const outIdx = rest.indexOf('--out');
    const outPath = outIdx >= 0 ? rest[outIdx + 1] : undefined;
    cmdRun(runsPath, outPath);
  } else {
    console.error('usage: node score.mjs selftest | node score.mjs run <runs.jsonl> [--out results.json]');
    process.exit(2);
  }
}

main();
