/**
 * End-to-end control-flow tests for the code-map generator CLI.
 *
 * THE COMMITTED BUNDLE (mcp/dist/tools/code-map-cli.bundle.js) IS THE TEST
 * SUBJECT — it is what the drainer actually spawns. tests/test-bundle-current.sh
 * guarantees dist freshness in CI, so a stale LOCAL dist can make this test lag
 * src; rebuild with `npm run bundle` when editing the CLI.
 *
 * Covers the CLI's control flow only (generate / skip-when-fresh / --check /
 * --force / fail-soft) against a REAL temp git repo — the scan/extract filter
 * behavior is locked by the pure-module unit tests, not here.
 *
 * Env boundary: SB_BRAIN_DIR points the store at a temp brain (brain-paths.ts:
 * SB_BRAIN_DIR || BRAIN_DIR || ~/.second-brain), CLAUDE_PROJECT_DIR points the
 * scan at the temp repo (project-dir.ts: CLAUDE_PROJECT_DIR || cwd; slug =
 * registry match, else basename).
 */
import { describe, it, expect, afterEach } from 'vitest';
import { execFile, execFileSync } from 'child_process';
import { promisify } from 'util';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { basename, dirname, join } from 'path';
import { fileURLToPath } from 'url';
import type { CodeGraph } from './types.js';

const execFileAsync = promisify(execFile);

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLE = join(HERE, '..', '..', '..', 'dist', 'tools', 'code-map-cli.bundle.js');
const FIXTURES = join(HERE, '__fixtures__');

/** Env vars that would leak the developer's real brain/repo into the run. */
const ENV_CLEAR = [
  'SB_BRAIN_DIR',
  'BRAIN_DIR',
  'CLAUDE_PROJECT_DIR',
  'SB_CODEMAP_MAX_FILE_BYTES',
  'SB_CODEMAP_MAX_FILES',
  'SB_CODEMAP_TOKEN_BUDGET',
];

