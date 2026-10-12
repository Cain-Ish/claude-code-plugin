import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { currentRev, isDirty, isStale } from './drift.js';
import type { GitRunner } from './scan-sources.js';
import type { CodeGraph } from './types.js';

// Re-audit S7-5: records what the codemap's DEFAULT runner hands the shared jit-index runner (no git spawned).
const sharedRunnerCalls = vi.hoisted(() => [] as unknown[][]);
vi.mock('../jit-index.js', async importOriginal => ({
  ...(await importOriginal<typeof import('../jit-index.js')>()),
  defaultGitRunner: async (...a: unknown[]) => { sharedRunnerCalls.push(a); return `${'c'.repeat(40)}\n`; },
}));

const REV_A = 'a'.repeat(40);
const REV_B = 'b'.repeat(40);

/** Stubbed git — unit tests must never spawn a real git (plan Task C1). */
const gitAbsent: GitRunner = async () => {
  throw new Error('git absent');
};
function gitAt(rev: string, porcelain = ''): GitRunner {
  return async (args) => {
    if (args[0] === 'rev-parse') return `${rev}\n`;
    if (args[0] === 'status') return porcelain;
    throw new Error(`unexpected git ${args.join(' ')}`);
  };
}

function graphFixture(overrides: Partial<CodeGraph> = {}): CodeGraph {
  return {
    schema: 1,
    slug: 'proj',
    repo_root: join('some', 'repo'),
    git_rev: REV_A,
    dirty: false,
    generated_at: '2026-07-05T00:00:00.000Z',
    generator: 'regex-v1',
    truncated: false,
    files: [],
    symbols: [],
    edges: [],
    ...overrides,
  };
}

// scanSources reads these in its default parameters — clear them so an ambient
// developer environment cannot skew the nogit mtime-walk assertions.
const ENV_KEYS = ['SB_CODEMAP_MAX_FILE_BYTES', 'SB_CODEMAP_MAX_FILES'];

