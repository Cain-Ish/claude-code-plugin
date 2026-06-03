import { homedir } from 'os';
import { join, basename, relative } from 'path';
import { existsSync, readFileSync } from 'fs';
import { runScan } from './raw-scan.js';

function resolveSlug(brainDir: string): string | undefined {
  if (process.env.SB_ACTIVE_SLUG) return process.env.SB_ACTIVE_SLUG;
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  const base = basename(process.cwd());
  return base && base !== '/' && base !== '.' && base !== '..' ? base : undefined;
}

async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
  const projectRoot = process.env.SCAN_ROOT || process.cwd();
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('scan: could not resolve the active project. cd into a project.'); return; }
  const dryRun = process.argv.includes('--dry-run');
  try {
    const r = await runScan(projectRoot, brainDir, slug, { dryRun });
    if (dryRun) {
      const more = r.truncated ? ` (+${r.truncated} over the SB_SCAN_MAX cap)` : '';
      console.log(`${r.candidates.length} high-signal doc(s) to capture into ${slug}'s raw inbox${more}:`);
      for (const p of r.candidates) console.log(`  - ${relative(projectRoot, p)}`);
      if (r.candidates.length === 0) console.log('  (no high-signal docs found)');
    } else {
      const more = r.truncated ? `, ${r.truncated} over the cap (raise SB_SCAN_MAX or /second-brain:track them)` : '';
      console.log(`Captured ${r.captured}, skipped ${r.skipped} already-in-inbox${more}. Review: /second-brain:capture --list`);
    }
  } catch (e) {
    console.log(`scan error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
