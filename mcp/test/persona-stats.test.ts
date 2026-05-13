import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { personaStats } from '../src/tools/persona-stats.js';

describe('persona_stats', () => {
  let brainDir: string;
  beforeEach(() => { brainDir = mkdtempSync(join(tmpdir(), 'ps-stats-')); });
  afterEach(() => { rmSync(brainDir, { recursive: true, force: true }); });

  it('returns zeroes when no persona files exist', async () => {
    const r = await personaStats({ brainDir });
    expect(r.persona_card_bytes).toBe(0);
    expect(r.ungraduated_signals).toBe(0);
    expect(r.installed_plugins).toBe(0);
    expect(r.dismissals_7d).toBe(0);
  });

  it('parses persona-card.md identity bullets', async () => {
    writeFileSync(join(brainDir, 'persona-card.md'),
      '# Persona\n## Identity\n- senior engineer\n- builds developer tools\n', 'utf-8');
    const r = await personaStats({ brainDir });
    expect(r.identity_summary).toContain('senior engineer');
    expect(r.persona_card_bytes).toBeGreaterThan(0);
  });

  it('counts graduated and ungraduated signals from persona-signals.jsonl', async () => {
    writeFileSync(join(brainDir, 'persona-signals.jsonl'),
      JSON.stringify({ category: 'a', count: 3, graduated: true }) + '\n' +
      JSON.stringify({ category: 'b', count: 2, graduated: false }) + '\n' +
      JSON.stringify({ category: 'c', count: 1, graduated: false }) + '\n', 'utf-8');
    const r = await personaStats({ brainDir });
    expect(r.graduated_signals).toBe(1);
    expect(r.ungraduated_signals).toBe(1); // count 1 is below threshold of 2
  });

  it('reads installed catalog counts', async () => {
    writeFileSync(join(brainDir, '.installed-catalog.json'),
      JSON.stringify({ plugins: [{ name: 'a' }, { name: 'b' }], agents: [{ name: 'x' }], skills: [] }), 'utf-8');
    const r = await personaStats({ brainDir });
    expect(r.installed_plugins).toBe(2);
    expect(r.installed_agents).toBe(1);
    expect(r.installed_skills).toBe(0);
  });

  it('counts dismissals within the last 7d', async () => {
    const recent = new Date(Date.now() - 2 * 86400000).toISOString();
    const old = new Date(Date.now() - 30 * 86400000).toISOString();
    writeFileSync(join(brainDir, '.persona-dismissals.jsonl'),
      JSON.stringify({ at: recent }) + '\n' +
      JSON.stringify({ at: recent }) + '\n' +
      JSON.stringify({ at: old }) + '\n', 'utf-8');
    const r = await personaStats({ brainDir });
    expect(r.dismissals_7d).toBe(2);
  });

  it('reports today_spend_usd from persona-budget.json', async () => {
    writeFileSync(join(brainDir, 'persona-budget.json'),
      JSON.stringify({ date: new Date().toISOString().slice(0, 10), today_usd: 1.23 }), 'utf-8');
    const r = await personaStats({ brainDir });
    expect(r.today_spend_usd).toBeCloseTo(1.23);
  });
});