describe('drift', () => {
  const saved: Record<string, string | undefined> = {};
  const tempDirs: string[] = [];

  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });

  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    for (const d of tempDirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  function tempRepo(): string {
    const d = mkdtempSync(join(tmpdir(), 'sb-codemap-drift-'));
    tempDirs.push(d);
    return d;
  }

  describe('currentRev', () => {
    it('returns the trimmed sha from rev-parse', async () => {
      expect(await currentRev('/repo', gitAt(REV_A))).toBe(REV_A);
    });

    it("returns 'nogit' when git fails (no repo, no git, no commits)", async () => {
      expect(await currentRev('/repo', gitAbsent)).toBe('nogit');
    });

    it("returns 'nogit' on empty rev-parse output", async () => {
      expect(await currentRev('/repo', async () => '\n')).toBe('nogit');
    });

    // The out-of-band codemap inherited jit-index's 5 s: a slow `git status` on a large repo marked
    // every graph dirty, so each drainer tick regenerated it and code_map always read stale.
    it('the default runner gives git far more than jit-index\'s 5 s', async () => {
      sharedRunnerCalls.length = 0;
      expect(await currentRev('/repo')).toBe('c'.repeat(40));
      expect(sharedRunnerCalls).toHaveLength(1);
      expect(sharedRunnerCalls[0][2]).toBeGreaterThanOrEqual(30_000);
    });
  });

  describe('isDirty', () => {
    it('true when status --porcelain is non-empty', async () => {
      expect(await isDirty('/repo', gitAt(REV_A, ' M src/a.ts\n'))).toBe(true);
    });

    it('ignores untracked files (audit B9)', async () => {
      let seen: string[] = [];
      await isDirty('/repo', async (args) => { seen = args; return ''; });
      expect(seen).toContain('--untracked-files=no');
    });

    it('false when status --porcelain is empty', async () => {
      expect(await isDirty('/repo', gitAt(REV_A))).toBe(false);
    });

    it('true (unknown => stale) when git status times out, and says so', async () => {
      const err = vi.spyOn(console, 'error').mockImplementation(() => {});
      const timedOut: GitRunner = async () => { throw Object.assign(new Error('timed out'), { killed: true, signal: 'SIGTERM' }); };
      expect(await isDirty('/repo', timedOut)).toBe(true);
      expect(err).toHaveBeenCalledTimes(1);
      err.mockRestore();
    });

    it("false when git fails ('nogit' — no tree to be dirty against)", async () => {
      expect(await isDirty('/repo', gitAbsent)).toBe(false);
    });
  });

  describe('isStale', () => {
    it('fresh: same rev, clean-generated graph', async () => {
      expect(await isStale(graphFixture(), tempRepo(), gitAt(REV_A))).toBe(false);
    });

    it('stale: HEAD moved past the stored rev', async () => {
      expect(await isStale(graphFixture(), tempRepo(), gitAt(REV_B))).toBe(true);
    });

    it("stale: a 'nogit' store facing a real current rev (repo gained history)", async () => {
      expect(await isStale(graphFixture({ git_rev: 'nogit' }), tempRepo(), gitAt(REV_A))).toBe(
        true,
      );
    });

    it('stale: previously-dirty graph, even at the matching rev, without any git spawn', async () => {
      let calls = 0;
      const counting: GitRunner = async (args, cwd) => {
        calls++;
        return gitAt(REV_A)(args, cwd);
      };
      expect(await isStale(graphFixture({ dirty: true }), tempRepo(), counting)).toBe(true);
      expect(calls).toBe(0);
    });

    it('stale: both nogit and a tracked source is newer than generated_at', async () => {
      const repo = tempRepo();
      writeFileSync(join(repo, 'src.ts'), 'export const a = 1;\n'); // mtime = now
      const graph = graphFixture({
        git_rev: 'nogit',
        generated_at: '2020-01-01T00:00:00.000Z',
      });
      expect(await isStale(graph, repo, gitAbsent)).toBe(true);
    });

    it('fresh: both nogit and every source predates generated_at', async () => {
      const repo = tempRepo();
      const file = join(repo, 'src.ts');
      writeFileSync(file, 'export const a = 1;\n');
      const past = new Date('2020-01-01T00:00:00.000Z');
      utimesSync(file, past, past);
      const graph = graphFixture({
        git_rev: 'nogit',
        generated_at: new Date().toISOString(),
      });
      expect(await isStale(graph, repo, gitAbsent)).toBe(false);
    });

    it('stale: nogit path with an unreadable repoRoot (freshness unverifiable)', async () => {
      const missing = join(tmpdir(), 'sb-codemap-drift-definitely-missing');
      const graph = graphFixture({ git_rev: 'nogit' });
      expect(await isStale(graph, missing, gitAbsent)).toBe(true);
    });

    it('stale: nogit path with an unparseable generated_at (corrupt provenance)', async () => {
      const graph = graphFixture({ git_rev: 'nogit', generated_at: 'not-a-date' });
      expect(await isStale(graph, tempRepo(), gitAbsent)).toBe(true);
    });

    describe('scan_fingerprint fast path (D039)', () => {
      it('stale: file count changed even with a backdated mtime the old mtime-only walk would miss', async () => {
        const repo = tempRepo();
        const past = new Date('2020-01-01T00:00:00.000Z');
        const keptFile = join(repo, 'a.ts');
        writeFileSync(keptFile, 'export const a = 1;\n');
        utimesSync(keptFile, past, past);
        // A file ADDED after generation, but with a backdated mtime (e.g. a
        // restored/copied file) — the pre-fix mtime-only comparison sees no
        // mtime past generatedAt and would call this "fresh" (false negative).
        const addedFile = join(repo, 'b.ts');
        writeFileSync(addedFile, 'export const b = 2;\n');
        utimesSync(addedFile, past, past);
        const graph = graphFixture({
          git_rev: 'nogit',
          generated_at: new Date().toISOString(),
          scan_fingerprint: { file_count: 1, max_mtime_ms: past.getTime() },
        });
        expect(await isStale(graph, repo, gitAbsent)).toBe(true);
      });

      it('fresh: matching file count and max mtime via the fingerprint comparison', async () => {
        const repo = tempRepo();
        const past = new Date('2020-01-01T00:00:00.000Z');
        const file = join(repo, 'a.ts');
        writeFileSync(file, 'export const a = 1;\n');
        utimesSync(file, past, past);
        const graph = graphFixture({
          git_rev: 'nogit',
          generated_at: new Date().toISOString(),
          scan_fingerprint: { file_count: 1, max_mtime_ms: past.getTime() },
        });
        expect(await isStale(graph, repo, gitAbsent)).toBe(false);
      });

      it('stale: a newer max mtime than the stored fingerprint', async () => {
        const repo = tempRepo();
        const past = new Date('2020-01-01T00:00:00.000Z');
        const file = join(repo, 'a.ts');
        writeFileSync(file, 'export const a = 1;\n'); // mtime = now, past generatedAt-independent check
        const graph = graphFixture({
          git_rev: 'nogit',
          generated_at: new Date().toISOString(),
          scan_fingerprint: { file_count: 1, max_mtime_ms: past.getTime() },
        });
        expect(await isStale(graph, repo, gitAbsent)).toBe(true);
      });

      it('stale: unreadable repoRoot on the fingerprint path (freshness unverifiable)', async () => {
        const missing = join(tmpdir(), 'sb-codemap-drift-fingerprint-missing');
        const graph = graphFixture({
          git_rev: 'nogit',
          scan_fingerprint: { file_count: 0, max_mtime_ms: 0 },
        });
        expect(await isStale(graph, missing, gitAbsent)).toBe(true);
      });
    });
  });
});
