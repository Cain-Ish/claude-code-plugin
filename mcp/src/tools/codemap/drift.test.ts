import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { currentRev, isDirty, isStale } from './drift.js';
import type { GitRunner } from './scan-sources.js';
import type { CodeGraph } from './types.js';

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
  });

  describe('isDirty', () => {
    it('true when status --porcelain is non-empty', async () => {
      expect(await isDirty('/repo', gitAt(REV_A, ' M src/a.ts\n'))).toBe(true);
    });

    it('false when status --porcelain is empty', async () => {
      expect(await isDirty('/repo', gitAt(REV_A))).toBe(false);
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
  });
});
