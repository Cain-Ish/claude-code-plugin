import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { episodicSearch, withActiveScope, scopeAndBroaden } from '../src/tools/episodic-search.js';

// SP-1 parity for the episodic tier: when an active project is set, prefer
// same-project exchanges and suppress other-project noise; broaden only when
// the active project has no in-scope hit (a thin/new project still gets recall).

function seedIndex(brainDir: string, exchanges: Array<{ id: string; project: string; user: string; assistant: string }>) {
  const index = {
    model: 'Xenova/all-MiniLM-L6-v2',
    indexed_files: { 'fixture.txt': 'h' },
    exchanges: exchanges.map((e, i) => ({
      id: e.id,
      sessionId: `s-${e.id}`,
      project: e.project,
      date: '2026-06-07',
      userSnippet: e.user,
      assistantSnippet: e.assistant,
      archivePath: join(brainDir, 'transcripts', 'fixture.txt'),
      lineStart: i * 2 + 1,
      lineEnd: i * 2 + 2,
      embedding: [] as number[],
    })),
  };
  writeFileSync(join(brainDir, 'episodic-index.json'), JSON.stringify(index), 'utf-8');
  writeFileSync(join(brainDir, 'transcripts', 'fixture.txt'), 'placeholder', 'utf-8');
}

describe('episodicSearch — active-project scoping (SP-1 parity)', () => {
  let brainDir: string;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'epi-scope-'));
    mkdirSync(join(brainDir, 'transcripts'), { recursive: true });
    process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
  });
  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    delete process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS;
  });

  it('suppresses other-project exchanges when activeProject has in-scope hits', async () => {
    seedIndex(brainDir, [
      { id: 'a1', project: 'alpha', user: 'wireguard tunnel keeps dropping', assistant: 'restart the wireguard tunnel interface' },
      { id: 'b1', project: 'beta', user: 'wireguard tunnel config for beta', assistant: 'the wireguard tunnel needs a new key' },
    ]);

    const res = await episodicSearch({ query: 'wireguard tunnel', mode: 'text', activeProject: 'alpha' }, brainDir);

    expect(res.results.length).toBeGreaterThan(0);
    expect(res.results.every(r => r.project === 'alpha')).toBe(true);
    expect(res.results.some(r => r.project === 'beta')).toBe(false);
  });

  it('broadens to other projects when the active project has no in-scope hit', async () => {
    seedIndex(brainDir, [
      { id: 'b1', project: 'beta', user: 'wireguard tunnel config for beta', assistant: 'the wireguard tunnel needs a new key' },
    ]);

    const res = await episodicSearch({ query: 'wireguard tunnel', mode: 'text', activeProject: 'alpha' }, brainDir);

    // active project (alpha) has zero matches → don't return empty, fall back to beta
    expect(res.results.length).toBeGreaterThan(0);
    expect(res.results.some(r => r.project === 'beta')).toBe(true);
  });

  it('returns all projects when no activeProject is given (default behavior unchanged)', async () => {
    seedIndex(brainDir, [
      { id: 'a1', project: 'alpha', user: 'wireguard tunnel keeps dropping', assistant: 'restart the wireguard tunnel interface' },
      { id: 'b1', project: 'beta', user: 'wireguard tunnel config for beta', assistant: 'the wireguard tunnel needs a new key' },
    ]);

    const res = await episodicSearch({ query: 'wireguard tunnel', mode: 'text' }, brainDir);

    expect(res.results.some(r => r.project === 'alpha')).toBe(true);
    expect(res.results.some(r => r.project === 'beta')).toBe(true);
  });

  it('honors an explicit project hard-filter over activeProject', async () => {
    seedIndex(brainDir, [
      { id: 'a1', project: 'alpha', user: 'wireguard tunnel keeps dropping', assistant: 'restart the wireguard tunnel interface' },
      { id: 'b1', project: 'beta', user: 'wireguard tunnel config for beta', assistant: 'the wireguard tunnel needs a new key' },
    ]);

    const res = await episodicSearch({ query: 'wireguard tunnel', mode: 'text', project: 'beta', activeProject: 'alpha' }, brainDir);

    expect(res.results.length).toBeGreaterThan(0);
    expect(res.results.every(r => r.project === 'beta')).toBe(true);
  });
});

describe('withActiveScope — MCP arg defaulting', () => {
  it('defaults activeProject to the active slug when no project is given', () => {
    expect(withActiveScope({ query: 'q' }, 'alpha')).toEqual({ query: 'q', activeProject: 'alpha' });
  });

  it('leaves an explicit project hard-filter untouched (no soft scope added)', () => {
    expect(withActiveScope({ query: 'q', project: 'beta' }, 'alpha')).toEqual({ query: 'q', project: 'beta' });
  });

  it('treats project:"all" as a deliberate broaden (drops the filter, no scope)', () => {
    expect(withActiveScope({ query: 'q', project: 'all' }, 'alpha')).toEqual({ query: 'q' });
  });

  it('is a no-op when there is no active slug', () => {
    expect(withActiveScope({ query: 'q' }, undefined)).toEqual({ query: 'q' });
  });

  it('project:"all" also strips a caller-supplied activeProject (truly broaden)', () => {
    // guards against soft scope leaking back in when a caller pre-set activeProject + project:"all"
    expect(withActiveScope({ query: 'q', project: 'all', activeProject: 'beta' }, 'alpha')).toEqual({ query: 'q' });
  });
});

describe('scopeAndBroaden — shared scoping for both query paths', () => {
  const A = { project: 'alpha', similarity: 0.4 };
  const A2 = { project: 'alpha', similarity: 0.2 };
  const B = { project: 'beta', similarity: 0.9 };

  it('keeps only in-scope when the active project meets the min-hits floor', () => {
    expect(scopeAndBroaden([B, A, A2], { query: 'q', activeProject: 'alpha' })).toEqual([A, A2]);
  });

  it('broadens to the full ranked set when the active project has zero in-scope hits', () => {
    expect(scopeAndBroaden([B], { query: 'q', activeProject: 'alpha' })).toEqual([B]);
  });

  it('is a passthrough when no activeProject is set', () => {
    expect(scopeAndBroaden([B, A], { query: 'q' })).toEqual([B, A]);
  });

  it('is a passthrough when a hard project filter is present (applyFilters already scoped)', () => {
    expect(scopeAndBroaden([B], { query: 'q', project: 'beta', activeProject: 'alpha' })).toEqual([B]);
  });
});
