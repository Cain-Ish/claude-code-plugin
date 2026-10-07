import { describe, it, expect, vi, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

// The two CLIs whose stdout the hooks inject (knowledge-search-cli -> session-load.sh's SessionStart
// enrichment, context-serve-cli -> persona-context.sh's per-prompt context), run in process: the
// engines are mocked, the rest (gate, renderer, logs) is real. A CLI is a script with top-level
// await that ends in process.exit, so process.exit is stubbed to throw ExitSignal and each run
// imports a fresh copy of the module.
class ExitSignal extends Error {
  constructor(public code: number) { super(`exit ${code}`); }
}

type Cand = { path: string; description: string; source: string };
const cand = (c: Cand) => ({ score: 1, score_norm: 1, relevance: 50, grounded: 5, query_terms: 5, discriminative_terms: 5, tokens: 10, ...c });
const wiki = (s: string) => cand({ path: `/k/wiki/concepts/${s}.md`, description: `about ${s}`, source: 'wiki' });

interface Mocks { search: () => Promise<unknown>; serve?: () => Promise<string[]> }

async function runCli(cli: 'context-serve-cli' | 'knowledge-search-cli', m: Mocks): Promise<{ out: string[]; brainDir: string }> {
  const brainDir = mkdtempSync(join(tmpdir(), 'inject-cli-'));
  for (const k of ['SB_BRAIN_DIR', 'SB_INJECT_GATE', 'SB_INJECT_MIN_GROUNDED', 'SB_INJECT_MIN_RELEVANCE', 'KNOWLEDGE_MIN_SCORE']) delete process.env[k];
  process.env.BRAIN_DIR = brainDir;
  process.env.KNOWLEDGE_DIR = join(brainDir, 'kd');
  vi.resetModules();
  vi.doMock('./knowledge-search.js', async (orig) => ({ ...(await orig<typeof import('./knowledge-search.js')>()), knowledgeSearch: m.search }));
  vi.doMock('./episodic-search.js', async (orig) => ({ ...(await orig<typeof import('./episodic-search.js')>()),
    serveEpisodicLines: m.serve ?? (async () => []) }));
  const argv = process.argv;
  process.argv = [argv[0], cli, 'wombat runbook'];
  const out: string[] = [];
  const log = vi.spyOn(console, 'log').mockImplementation((s: unknown) => { out.push(String(s)); });
  const exit = vi.spyOn(process, 'exit').mockImplementation(((code?: number) => { throw new ExitSignal(code ?? 0); }) as never);
  const err = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
  try {
    await import(`./${cli}.js`);
  } catch (e) {
    if (!(e instanceof ExitSignal)) throw e;
    expect(e.code).toBe(0);
  } finally {
    process.argv = argv;
    log.mockRestore(); exit.mockRestore(); err.mockRestore();
    vi.doUnmock('./knowledge-search.js'); vi.doUnmock('./episodic-search.js');
  }
  return { out, brainDir };
}

const rows = (brainDir: string, file: string) => existsSync(join(brainDir, file))
  ? readFileSync(join(brainDir, file), 'utf-8').trim().split('\n').map(l => JSON.parse(l)) : [];

afterEach(() => { vi.resetModules(); });

describe('T2/S4: an unprintable candidate does not cost an injected slot, and each drop leaves a row', () => {
  const ranked = () => Promise.resolve({ candidates: [
    cand({ path: 'docs/rel.md', description: 'x', source: 'local-doc' }),
    wiki('alpha'), wiki('beta'), wiki('gamma'),
  ] });
  for (const cli of ['context-serve-cli', 'knowledge-search-cli'] as const) {
    it(`${cli}: the two printed lines are the first two printable candidates`, async () => {
      const { out, brainDir } = await runCli(cli, { search: ranked, serve: async () => ['[Past sessions]', '- "x"'] });
      expect(out.filter(l => l.startsWith('###') || l.startsWith('Read '))).toEqual(['### [[alpha]] — about alpha', '### [[beta]] — about beta']);
      const drops = rows(brainDir, 'audit-log.jsonl').filter(r => /^gate=inject-drop /.test(r.message));
      expect(drops.map(r => r.message)).toEqual(['gate=inject-drop reason=path-relative source=local-doc path="docs/rel.md"']);
      expect(drops[0].script).toBe(cli);
    });
  }
});

describe('S14: context-serve-cli logs a failed section instead of swallowing it', () => {
  it('a throwing wiki search and a throwing episodic serve each leave one error-log row; stdout stays empty', async () => {
    const { out, brainDir } = await runCli('context-serve-cli', {
      search: async () => { throw new Error('wiki engine exploded'); },
      serve: async () => { throw new Error('episodic engine exploded'); },
    });
    expect(out).toEqual([]);
    const errs = rows(brainDir, 'error-log.jsonl').filter(r => r.script === 'context-serve-cli');
    expect(errs.map(r => r.message)).toEqual([
      'wiki section failed open (empty): wiki engine exploded',
      'episodic section failed open (empty): episodic engine exploded',
    ]);
    expect(errs.every(r => r.exit_code === 1)).toBe(true);
  });

  it('one failing section still lets the other print', async () => {
    const { out, brainDir } = await runCli('context-serve-cli', {
      search: async () => { throw new Error('wiki engine exploded'); },
      serve: async () => ['[Past sessions]', '- "wombat"'],
    });
    expect(out).toEqual(['--8<--SB-EPISODIC--8<--', '[Past sessions]', '- "wombat"']);
    expect(rows(brainDir, 'error-log.jsonl').filter(r => r.script === 'context-serve-cli')).toHaveLength(1);
  });
});
