import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { codemapDir, readGraph, writeGraph } from './store.js';
import { resolveBrainDir } from '../../brain-paths.js';
import type { CodeGraph } from './types.js';

const GRAPH: CodeGraph = {
  schema: 1,
  slug: 'proj',
  repo_root: '/repo',
  git_rev: 'abc1234',
  dirty: false,
  generated_at: '2026-07-05T00:00:00.000Z',
  generator: 'regex-v1',
  truncated: false,
  files: [{ id: 'src/a.ts', lang: 'ts', rank: 0.5, symbols: ['foo'] }],
  symbols: [{ id: 'src/a.ts#foo', kind: 'function', file: 'src/a.ts', rank: 0.5 }],
  edges: [{ from: 'src/a.ts', to: 'src/b.ts', type: 'imports' }],
};

// resolveBrainDir honors SB_BRAIN_DIR first, then BRAIN_DIR -- clear BOTH so an
// ambient developer environment cannot leak into the override assertion.
const ENV_KEYS = ['SB_BRAIN_DIR', 'BRAIN_DIR'];

describe('codemap store', () => {
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

  function tempDir(): string {
    const d = mkdtempSync(join(tmpdir(), 'sb-codemap-store-'));
    tempDirs.push(d);
    return d;
  }

  it('codemapDir shapes BRAIN_DIR/projects/<slug>/codemap', () => {
    expect(codemapDir(join('x', 'brain'), 'proj')).toBe(
      join('x', 'brain', 'projects', 'proj', 'codemap'),
    );
  });

  it('round-trips graph.json and writes map.md, creating dirs recursively', async () => {
    const dir = codemapDir(tempDir(), 'proj'); // projects/proj/codemap does not exist yet
    await writeGraph(dir, GRAPH, 'src/a.ts \u2014 foo\n');
    expect(await readGraph(dir)).toEqual(GRAPH);
    expect(readFileSync(join(dir, 'map.md'), 'utf-8')).toBe('src/a.ts \u2014 foo\n');
  });

  it('leaves no temp residue after a write (atomic tmp+rename)', async () => {
    const dir = codemapDir(tempDir(), 'proj');
    await writeGraph(dir, GRAPH, 'm\n');
    expect(readdirSync(dir).sort()).toEqual(['graph.json', 'map.md']);
  });

  it('rewrite fully replaces the previous store (idempotent regen)', async () => {
    const dir = codemapDir(tempDir(), 'proj');
    await writeGraph(dir, GRAPH, 'one\n');
    await writeGraph(dir, { ...GRAPH, git_rev: 'def5678' }, 'two\n');
    const g = await readGraph(dir);
    expect(g!.git_rev).toBe('def5678');
    expect(readFileSync(join(dir, 'map.md'), 'utf-8')).toBe('two\n');
  });

  it('readGraph returns null when no graph.json exists (first run)', async () => {
    expect(await readGraph(codemapDir(tempDir(), 'proj'))).toBeNull();
  });

  it('readGraph throws (fail loud) on corrupt JSON, not null', async () => {
    const dir = codemapDir(tempDir(), 'proj');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'graph.json'), 'not json {{{');
    await expect(readGraph(dir)).rejects.toThrow();
  });

  it('readGraph throws (fail loud) on an unrecognized schema', async () => {
    const dir = codemapDir(tempDir(), 'proj');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'graph.json'), JSON.stringify({ schema: 2 }));
    await expect(readGraph(dir)).rejects.toThrow(/schema/);
  });

  it('store path lands under the env-overridden BRAIN_DIR resolveBrainDir honors', async () => {
    const brain = tempDir();
    process.env.SB_BRAIN_DIR = brain;
    const dir = codemapDir(resolveBrainDir(), 'proj');
    await writeGraph(dir, GRAPH, 'm\n');
    expect(existsSync(join(brain, 'projects', 'proj', 'codemap', 'graph.json'))).toBe(true);
    expect(existsSync(join(brain, 'projects', 'proj', 'codemap', 'map.md'))).toBe(true);
  });
});
