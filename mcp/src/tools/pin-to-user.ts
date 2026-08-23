import { promises as fs } from 'fs';
import { join } from 'path';
import { resolveBrainDir } from '../brain-paths.js';

// Cap on PIN LINES ONLY ("- [YYYY-MM-DD] …"), never on the whole file. The previous cap
// (15 non-blank lines of the ENTIRE file, pin appended at EOF) counted the operator's own
// hand-written About/Intent sections — the live USER.md was 23 non-blank lines with ZERO pins,
// so every pin_to_user call and every auto-graduated persona signal was refused, silently, for
// months (ledger LC-07, 2026-08-23). scripts/lib.sh sb_pin_to_user applies the SAME rule
// (same regex, same MAX_PINS, same section) — keep them in lockstep.
export const MAX_PINS = 15;
export const PIN_RE = /^- \[\d{4}-\d{2}-\d{2}\]\s+(.*)$/;
const PIN_SECTION = '## Pinned';

export interface PinToUserArgs { text: string; brainDir?: string; }
export interface PinToUserResult { ok: boolean; line_added: string; reason?: string; }

export async function pinToUser(args: PinToUserArgs): Promise<PinToUserResult> {
  const dir = resolveBrainDir(args.brainDir);
  const file = join(dir, 'USER.md');
  const date = new Date().toISOString().slice(0, 10);
  const trimmed = args.text.trim();
  const newLine = `- [${date}] ${trimmed}`;

  let content = '';
  try { content = await fs.readFile(file, 'utf-8'); }
  catch { content = `# USER preferences\n\n${PIN_SECTION}\n`; }

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

  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(file, projected, 'utf-8');
  return { ok: true, line_added: newLine };
}
