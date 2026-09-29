#!/usr/bin/env node
// S1 harness — one-time EVAL_ROOT setup (build order steps 1 and part of 3).
//
// Responsibilities:
//   1. Import the frozen brain/knowledge-graph snapshots into EVAL_ROOT
//      (never re-snapshots the live brain — it only ever READS the
//      --snapshot-src the caller points it at).
//   2. Verify each snapshot's manifest hash against config.json's pin.
//   3. Leak-scan the snapshot BEFORE import; abort on any hit.
//   4. Redact PROJECT.md's experiment-meta line in the imported copy.
//   5. Build plugin dirs A and B from the pinned plugin commit (SKIPPED with
//      a logged reason while config.json's plugin_commit is still the
//      "TBD-after-S0-merge" placeholder).
//   6. Generate the pre-registered, seeded run-plan (3 blocks x 48 cells).
//   7. Write prepare-report.json summarizing what ran vs. what was skipped.
//
// --dry-run performs every read-only check (leak scan, hash verification,
// run-plan generation) and writes a lightweight report, but skips the
// snapshot copy, PROJECT.md redaction, plugin-dir build, and any git/network
// operation. It never writes outside EVAL_ROOT and never touches the live
// brain (guarded by assertNotLiveBrainPath on every write target).
//
// Usage:
//   node prepare.mjs --snapshot-src <dir> [--eval-root <dir>] [--id <id>] [--dry-run]

