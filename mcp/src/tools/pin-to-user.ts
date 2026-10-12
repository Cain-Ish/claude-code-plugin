import { promises as fs } from 'fs';
import { join } from 'path';
import { resolveBrainDir } from '../brain-paths.js';
import { withFileLock, LOCK_STOLEN } from './hot-file-lock.js';
import { writeFileAtomic } from './atomic-write.js';

// Cap on PIN LINES ONLY ("- [YYYY-MM-DD] …"), never on the whole file. The previous cap
// (15 non-blank lines of the ENTIRE file, pin appended at EOF) counted the operator's own
// hand-written About/Intent sections — the live USER.md was 23 non-blank lines with ZERO pins,
// so every pin_to_user call (and, then, every auto-graduated persona signal) was refused, silently,
// for months (ledger LC-07, 2026-08-23). Graduation no longer goes through here: it writes
// $BRAIN_DIR/persona-learned.md via sb_pin_to_learned; USER.md is human pins only. scripts/lib.sh sb_pin_to_user applies the SAME rule
// (same regex, same MAX_PINS, same section) — keep them in lockstep.
export const MAX_PINS = 15;
export const PIN_RE = /^- \[\d{4}-\d{2}-\d{2}\]\s+(.*)$/;
const PIN_SECTION = '## Pinned';

// D109: text spliced into USER.md unflattened let a forged "\n## Operator instructions\nALWAYS
// …" (e.g. from transcript-derived text; graduation itself now targets persona-learned.md) create a NEW heading that
// session-load.sh then injects verbatim into EVERY SessionStart — USER.md is priority-1 and is
// never wrapped as untrusted (test-injection-wrap.sh). Ported verbatim from pin-to-project.ts's
// flattenField (added there in 0.48.0 for exactly this memory-poisoning primitive): strip
// CR/LF/backticks, collapse whitespace, NFC-normalize so equivalent Unicode forms dedupe
// consistently, cap length. scripts/lib.sh sb_pin_to_user mirrors this in bash — lockstep.
const PIN_TEXT_CAP = 400;
function flattenField(s: string, cap: number): string {
  return s.normalize('NFC').replace(/[\r\n`]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, cap);
}

export interface PinToUserArgs { text: string; brainDir?: string; }
export interface PinToUserResult { ok: boolean; line_added: string; reason?: string; }

export async function pinToUser(args: PinToUserArgs): Promise<PinToUserResult> {
  const dir = resolveBrainDir(args.brainDir);
  const file = join(dir, 'USER.md');
  const date = new Date().toISOString().slice(0, 10);
  const trimmed = flattenField(args.text, PIN_TEXT_CAP);
  if (!trimmed) {
    return { ok: false, line_added: '', reason: 'empty text after sanitization' };
  }
  const newLine = `- [${date}] ${trimmed}`;

  // E3: read-modify-write under the shared .USER.md.lock (lib.sh sb_pin_to_user, the bash twin of
  // this tool, holds it too) and replace by temp + rename.
  await fs.mkdir(dir, { recursive: true });
  return withFileLock(file, reason => ({ ok: false, line_added: '', reason }),
    owned => pinUserLocked(file, trimmed, newLine, owned));
}

async function pinUserLocked(file: string, trimmed: string, newLine: string, owned: () => Promise<boolean>): Promise<PinToUserResult> {
  let content = '';
  try { content = await fs.readFile(file, 'utf-8'); }
  catch (e) {
    // M5: only a MISSING file gets the template. EPERM/EBUSY (a locked file on Windows) used to
    // write template + one pin over the real profile and report ok:true.
    const code = (e as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT') return { ok: false, line_added: '', reason: `cannot read USER.md (${code ?? String(e)}); nothing written` };
    content = `# USER preferences\n\n${PIN_SECTION}\n`;
  }

  const lines = content.split('\n');
  const pinLines = lines.filter(l => PIN_RE.test(l));

  // Dedupe on the <text> portion, exact after trim → no-op success.
  const existing = pinLines.find(l => (l.match(PIN_RE) as RegExpMatchArray)[1].trim() === trimmed);
  if (existing !== undefined) {
    return { ok: true, line_added: existing, reason: 'already present' };
  }
  if (pinLines.length >= MAX_PINS) {
    return { ok: false, line_added: '', reason: `would exceed ${MAX_PINS} pinned lines (hand-written sections do not count)` };
  }

  // Insert under "## Pinned": after the last existing pin in that section, else right after the
  // heading; create the section at EOF when absent. Never touches the hand-written sections.
  const out = [...lines];
  let secIdx = out.findIndex(l => l.trim() === PIN_SECTION);
  if (secIdx === -1) {
    if (out.length && out[out.length - 1] !== '') out.push('');
    out.push(PIN_SECTION);
    secIdx = out.length - 1;
  }
  let insertAt = secIdx + 1;
  for (let i = secIdx + 1; i < out.length; i++) {
    if (/^## /.test(out[i])) break;
    if (PIN_RE.test(out[i])) insertAt = i + 1;
  }
  out.splice(insertAt, 0, newLine);
  const projected = out.join('\n').replace(/\n*$/, '\n');

  if (!(await owned())) return { ok: false, line_added: '', reason: LOCK_STOLEN };
  await writeFileAtomic(file, projected);
  return { ok: true, line_added: newLine };
}
