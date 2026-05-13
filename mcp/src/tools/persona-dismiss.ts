import { promises as fs } from 'fs';
import { join } from 'path';

export interface PersonaDismissArgs {
  prompt_snippet?: string;
  reason?: string;
  brainDir?: string;
}

export interface PersonaDismissResult {
  ok: boolean;
  count_7d: number;
}

const RETAIN_DAYS = 30;

export async function personaDismiss(args: PersonaDismissArgs = {}): Promise<PersonaDismissResult> {
  const dir = args.brainDir ?? join(process.env.HOME ?? process.env.USERPROFILE ?? '', '.second-brain');
  await fs.mkdir(dir, { recursive: true }).catch(() => {});
  const file = join(dir, '.persona-dismissals.jsonl');

  const now = new Date();
  const entry = {
    at: now.toISOString(),
    prompt_snippet: (args.prompt_snippet ?? '').slice(0, 200),
    reason: args.reason ?? '',
  };

  // Prune entries older than RETAIN_DAYS before appending.
  const cutoff = now.getTime() - RETAIN_DAYS * 86400000;
  let kept = '';
  try {
    const existing = await fs.readFile(file, 'utf-8');
    for (const line of existing.split('\n')) {
      if (!line.trim()) continue;
      try {
        const j = JSON.parse(line);
        const t = new Date(j.at).getTime();
        if (!Number.isNaN(t) && t > cutoff) kept += line + '\n';
      } catch {}
    }
  } catch {}
  kept += JSON.stringify(entry) + '\n';
  await fs.writeFile(file, kept);

  // Count last 7d
  const week = now.getTime() - 7 * 86400000;
  let count = 0;
  for (const line of kept.split('\n')) {
    if (!line.trim()) continue;
    try {
      const j = JSON.parse(line);
      const t = new Date(j.at).getTime();
      if (!Number.isNaN(t) && t > week) count++;
    } catch {}
  }
  return { ok: true, count_7d: count };
}
