/**
 * buddy-events — the TS twin of lib.sh `sb_buddy_event`. Same file format, same rules:
 * one atomic current-state file per key under $BRAIN_DIR/.buddy/, an append-only log beside it.
 * The MCP server does not know the Claude Code session id, so its events (memory READ and WRITE
 * through the tools) go to the shared key `_global`; the statusline renderer merges the session
 * file and `_global` by freshness. Fail-soft: never throws, never blocks a tool result — it
 * reports what happened instead, so buddy_react (whose whole job is this write) can say so.
 * Design: docs/plans/2026-09-22-buddy-companion.md §2.
 */
import { promises as fs } from 'fs';
import { join } from 'path';

export type BuddyKind = 'delivered' | 'retrieved' | 'read' | 'remembered' | 'gate' | 'guard' | 'pending' | 'phase' | 'stumble' | 'said';
export type BuddyMood = 'focused' | 'alert' | 'pleased' | 'waiting' | 'puzzled';
export interface BuddyEvent { ts: number; kind: BuddyKind; mood: BuddyMood; line: string; source: string; ttl_s: number }
/** shown = current-state file written; held = only logged (an active gate or Claude's own line is
 *  showing); skipped = buddy off or nothing to write; failed = the write threw (error says why). */
export interface BuddyWrite { status: 'shown' | 'held' | 'skipped' | 'failed'; error?: string }

const LOG_KEEP = 40;
let seq = 0;   // concurrent tool calls in one server process must not share a tmp name
// C0/C1 controls and format chars (\p{Cf}: bidi overrides, zero-width, tag characters — invisible to
// the user, read back by the model through persona-context) become spaces.
const clean = (s: string) => Array.from(s.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]|\p{Cf}/gu, ' ')).slice(0, 200).join('');

export async function writeBuddyEvent(
  brainDir: string, key: string, kind: BuddyKind, mood: BuddyMood, line: string, source: string, ttl_s = 900,
): Promise<BuddyWrite> {
  if (process.env.SB_BUDDY === 'off' || process.env.SB_HOOK_PROFILE === 'minimal') return { status: 'skipped' };
  const k = key.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
  if (!k || !line) return { status: 'skipped' };
  try {
    const dir = join(brainDir, '.buddy');
    await fs.mkdir(dir, { recursive: true });
    const cur = join(dir, `${k}.json`);
    const now = Math.floor(Date.now() / 1000);
    // An ACTIVE gate (alert/puzzled — the user must act) holds the current-state bubble for 60 s
    // against every other kind; a clearing gate (pleased) does not. Claude's own line (said) holds
    // the same way against everything but a gate, a guard, an alert/puzzled mood or a newer said —
    // "which gate is holding you" must never hide behind a chat line. The log always gets the row.
    // Twin: lib.sh sb_buddy_event.
    let hold = false;
    if (kind !== 'gate') {
      try {
        const prev = JSON.parse(await fs.readFile(cur, 'utf-8')) as Partial<BuddyEvent>;
        const urgent = kind === 'said' || kind === 'guard' || mood === 'alert' || mood === 'puzzled';
        const holding = (prev.kind === 'gate' && prev.mood !== 'pleased') || (prev.kind === 'said' && !urgent);
        hold = holding && typeof prev.ts === 'number' && now - prev.ts < 60;
      } catch { /* no current state */ }
    }
    const row: BuddyEvent = { ts: now, kind, mood, line: clean(line), source, ttl_s };
    const text = JSON.stringify(row);
    const log = join(dir, `${k}.log.jsonl`);
    await fs.appendFile(log, text + '\n', 'utf-8');
    if (!hold) {
      const tmp = `${cur}.tmp.${process.pid}.${++seq}`;
      await fs.writeFile(tmp, text + '\n', 'utf-8');
      await fs.rename(tmp, cur);
    }
    try {
      const lines = (await fs.readFile(log, 'utf-8')).split('\n').filter(Boolean);
      if (lines.length > LOG_KEEP * 2) await fs.writeFile(log, lines.slice(-LOG_KEEP).join('\n') + '\n', 'utf-8');
    } catch { /* bounded best-effort */ }
    return { status: hold ? 'held' : 'shown' };
  } catch (e) {
    return { status: 'failed', error: (e as NodeJS.ErrnoException).code ?? String(e) };   // fail-soft by contract
  }
}

/**
 * The `buddy_react` MCP tool — Claude's half of the two-way buddy. persona-context.sh hands Claude
 * its session id in the per-prompt [buddy] line; the line lands in THAT session's bubble. No
 * session (or anything not id-shaped) → refused, never `_global`: a line every open session shows
 * — and persona-context would read back — is not this session's to write. Kind `said`, 15 min TTL.
 */
export async function buddyReact(
  brainDir: string, a: { line: string; mood?: BuddyMood; session?: string },
): Promise<string> {
  const line = a.line.trim();
  if (!clean(line).trim()) throw new Error('line is empty (or only control/format characters)');
  if (process.env.SB_BUDDY === 'off' || process.env.SB_HOOK_PROFILE === 'minimal') return 'buddy is off (SB_BUDDY=off) — nothing shown';
  if (!a.session || !/^[A-Za-z0-9_-]{8,64}$/.test(a.session)) {
    throw new Error('not shown: pass session — the id quoted in the [buddy: …] context line');
  }
  const w = await writeBuddyEvent(brainDir, a.session, 'said', a.mood ?? 'focused', Array.from(line).slice(0, 120).join(''), 'claude', 900);
  if (w.status === 'failed') throw new Error(`not shown: the buddy line could not be written (${w.error})`);
  if (w.status === 'held') return 'held: an active gate is showing in the bubble — your line was logged, not shown';
  return 'ok';
}
