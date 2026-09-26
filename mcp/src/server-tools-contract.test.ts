import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';

// Source-scan lock on server.ts's tool-registration contract (0.33.38 audit):
// ONE registration path (registerJsonTool owns try/catch + the single
// `<tool> error:` grammar + serialization), and an HONEST knowledge_search
// description (the access-frequency boost was cut in 0.33.30 — the description
// advertised it for four more releases). server.ts cannot be imported in a test
// (module load connects the stdio transport), so the lock is on the source.
const src = readFileSync(new URL('./server.ts', import.meta.url), 'utf-8');

const ALL_TOOLS = [
  'knowledge_search', 'knowledge_fetch', 'pin_to_user', 'pin_to_project', 'archive_to_wiki',
  'knowledge_stats', 'knowledge_reindex', 'knowledge_validate',
  'dream_create', 'dream_status', 'dream_list', 'dream_accept', 'dream_discard', 'dream_cancel',
  'episodic_search', 'episodic_read',
  'persona_think', 'persona_stats', 'persona_dismiss',
  'knowledge_relate', 'knowledge_neighbors',
  'code_map', 'code_neighbors',
  'buddy_react',
];

describe('server.ts tool-registration contract', () => {
  it('all 24 tools register through registerJsonTool', () => {
    for (const t of ALL_TOOLS) {
      expect(new RegExp(`registerJsonTool\\(\\s*"${t}"`).test(src), `${t} must register via registerJsonTool`).toBe(true);
    }
  });

  it('server.registerTool is called ONLY inside the helper (no bespoke registrations)', () => {
    expect((src.match(/server\.registerTool\(/g) ?? []).length).toBe(1);
  });

  it('knowledge_search description no longer advertises the access-frequency boost removed in 0.33.30', () => {
    expect(src).not.toMatch(/access-frequency/);
  });

  // D031: knowledge_reindex unconditionally runs knowledge_validate with autofix:true
  // (knowledge-reindex.ts calls `knowledgeValidate(knowledgeDir, { autofix: true, ... })`), which
  // deletes empty pages and rewrites frontmatter — exactly the destructive default
  // knowledge_validate's OWN description says it flips to report-only "so a casual/unattended
  // MODEL call must not silently delete empty pages". The reindex description must disclose this
  // instead of implying a harmless catalog rebuild.
  it('knowledge_reindex description discloses that it runs validate with autofix (deletes empty pages)', () => {
    const m = src.match(/registerJsonTool\(\s*"knowledge_reindex",\s*"([^"]*(?:\\.[^"]*)*)"/);
    expect(m, 'knowledge_reindex registration not found').not.toBeNull();
    const description = m![1];
    expect(description).toMatch(/autofix/i);
    expect(description).toMatch(/delete/i);
  });

  // contract acceptance[6] (repo-brain S2, previously missing): the pin_to_project z.enum must
  // carry "conventions" — a schema/enum lock (kb-schema.test.ts only mirrors kb-schema.json's
  // OWN project_sections array; nothing previously locked server.ts's registration to it).
  it('pin_to_project registration z.enum includes "conventions"', () => {
    const m = src.match(/registerJsonTool\(\s*"pin_to_project"[\s\S]*?z\.enum\(\[([^\]]*)\]/);
    expect(m, 'pin_to_project section z.enum not found').not.toBeNull();
    const values = m![1].match(/"([a-z]+)"/g)?.map(s => s.replace(/"/g, '')) ?? [];
    expect(values).toContain('conventions');
  });

  // repo-brain Slice 2 review fix (MEDIUM): pin_to_project must gate its post-pin
  // rebuildJitIndex call through shouldRebuildAfterPin (active-slug check) — a bare
  // `rebuildJitIndex(...)` call with no gate would silently reintroduce the cross-project
  // index clobber (a pin to a non-active slug rebuilding against the active repo's files).
  it('pin_to_project gates its post-pin rebuildJitIndex call through shouldRebuildAfterPin', () => {
    expect(src).toMatch(/shouldRebuildAfterPin\(/);
    const idx = src.search(/registerJsonTool\(\s*"pin_to_project"/);
    expect(idx, 'pin_to_project registration not found').toBeGreaterThan(-1);
    const block = src.slice(idx, idx + 2500);
    expect(block).toMatch(/if\s*\(\s*shouldRebuildAfterPin\(/);
    expect(block).not.toMatch(/if\s*\(\s*result\.ok\s*\)\s*\{\s*void rebuildJitIndex/);
  });
});
