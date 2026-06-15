import { promises as fs } from 'fs';
import { join } from 'path';
import { cleanEnvPath } from '../path-guard.js';

const MAX_LINES = 15;

export interface PinToUserArgs { text: string; brainDir?: string; }
export interface PinToUserResult { ok: boolean; line_added: string; reason?: string; }

export async function pinToUser(args: PinToUserArgs): Promise<PinToUserResult> {
  const dir = args.brainDir ?? join(cleanEnvPath(process.env.HOME), '.second-brain');
  const file = join(dir, 'USER.md');
  const date = new Date().toISOString().slice(0, 10);
  const trimmed = args.text.trim();
  const newLine = `- [${date}] ${trimmed}`;

  let content = '';
  try { content = await fs.readFile(file, 'utf-8'); }
  catch { content = '# USER preferences\n\n## Pinned\n'; }

  // Dedupe: if any existing pin line carries the same trimmed payload, no-op success.
  // Match form: "- [YYYY-MM-DD] <text>"; compare the <text> portion exactly (after trim).
  const existing = content.split('\n').find(l => {
    const m = l.match(/^- \[\d{4}-\d{2}-\d{2}\]\s+(.*)$/);
    return m !== null && m[1].trim() === trimmed;
  });
  if (existing !== undefined) {
    return { ok: true, line_added: existing, reason: 'already present' };
  }

  const projected = content + (content.endsWith('\n') ? '' : '\n') + newLine + '\n';
  if (projected.split('\n').filter(Boolean).length > MAX_LINES) {
    return { ok: false, line_added: '', reason: `would exceed ${MAX_LINES}-line cap` };
  }
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(file, projected, 'utf-8');
  return { ok: true, line_added: newLine };
}