import { existsSync, readdirSync, statSync, readFileSync, writeFileSync, cpSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import {
  readJSON, ensureDir, sha256File, assertNotLiveBrainPath,
  buildLeakPatterns, assertNoLeaks, buildRunPlan,
} from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = { dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run') args.dryRun = true;
    else if (a === '--snapshot-src') args.snapshotSrc = argv[++i];
    else if (a === '--eval-root') args.evalRoot = argv[++i];
    else if (a === '--id') args.id = argv[++i];
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return args;
}

function defaultEvalRootBase() {
  const base = process.env.LOCALAPPDATA;
  if (!base) {
    // Fail loud: no silent fallback to a guessable temp dir that could end
    // up somewhere unexpected (or under HOME, which the guard would reject
    // anyway).
    throw new Error('LOCALAPPDATA is not set and no --eval-root was given; refusing to guess EVAL_ROOT');
  }
  return join(base, 'sb-evals', 's1');
}

function findSha256sums(dir) {
  const path = join(dir, 'SHA256SUMS');
  if (!existsSync(path)) throw new Error(`snapshot missing SHA256SUMS: ${dir}`);
  return path;
}

function verifySnapshotManifest(name, dir, expectedHash) {
  if (!expectedHash) {
    console.log(`SKIP: ${name} manifest hash check (no pin in config.json — optional snapshot)`);
    return;
  }
  const manifestPath = findSha256sums(dir);
  const actual = sha256File(manifestPath);
  if (actual !== expectedHash) {
    throw new Error(`${name} manifest hash mismatch: expected ${expectedHash}, got ${actual} (${manifestPath})`);
  }
  console.log(`OK: ${name} manifest hash verified (${actual.slice(0, 12)}...)`);
}

// Finds every PROJECT.md under `brainDir` and redacts the line matching the
// pinned experiment-meta text (SPEC.md "redactions": PROJECT.md line 67).
// Matches on CONTENT, not a hardcoded line number, so it keeps working if
// the snapshot is re-taken and the line shifts — but fails loud if a
// PROJECT.md exists with no matching line, since that means the pin is
// stale and needs a human look, not a silent no-op.
const EXPERIMENT_META_RE = /Proposed a pre-registered A\/B\/C falsification test/i;

function redactProjectMdFiles(brainDir) {
  const redacted = [];
  const projectsDir = join(brainDir, 'projects');
  if (!existsSync(projectsDir)) return redacted;
  for (const name of readdirSync(projectsDir)) {
    const pmPath = join(projectsDir, name, 'PROJECT.md');
    if (!existsSync(pmPath)) continue;
    const lines = readFileSync(pmPath, 'utf8').split('\n');
    let hit = false;
    const out = lines.map((line) => {
      if (EXPERIMENT_META_RE.test(line)) { hit = true; return '- [redacted: experiment meta]'; }
      return line;
    });
    if (hit) {
      writeFileSync(pmPath, out.join('\n'), 'utf8');
      redacted.push(pmPath);
    }
  }
  return redacted;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const id = args.id || new Date().toISOString().replace(/[:.]/g, '-');
  const evalRoot = resolve(args.evalRoot || join(defaultEvalRootBase(), id));
  assertNotLiveBrainPath(evalRoot);
  ensureDir(evalRoot);

  const tasksDoc = readJSON(join(HERE, 'tasks.json'));
  const config = readJSON(join(HERE, 'config.json'));
  const report = { eval_root: evalRoot, dry_run: args.dryRun, steps: [] };
  const log = (step, status, detail) => { report.steps.push({ step, status, detail }); console.log(`[${status}] ${step}${detail ? ' — ' + detail : ''}`); };

  // Step 1: snapshot source + leak-scan BEFORE import (abort on hit).
  if (!args.snapshotSrc) {
    log('snapshot-import', 'SKIP', 'no --snapshot-src given; nothing to import');
  } else {
    const src = resolve(args.snapshotSrc);
    const patterns = buildLeakPatterns(tasksDoc);
    const brainSrc = join(src, config.snapshots.brain.dir_name);
    const kgSrc = join(src, config.snapshots.knowledge_graph.dir_name);
    for (const [name, dir] of [['brain', brainSrc], ['knowledge_graph', kgSrc]]) {
      if (!existsSync(dir)) throw new Error(`snapshot source missing ${name} at ${dir}`);
      assertNoLeaks(dir, patterns); // throws (aborts) on any hit
      log(`leak-scan:${name}`, 'OK', `${dir} clean`);
    }
    verifySnapshotManifest('brain', brainSrc, config.snapshots.brain.manifest_sha256);
    verifySnapshotManifest('knowledge_graph', kgSrc, config.snapshots.knowledge_graph.manifest_sha256);

    if (args.dryRun) {
      log('snapshot-import', 'SKIP', 'dry-run: not copying into EVAL_ROOT');
      log('project-md-redaction', 'SKIP', 'dry-run: nothing imported yet to redact');
    } else {
      const frozenDir = join(evalRoot, 'frozen');
      const brainDst = join(frozenDir, 'brain');
      const kgDst = join(frozenDir, 'knowledge-graph');
      assertNotLiveBrainPath(brainDst);
      assertNotLiveBrainPath(kgDst);
      cpSync(brainSrc, brainDst, { recursive: true, preserveTimestamps: false });
      cpSync(kgSrc, kgDst, { recursive: true, preserveTimestamps: false });
      log('snapshot-import', 'OK', `copied brain -> ${brainDst}, knowledge-graph -> ${kgDst}`);

      const redacted = redactProjectMdFiles(brainDst);
      if (redacted.length === 0) {
        throw new Error('project-md-redaction: no PROJECT.md line matched the pinned experiment-meta text — pin is stale, investigate before continuing');
      }
      log('project-md-redaction', 'OK', redacted.join(', '));

      // Re-scan the imported (and now redacted) copy — belt-and-suspenders,
      // catches anything the copy step introduced.
      assertNoLeaks(brainDst, patterns);
      assertNoLeaks(kgDst, patterns);
      log('leak-scan:post-import', 'OK', 'imported copies clean');
    }
  }

  // Step: plugin dirs A/B — skipped until the plugin commit is pinned.
  if (config.pins.plugin_commit === 'TBD-after-S0-merge') {
    log('build-plugin-dirs', 'SKIP', 'config.json pins.plugin_commit is still the placeholder; run again after S0 merges and the pin is filled in');
  } else {
    log('build-plugin-dirs', 'SKIP', 'not implemented in this dispatch (out of scope: steps 1-5 only); see tests/evals/README.md Gaps');
  }

  // Step: repo template clone — needs network; never run automatically here.
  log('repo-template-clone', 'SKIP', 'network operation, not run by prepare.mjs automatically; ensureRepoTemplate() in lib.mjs is called by run.mjs before the first real run');

  // Step: run-plan generation (pure, deterministic — always runs).
  const arms = Object.keys(config.arms).filter((a) => a !== 'C2');
  const plan = buildRunPlan(tasksDoc, arms, config.pins.seed, config.pins.reps);
  const planPath = join(evalRoot, 'run-plan.json');
  writeFileSync(planPath, JSON.stringify(plan, null, 2) + '\n', 'utf8');
  log('run-plan', 'OK', `${plan.length} cells (${tasksDoc.tasks.length} tasks x ${arms.length} arms x ${config.pins.reps} reps) -> ${planPath}`);

  const reportPath = join(evalRoot, 'prepare-report.json');
  writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', 'utf8');
  console.log(`\nprepare-report.json -> ${reportPath}`);
}

main();
