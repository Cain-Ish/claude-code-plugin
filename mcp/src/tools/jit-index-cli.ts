#!/usr/bin/env node
// jit-index-cli.ts — thin CLI wrapper around rebuildJitIndex, spawned by stop-extract.sh's
// freshness rebuild (docs/plans/2026-09-24-repo-brain.md §F) and by tests. Dir resolution goes
// through brain-paths.ts ONLY — the home-dir env var below is never read directly (source-scan
// guarded).
// Usage: node jit-index-cli.bundle.js <slug> <repo_root>
import { rebuildJitIndex } from './jit-index.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';

async function main(): Promise<void> {
  const slug = process.argv[2];
  const repoRoot = process.argv[3];
  if (!slug || !repoRoot) {
    console.error(JSON.stringify({ event: 'jit-index-cli-bad-args', argv: process.argv.slice(2) }));
    process.exitCode = 1;
    return;
  }
  try {
    await rebuildJitIndex({
      brainDir: resolveBrainDir(),
      knowledgeDir: resolveKnowledgeDir(),
      slug,
      repoRoot,
    });
    process.exitCode = 0;
  } catch (e) {
    console.error(JSON.stringify({ event: 'jit-index-cli-failed', err: e instanceof Error ? e.message : String(e) }));
    process.exitCode = 1;
  }
}

main();
