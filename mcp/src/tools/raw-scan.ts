import { resolve, relative, sep } from 'path';
import { glob } from 'glob';
import { filterIgnored, assertSafeSlug } from './doc-sources.js';
import { captureItem } from './raw-inbox.js';

const DOC_DIRS = new Set(['docs', 'doc', 'adr', 'adrs', 'rfc', 'rfcs', 'spec', 'specs', 'decisions', '.ai-docs', 'notes']);
const NAME_INCLUDE = /^(readme|architecture|design|contributing|roadmap)/i;  // basename (sans ext)
const LOW_SIGNAL = /^(changelog|license|licence|code_of_conduct)/i;          // basename (sans ext)
const TEMPLATE_RE = /template/i;                                              // basename
// `.pem`/`.key` match as an EXTENSION COMPONENT (a dot-token followed by another extension or
// end-of-path), not $-anchored on the full path — every candidate already ends in `.md`, so the
// old `\.pem$`/`\.key$` branches were structurally unreachable and `server.key.md` leaked through.
// `(\.|$)` after the token keeps `monkey.md`/`api-keys.md` (no `.key` extension) from over-matching.
const SECRET_RE = /(^|\/)\.env|\.(pem|key)(\.|$)|id_rsa|secret|credential/i;  // full rel path

/** A repo-relative markdown path is high-signal iff it matches an include rule and no denylist.
 *  Normalizes separators first: `path.relative` emits OS-native separators, so a Windows path
 *  `docs\adr\x.md` must be split on `\` too or rule 2 / the secret anchor silently misfire. */
export function isHighSignal(relRaw: string): boolean {
  const rel = relRaw.replace(/\\/g, '/');
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
  // follow:false → never traverse symlinked directories (a symlink loop would otherwise hang the scan).
  const matches = await glob('**/*.{md,markdown}', { cwd: root, absolute: true, nodir: true, follow: false }).catch(() => [] as string[]);
  const within = matches.filter(p => { const r = resolve(p); return r === root || r.startsWith(root + sep); });
  const highSignal = within.filter(p => isHighSignal(relative(root, p)));
  const kept = filterIgnored(root, highSignal);  // drops JUNK_DIRS + `git check-ignore` paths
  kept.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));  // byte-stable, locale-independent
  return kept;
}

export interface ScanResult {
  candidates: string[];   // the (capped) set that will be / was captured
  overflow: string[];     // candidates beyond the cap (shown in the dry-run preview so nothing is hidden)
  captured: number;
  skipped: number;        // already-in-inbox (dedup) OR unreadable at capture time
  errored: number;        // subset of skipped that failed to read (kept separate so the CLI can be honest)
  truncated: number;      // === overflow.length
}

/** Scan + (unless dryRun) capture each candidate into the raw inbox as `setup-scan` material.
 *  Dedup is unprocessed-scoped (captureItem): re-running re-captures only new/changed docs. Once
 *  SP-4 marks an item `processed`, re-capture policy for that doc is SP-4's concern (it owns the
 *  processed lifecycle), so this scan intentionally does not dedup against processed items. */
export async function runScan(projectRoot: string, brainDir: string, slug: string,
                              opts: { dryRun?: boolean }): Promise<ScanResult> {
  assertSafeSlug(slug);
  const all = await scanCandidates(projectRoot);
  const cap = scanCap();
  const candidates = all.slice(0, cap);
  const overflow = all.slice(cap);
  const truncated = overflow.length;
  if (opts.dryRun) return { candidates, overflow, captured: 0, skipped: 0, errored: 0, truncated };
  let captured = 0, skipped = 0, errored = 0;
  for (const src of candidates) {
    try {
      const r = await captureItem({ brainDir, slug, kind: 'file', source: src, capturedBy: 'setup-scan' });
      if (r.duplicate) skipped++; else captured++;
    } catch { skipped++; errored++; }  // unreadable → skip, never abort the scan
  }
  return { candidates, overflow, captured, skipped, errored, truncated };
}