describe('code-map-cli bundle (end to end)', () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const d of tempDirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  function tempDir(prefix: string): string {
    const d = mkdtempSync(join(tmpdir(), prefix));
    tempDirs.push(d);
    return d;
  }

  /** Identity via -c flags (no reliance on the developer's git config);
   *  gpgsign forced off so a signing-enabled global config cannot hang CI. */
  function git(cwd: string, ...args: string[]): string {
    return execFileSync(
      'git',
      ['-c', 'user.name=sb-test', '-c', 'user.email=sb-test@example.invalid', '-c', 'commit.gpgsign=false', ...args],
      { cwd, stdio: 'pipe', windowsHide: true },
    ).toString();
  }

  /** Temp git repo with one committed source file + fresh temp brain. */
  function fixture(): { repo: string; brain: string; env: NodeJS.ProcessEnv } {
    const repo = tempDir('sb-codemap-cli-repo-');
    const brain = tempDir('sb-codemap-cli-brain-');
    git(repo, 'init', '--quiet');
    writeFileSync(join(repo, 'app.ts'), "import './helper.js';\nexport const a = 1;\n");
    writeFileSync(join(repo, 'helper.ts'), 'export const h = 2;\n');
    git(repo, 'add', '.');
    git(repo, 'commit', '--quiet', '-m', 'initial');
    return { repo, brain, env: cliEnv(repo, brain) };
  }

  function cliEnv(repo: string, brain: string): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env };
    for (const k of ENV_CLEAR) delete env[k];
    env.SB_BRAIN_DIR = brain;
    env.CLAUDE_PROJECT_DIR = repo;
    return env;
  }

  /** execFile rejects on a non-zero exit — a resolved promise IS the exit-0 assertion. */
  async function runCli(
    args: string[],
    env: NodeJS.ProcessEnv,
  ): Promise<{ stdout: string; stderr: string }> {
    return execFileAsync(process.execPath, [BUNDLE, ...args], {
      env,
      timeout: 30_000,
      windowsHide: true,
    });
  }

  function storeDir(brain: string, repo: string): string {
    return join(brain, 'projects', basename(repo), 'codemap');
  }

  function readStoredGraph(brain: string, repo: string): CodeGraph {
    return JSON.parse(readFileSync(join(storeDir(brain, repo), 'graph.json'), 'utf-8')) as CodeGraph;
  }

  function head(repo: string): string {
    return git(repo, 'rev-parse', 'HEAD').trim();
  }

  it('first run generates graph.json + map.md under the brain store, exit 0', async () => {
    const { repo, brain, env } = fixture();
    const { stderr } = await runCli([], env);
    expect(stderr).toContain('code-map:');
    expect(stderr).not.toContain('ERROR');
    const dir = storeDir(brain, repo);
    expect(existsSync(join(dir, 'graph.json'))).toBe(true);
    expect(existsSync(join(dir, 'map.md'))).toBe(true);
    const graph = readStoredGraph(brain, repo);
    expect(graph.schema).toBe(1);
    expect(graph.git_rev).toBe(head(repo));
    expect(graph.files.length).toBeGreaterThan(0);
  }, 30_000);

  it('immediate rerun skips when fresh (same rev, store untouched)', async () => {
    const { repo, brain, env } = fixture();
    await runCli([], env);
    const before = statSync(join(storeDir(brain, repo), 'graph.json')).mtimeMs;
    const { stderr } = await runCli([], env);
    expect(stderr).toMatch(/fresh.*skipped/);
    const after = statSync(join(storeDir(brain, repo), 'graph.json')).mtimeMs;
    expect(after).toBe(before);
  }, 30_000);

  it('--check prints fresh, then stale after a new commit moves HEAD', async () => {
    const { repo, env } = fixture();
    await runCli([], env);
    const freshRun = await runCli(['--check'], env);
    expect(freshRun.stdout.trim()).toBe('fresh');
    writeFileSync(join(repo, 'extra.ts'), 'export const x = 3;\n');
    git(repo, 'add', '.');
    git(repo, 'commit', '--quiet', '-m', 'add extra');
    const staleRun = await runCli(['--check'], env);
    expect(staleRun.stdout.trim()).toBe('stale');
  }, 30_000);

  it('--force regenerates: stored git_rev advances to the new HEAD', async () => {
    const { repo, brain, env } = fixture();
    await runCli([], env);
    const rev1 = readStoredGraph(brain, repo).git_rev;
    writeFileSync(join(repo, 'extra.ts'), 'export const x = 3;\n');
    git(repo, 'add', '.');
    git(repo, 'commit', '--quiet', '-m', 'add extra');
    const rev2 = head(repo);
    expect(rev2).not.toBe(rev1);
    const { stderr } = await runCli(['--force'], env);
    expect(stderr).not.toContain('skipped');
    expect(readStoredGraph(brain, repo).git_rev).toBe(rev2);
  }, 30_000);

  // --- Drift semantics (REQUIRE the current bundle: rebuild with
  // `npm run bundle` when editing drift.ts/code-map-cli.ts — a stale
  // committed bundle ignores the dirty bit and these two tests fail on it) ---

  it('dirty tree at generation records dirty:true and --check reports stale', async () => {
    const { repo, brain, env } = fixture();
    writeFileSync(join(repo, 'uncommitted.ts'), 'export const u = 9;\n'); // untracked => porcelain non-empty
    await runCli([], env);
    expect(readStoredGraph(brain, repo).dirty).toBe(true);
    const { stdout } = await runCli(['--check'], env);
    expect(stdout.trim()).toBe('stale'); // a previously-dirty tree is ALWAYS re-checked
  }, 30_000);

  it('previously-dirty graph regenerates on the no-flag path even at the same rev', async () => {
    const { repo, brain, env } = fixture();
    writeFileSync(join(repo, 'uncommitted.ts'), 'export const u = 9;\n');
    await runCli([], env);
    const before = statSync(join(storeDir(brain, repo), 'graph.json')).mtimeMs;
    const { stderr } = await runCli([], env); // same HEAD, but dirty-generated => regen, not skip
    expect(stderr).not.toContain('skipped');
    const after = statSync(join(storeDir(brain, repo), 'graph.json')).mtimeMs;
    expect(after).toBeGreaterThan(before);
  }, 30_000);

  it('clean regen after a dirty one clears the dirty bit and --check reads fresh', async () => {
    const { repo, brain, env } = fixture();
    writeFileSync(join(repo, 'uncommitted.ts'), 'export const u = 9;\n');
    await runCli([], env);
    git(repo, 'add', '.');
    git(repo, 'commit', '--quiet', '-m', 'commit the stray');
    await runCli([], env); // dirty store => regen; tree now clean
    expect(readStoredGraph(brain, repo).dirty).toBe(false);
    const { stdout } = await runCli(['--check'], env);
    expect(stdout.trim()).toBe('fresh');
  }, 30_000);

  it('fail-soft: nonexistent CLAUDE_PROJECT_DIR exits 0, reports on stderr, writes no store', async () => {
    const brain = tempDir('sb-codemap-cli-brain-');
    const missing = join(tmpdir(), 'sb-codemap-cli-definitely-missing-repo');
    // resolves => exit 0 (the hook-path fail-soft boundary; a reject here
    // would mean a codemap failure could fail the drain)
    const { stderr } = await runCli([], cliEnv(missing, brain));
    expect(stderr.length).toBeGreaterThan(0);
    expect(stderr).toContain('code-map:');
    expect(existsSync(join(brain, 'projects'))).toBe(false);
  }, 30_000);

  // --- D039: refuse to map a root that is not a recognizable project ---

  it('refuses a nogit temp root with no workspace manifest, exit 0, writes no store', async () => {
    const repo = tempDir('sb-codemap-cli-repo-');
    const brain = tempDir('sb-codemap-cli-brain-');
    writeFileSync(join(repo, 'scratch.ts'), 'export const s = 1;\n'); // no .git, no manifest
    const { stderr } = await runCli([], cliEnv(repo, brain));
    expect(stderr).toContain('code-map:');
    expect(stderr).toMatch(/temp/i);
    expect(existsSync(storeDir(brain, repo))).toBe(false);
  }, 30_000);

  // --- D037: absolute in-repo Python imports + tsconfig @/* aliases ---

  it('resolves absolute python imports and tsconfig @/* aliases into graph edges with non-uniform ranks', async () => {
    const repo = tempDir('sb-codemap-cli-repo-');
    const brain = tempDir('sb-codemap-cli-brain-');
    // Merges pkg/ (py-abs-import) and tsconfig.json + src/ (ts-alias) into the
    // repo root -- tsconfig discovery is root-level only (read once per scan).
    cpSync(join(FIXTURES, 'py-abs-import'), repo, { recursive: true });
    cpSync(join(FIXTURES, 'ts-alias'), repo, { recursive: true });
    git(repo, 'init', '--quiet');
    git(repo, 'add', '.');
    git(repo, 'commit', '--quiet', '-m', 'initial');
    const { stderr } = await runCli([], cliEnv(repo, brain));
    expect(stderr).not.toContain('ERROR');
    const graph = readStoredGraph(brain, repo);
    expect(graph.edges.length).toBeGreaterThan(0);
    expect(graph.edges).toContainEqual({ from: 'pkg/main.py', to: 'pkg/sub.py', type: 'imports' });
    expect(graph.edges).toContainEqual({ from: 'src/index.ts', to: 'src/util.ts', type: 'imports' });
    const ranks = new Set(graph.files.map((f) => f.rank));
    expect(ranks.size).toBeGreaterThan(1); // pagerank is non-uniform, not the 1/n degenerate case
  }, 30_000);
});
