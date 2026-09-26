import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { buddyReact, writeBuddyEvent } from './buddy-events.js';

// buddy_react is Claude's half of the two-way buddy: the line lands in the session's bubble (the
// per-prompt [buddy] context hands Claude its session id) — and nowhere without one.
describe('buddyReact (the buddy_react MCP tool)', () => {
  let brain: string;
  const SID = '05b60468-e417-4256-8f6a-dbad65981bcd';
  const clearEnv = () => { delete process.env.SB_BUDDY; delete process.env.SB_HOOK_PROFILE; };
  beforeEach(() => { brain = mkdtempSync(join(tmpdir(), 'sb-buddy-react-')); clearEnv(); });
  afterEach(() => { rmSync(brain, { recursive: true, force: true }); clearEnv(); });
  const cur = (k: string) => JSON.parse(readFileSync(join(brain, '.buddy', `${k}.json`), 'utf-8'));

  it('writes a `said` line to the named session, default mood focused', async () => {
    expect(await buddyReact(brain, { line: 'Tests green, pinned the decision', session: SID })).toBe('ok');
    expect(cur(SID)).toMatchObject({ kind: 'said', mood: 'focused', line: 'Tests green, pinned the decision', source: 'claude' });
    expect(existsSync(join(brain, '.buddy', '_global.json'))).toBe(false);
  });

  it('without a valid session id nothing is written — never _global (every session would show it)', async () => {
    expect(await buddyReact(brain, { line: 'no session given', mood: 'pleased' })).toMatch(/not shown/);
    expect(await buddyReact(brain, { line: 'path-shaped id', session: '../../etc/x' })).toMatch(/not shown/);
    expect(existsSync(join(brain, '.buddy'))).toBe(false);
  });

  it('caps at 120 chars; strips control, bidi, zero-width and tag characters; rejects an empty line', async () => {
    const esc = String.fromCodePoint(0x1b), rlo = String.fromCodePoint(0x202e), zw = String.fromCodePoint(0x200b), tag = String.fromCodePoint(0xe0041);
    await buddyReact(brain, { line: `a${esc}[31m${rlo}b${zw}c${tag}d${'x'.repeat(300)}`, session: SID });
    const line: string = cur(SID).line;
    expect(Array.from(line).length).toBeLessThanOrEqual(120);
    expect(line.startsWith('a [31m b c d')).toBe(true);
    await expect(buddyReact(brain, { line: '   ', session: SID })).rejects.toThrow(/empty/);
  });

  it('SB_BUDDY=off and SB_HOOK_PROFILE=minimal write nothing and say so', async () => {
    process.env.SB_BUDDY = 'off';
    expect(await buddyReact(brain, { line: 'muted', session: SID })).toMatch(/off/);
    clearEnv(); process.env.SB_HOOK_PROFILE = 'minimal';
    expect(await buddyReact(brain, { line: 'minimal', session: SID })).toMatch(/off/);
    expect(existsSync(join(brain, '.buddy'))).toBe(false);
  });

  it('a fresh `said` holds the bubble 60 s against other kinds (Stop hooks fire right after it), not against a gate', async () => {
    const dir = join(brain, '.buddy'); mkdirSync(dir, { recursive: true });
    const now = Math.floor(Date.now() / 1000);
    writeFileSync(join(dir, `${SID}.json`), JSON.stringify({ ts: now - 5, kind: 'said', mood: 'pleased', line: 'mine', source: 'claude', ttl_s: 900 }));
    await writeBuddyEvent(brain, SID, 'remembered', 'pleased', 'Filed to memory: x', 'stop-extract');
    expect(cur(SID).line).toBe('mine');
    expect(readFileSync(join(dir, `${SID}.log.jsonl`), 'utf-8')).toContain('Filed to memory: x');   // the log keeps it
    await writeBuddyEvent(brain, SID, 'gate', 'alert', 'Verify gate', 'stop-verify-gate');
    expect(cur(SID).kind).toBe('gate');
    writeFileSync(join(dir, `${SID}.json`), JSON.stringify({ ts: now - 61, kind: 'said', mood: 'pleased', line: 'old', source: 'claude', ttl_s: 900 }));
    await writeBuddyEvent(brain, SID, 'read', 'focused', 'Read x', 'mcp');
    expect(cur(SID).kind).toBe('read');                            // expired hold hands over
  });
});
