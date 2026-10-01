#!/usr/bin/env node
// S1 harness — one-time EVAL_ROOT setup (build order steps 1 and part of 3).
//
// Responsibilities:
//   1. Import the frozen brain/knowledge-graph/wiki snapshots into EVAL_ROOT
//      (never re-snapshots the live brain — it only ever READS the
//      --snapshot-src the caller points it at; the wiki snapshot itself is a
//      one-time `git --git-dir ~/.second-brain/wiki-history.git archive
//      <full commit>` extraction done outside this script, per
//      tests/evals/README.md).
//   2. Verify each snapshot's manifest hash against config.json's pin, and
//      the wiki's .md count against expected_md_count.
//   3. Leak-scan the snapshot BEFORE import; abort on any hit.
//   4. Redact PROJECT.md's experiment-meta lines (line 67 AND line ~96) in
//      the imported copy.
//   5. Build plugin dirs A and B from `--plugin-commit`/`--repo-source` (a
//      `git archive` of the repo's plugin/ at that commit, plus B's
//      hooks.json rewritten per config.json's hook_removal_b); SKIPPED with
//      a logged reason when --plugin-commit isn't given.
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
//     [--plugin-commit <sha> --repo-source <dir>]

import { existsSync, readdirSync, statSync, readFileSync, writeFileSync, cpSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import {
  readJSON, ensureDir, sha256File, assertNotLiveBrainPath,
  buildLeakPatterns, buildBrainLeakPatterns, assertNoLeaks, buildRunPlan,
  redactLines, REDACTION_PATTERNS, buildArmPluginDirs,
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
    else if (a === '--plugin-commit') args.pluginCommit = argv[++i];
    else if (a === '--repo-source') args.repoSource = argv[++i];
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

// Counts files with `ext` anywhere under `dir` (recursive). Used to validate
// the imported wiki snapshot against config.json's expected_md_count.
function walkFilesCount(dir, ext) {
  let count = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) count += walkFilesCount(full, ext);
    else if (entry.isFile() && full.toLowerCase().endsWith(ext)) count += 1;
  }
  return count;
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

// Finds every PROJECT.md under `brainDir` and redacts every line matching
// REDACTION_PATTERNS (lib.mjs): line 67's experiment-meta sentence AND the
// line ~96 `[[context-injection-falsification-test]]` wiki-link mention one
// section below it (SPEC.md's own redaction list only names line 67 — see
// tests/evals/README.md for why line 96 needed adding). Matches on CONTENT,
// not a hardcoded line number, so this keeps working if the snapshot is
// re-taken and the lines shift — but fails loud if a PROJECT.md exists with
// no matching line at all, since that means the pins are stale and need a
// human look, not a silent no-op.
function redactProjectMdFiles(brainDir) {
  const redacted = [];
  const projectsDir = join(brainDir, 'projects');
  if (!existsSync(projectsDir)) return redacted;
  for (const name of readdirSync(projectsDir)) {
    const pmPath = join(projectsDir, name, 'PROJECT.md');
    if (!existsSync(pmPath)) continue;
    const { text, hits } = redactLines(readFileSync(pmPath, 'utf8'), REDACTION_PATTERNS);
    if (hits.length > 0) {
      writeFileSync(pmPath, text, 'utf8');
      redacted.push({ path: pmPath, hits });
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
    const wikiSrc = join(src, config.snapshots.wiki.dir_name);
    for (const [name, dir] of [['brain', brainSrc], ['knowledge_graph', kgSrc], ['wiki', wikiSrc]]) {
      if (!existsSync(dir)) throw new Error(`snapshot source missing ${name} at ${dir}`);
      assertNoLeaks(dir, patterns); // throws (aborts) on any hit — base patterns only (see buildBrainLeakPatterns doc: the wiki legitimately contains the redaction slug as an entity stub name)
      log(`leak-scan:${name}`, 'OK', `${dir} clean`);
    }
    verifySnapshotManifest('brain', brainSrc, config.snapshots.brain.manifest_sha256);
    verifySnapshotManifest('knowledge_graph', kgSrc, config.snapshots.knowledge_graph.manifest_sha256);
    verifySnapshotManifest('wiki', wikiSrc, config.snapshots.wiki.manifest_sha256);
    const wikiMdCount = walkFilesCount(wikiSrc, '.md');
    if (wikiMdCount !== config.snapshots.wiki.expected_md_count) {
      throw new Error(`wiki snapshot .md count mismatch: expected ${config.snapshots.wiki.expected_md_count}, got ${wikiMdCount} (${wikiSrc})`);
    }
    log('wiki-md-count', 'OK', `${wikiMdCount} .md files`);

    if (args.dryRun) {
      log('snapshot-import', 'SKIP', 'dry-run: not copying into EVAL_ROOT');
      log('project-md-redaction', 'SKIP', 'dry-run: nothing imported yet to redact');
    } else {
      const frozenDir = join(evalRoot, 'frozen');
      const brainDst = join(frozenDir, 'brain');
      const kgDst = join(frozenDir, 'knowledge-graph');
      const wikiDst = join(frozenDir, 'wiki');
      assertNotLiveBrainPath(brainDst);
      assertNotLiveBrainPath(kgDst);
      assertNotLiveBrainPath(wikiDst);
      cpSync(brainSrc, brainDst, { recursive: true, preserveTimestamps: false });
      cpSync(kgSrc, kgDst, { recursive: true, preserveTimestamps: false });
      cpSync(wikiSrc, wikiDst, { recursive: true, preserveTimestamps: false });
      log('snapshot-import', 'OK', `copied brain -> ${brainDst}, knowledge-graph -> ${kgDst}, wiki -> ${wikiDst}`);

      const redacted = redactProjectMdFiles(brainDst);
      const patternsHit = new Set(redacted.flatMap((r) => r.hits.map((h) => h.pattern)));
      const missingPatterns = REDACTION_PATTERNS.map((p) => p.name).filter((n) => !patternsHit.has(n));
      if (redacted.length === 0 || missingPatterns.length > 0) {
        throw new Error(`project-md-redaction: expected every redaction pattern to fire at least once, missing: ${missingPatterns.join(', ') || '(no PROJECT.md line matched at all)'} — pin is stale, investigate before continuing`);
      }
      log('project-md-redaction', 'OK', redacted.map((r) => `${r.path} (${r.hits.map((h) => h.pattern).join('+')})`).join(', '));

      // Re-scan the imported (and now redacted) copy — belt-and-suspenders,
      // catches anything the copy step introduced. Brain gets the extended
      // (redaction-check-inclusive) pattern set since that's where PROJECT.md
      // lives; knowledge-graph/wiki keep the base set (see buildBrainLeakPatterns).
      assertNoLeaks(brainDst, buildBrainLeakPatterns(tasksDoc));
      assertNoLeaks(kgDst, patterns);
      assertNoLeaks(wikiDst, patterns);
      log('leak-scan:post-import', 'OK', 'imported copies clean');
    }
  }

  // Step: plugin dirs A/B — built from --plugin-commit/--repo-source when
  // both are given (independent of config.json's pins.plugin_commit, which
  // stays the pre-registration placeholder until S0 merges); otherwise
  // skipped with a reason.
  if (args.dryRun) {
    log('build-plugin-dirs', 'SKIP', 'dry-run: not building plugin dirs');
  } else if (!args.pluginCommit) {
    log('build-plugin-dirs', 'SKIP', 'no --plugin-commit given (config.json pins.plugin_commit is still the placeholder until S0 merges)');
  } else if (!args.repoSource) {
    throw new Error('--plugin-commit given without --repo-source (the local checkout to `git archive` plugin/ from)');
  } else {
    const pluginsDir = join(evalRoot, 'plugins');
    const { aDir, bDir } = buildArmPluginDirs({
      repoSource: resolve(args.repoSource),
      pluginCommit: args.pluginCommit,
      pluginsDir,
      hookRemoval: config.hook_removal_b,
    });
    log('build-plugin-dirs', 'OK', `a -> ${aDir}, b -> ${bDir} (differ only in hooks/hooks.json, asserted)`);
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
