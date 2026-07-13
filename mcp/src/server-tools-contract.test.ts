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
];

describe('server.ts tool-registration contract', () => {
  it('all 23 tools register through registerJsonTool', () => {
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
});
