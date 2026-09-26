#!/usr/bin/env node
// jit-index-cli.ts — thin CLI wrapper around rebuildJitIndex, spawned by stop-extract.sh's
// freshness rebuild (docs/plans/2026-09-24-repo-brain.md §F) and by tests. Dir resolution goes
// through brain-paths.ts ONLY — the home-dir env var below is never read directly (source-scan
// guarded).
// Usage: node jit-index-cli.bundle.js <slug> <repo_root>
import { rebuildJitIndex } from './jit-index.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';
import { cleanEnvPath } from '../path-guard.js';

async function main(): Promise<void> {
  // CR-strip both argv values: a CRLF-tainted CLAUDE_PROJECT_DIR (the usual source of a
  // caller's repo_root/slug args on Windows) must resolve the SAME way here as everywhere
  // else cleanEnvPath already guards — else a stray \r turns repoRoot into a nonexistent
  // cwd, git spawns ENOENT, isNoGitError classifies it "no git here", and an empty index
  // gets written over a good one.
  const slug = cleanEnvPath(process.argv[2]);
  const repoRoot = cleanEnvPath(process.argv[3]);
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
