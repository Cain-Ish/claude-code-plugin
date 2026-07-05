import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { promises as fs, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { guardDestructive } from './nested-spawn-guard.js';
import { knowledgeValidate } from './tools/knowledge-validate.js';

// Return type carries the optional isError so guardDestructive's R extends ToolResult
// and res.isError is accessible on the R | ToolResult union under --strict.
const ok = (text: string): { content: Array<{ type: 'text'; text: string }>; isError?: boolean } =>
  ({ content: [{ type: 'text' as const, text }] });
const exists = (p: string) => fs.access(p).then(() => true, () => false);

// Save/restore so cases don't leak the marker into one another.
let saved: string | undefined;
beforeEach(() => { saved = process.env.SB_NESTED_SPAWN; });
afterEach(() => {
  if (saved === undefined) delete process.env.SB_NESTED_SPAWN;
  else process.env.SB_NESTED_SPAWN = saved;
});

describe('nested-spawn-guard — Part A: guardDestructive unit', () => {
  it('refuses under SB_NESTED_SPAWN=1 and NEVER calls the real handler', async () => {
    process.env.SB_NESTED_SPAWN = '1';
    const spy = vi.fn(async () => ok('ran'));
    const res = await guardDestructive('t', spy)();
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toMatch(/nested/i);
    expect(spy.mock.calls.length).toBe(0);   // ORACLE: the real handler did not run
  });

  it('passes the real result through verbatim when the marker is unset', async () => {
    delete process.env.SB_NESTED_SPAWN;
    const out = ok('real');
    const spy = vi.fn(async () => out);
    const res = await guardDestructive('t', spy)();
    expect(spy.mock.calls.length).toBe(1);
    expect(res).toEqual(out);
  });

  it('treats any non-"1" value as the live session (exact match, not truthiness)', async () => {
    const spy = vi.fn(async () => ok('ran'));
    const wrapped = guardDestructive('t', spy);
    for (const v of ['0', '', 'yes']) {
      spy.mockClear();
      process.env.SB_NESTED_SPAWN = v;
      await wrapped();
      expect(spy.mock.calls.length, `value=${JSON.stringify(v)} must run live`).toBe(1);
    }
  });
});

describe('nested-spawn-guard — Part B: filesystem round-trip (load-bearing oracle)', () => {
  async function tmpWikiWithEmptyPage() {
    const dir = await fs.mkdtemp(join(tmpdir(), 'nsg-'));
    const wiki = join(dir, 'wiki', 'state');
    await fs.mkdir(wiki, { recursive: true });
    const empty = join(wiki, 'empty.md');
    await fs.writeFile(empty, '   \n');
    return { dir, empty };
  }
  const wrappedValidate = (dir: string) =>
    guardDestructive('knowledge_validate', async () => ok(JSON.stringify(await knowledgeValidate(dir, { autofix: true }))));

  it('blocks the destructive autofix under the marker — the empty page survives on disk', async () => {
    const { dir, empty } = await tmpWikiWithEmptyPage();
    process.env.SB_NESTED_SPAWN = '1';
    const res = await wrappedValidate(dir)();
    expect(res.isError).toBe(true);
    expect(await exists(empty)).toBe(true);   // ORACLE: deletion never happened
  });

  it('allows the same autofix when the marker is unset — the empty page is deleted', async () => {
    const { dir, empty } = await tmpWikiWithEmptyPage();
    delete process.env.SB_NESTED_SPAWN;
    await wrappedValidate(dir)();
    expect(await exists(empty)).toBe(false);  // ORACLE: deletion happened (guard was transparent)
  });
});

describe('nested-spawn-guard — Part C: exactly the destructive tools are wrapped', () => {
  const src = readFileSync(new URL('./server.ts', import.meta.url), 'utf-8');
  const DESTRUCTIVE = ['pin_to_user', 'pin_to_project', 'archive_to_wiki', 'knowledge_reindex',
    'knowledge_validate', 'dream_create', 'dream_accept', 'dream_discard', 'dream_cancel',
    'persona_dismiss', 'knowledge_relate'];
  const READONLY = ['knowledge_search', 'knowledge_fetch', 'knowledge_stats', 'dream_status',
    'dream_list', 'episodic_search', 'episodic_read', 'persona_think', 'persona_stats',
    'knowledge_neighbors', 'code_map', 'code_neighbors'];

  it('all 11 destructive tools ARE wrapped with guardDestructive', () => {
    for (const t of DESTRUCTIVE) {
      expect(src.includes(`guardDestructive("${t}"`), `${t} must be guarded`).toBe(true);
    }
  });

  it('no read-only tool is wrapped (no over-blocking)', () => {
    for (const t of READONLY) {
      expect(src.includes(`guardDestructive("${t}"`), `${t} must NOT be guarded`).toBe(false);
    }
  });
});
