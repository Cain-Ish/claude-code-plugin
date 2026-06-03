import { resolve, relative, sep } from 'path';
import { glob } from 'glob';
import { filterIgnored, assertSafeSlug } from './doc-sources.js';
import { captureItem } from './raw-inbox.js';

const DOC_DIRS = new Set(['docs', 'doc', 'adr', 'adrs', 'rfc', 'rfcs', 'spec', 'specs', 'decisions', '.ai-docs', 'notes']);
const NAME_INCLUDE = /^(readme|architecture|design|contributing|roadmap)/i;  // basename (sans ext)
const LOW_SIGNAL = /^(changelog|license|licence|code_of_conduct)/i;          // basename (sans ext)
const TEMPLATE_RE = /template/i;                                              // basename
const SECRET_RE = /(^|\/)\.env|\.pem$|\.key$|id_rsa|secret|credential/i;      // full rel path

/** A repo-relative markdown path is high-signal iff it matches an include rule and no denylist. */
function isHighSignal(rel: string): boolean {
  const segs = rel.split('/');
  const file = segs[segs.length - 1];
  if (!/\.(md|markdown)$/i.test(file)) return false;
  const baseName = file.replace(/\.(md|markdown)$/i, '');
  const dirs = segs.slice(0, -1).map(s => s.toLowerCase());
  const include = segs.length === 1                       // rule 1: root-level *.md
    || dirs.some(d => DOC_DIRS.has(d))                    // rule 2: a directory segment is a doc dir
    || NAME_INCLUDE.test(baseName);                       // rule 3: high-signal basename anywhere
  if (!include) return false;
  if (LOW_SIGNAL.test(baseName) || TEMPLATE_RE.test(file)) return false;  // low-signal
  if (SECRET_RE.test(rel)) return false;                                  // secret defense-in-depth
  return true;
}

/** Max items captured per scan (SB_SCAN_MAX, default 50). */
export function scanCap(): number {
  const n = parseInt(process.env.SB_SCAN_MAX ?? '', 10);
  return Number.isFinite(n) && n >= 0 ? n : 50;
}

/** Walk the repo for high-signal markdown docs (junk + git-ignored dropped). Sorted, uncapped. */
export async function scanCandidates(projectRoot: string): Promise<string[]> {
  const root = resolve(projectRoot);
  const matches = await glob('**/*.{md,markdown}', { cwd: root, absolute: true, nodir: true }).catch(() => [] as string[]);
  const within = matches.filter(p => { const r = resolve(p); return r === root || r.startsWith(root + sep); });
  const highSignal = within.filter(p => isHighSignal(relative(root, p)));
  const kept = filterIgnored(root, highSignal);  // drops JUNK_DIRS + `git check-ignore` paths
  kept.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));  // byte-stable, locale-independent
  return kept;
}

export interface ScanResult { candidates: string[]; captured: number; skipped: number; truncated: number; }

/** Scan + (unless dryRun) capture each candidate into the raw inbox as `setup-scan` material. */
export async function runScan(projectRoot: string, brainDir: string, slug: string,
                              opts: { dryRun?: boolean }): Promise<ScanResult> {
  assertSafeSlug(slug);
  const all = await scanCandidates(projectRoot);
  const cap = scanCap();
  const candidates = all.slice(0, cap);
  const truncated = Math.max(0, all.length - cap);
  if (opts.dryRun) return { candidates, captured: 0, skipped: 0, truncated };
  let captured = 0, skipped = 0;
  for (const src of candidates) {
    try {
      const r = await captureItem({ brainDir, slug, kind: 'file', source: src, capturedBy: 'setup-scan' });
      if (r.duplicate) skipped++; else captured++;
    } catch { skipped++; }  // unreadable → skip, never abort the scan
  }
  return { candidates, captured, skipped, truncated };
}
