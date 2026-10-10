import { homedir } from 'os';
import { join, basename, relative } from 'path';
import { existsSync, readFileSync } from 'fs';
import { runScan, originGuard } from './raw-scan.js';
import { resolveActiveSlug, slugFromProjectDir } from './project-dir.js';
import { cleanEnvPath } from '../path-guard.js';
import { resolveBrainDir } from '../brain-paths.js';
import { rawCaptureCliCommand, shellWord } from './raw-inbox.js';

/** How a person lists what the scan filed: raw-capture-cli.bundle.js, the sibling of this running
 *  bundle. Nothing invokes the capture skill (user-invocable:false, disable-model-invocation:true),
 *  so the hint names the CLI itself, never the skill as a slash command; and never
 *  `$CLAUDE_PLUGIN_ROOT`, which a Bash tool's environment does not set (T6). */
const RAW_CAPTURE_CLI = rawCaptureCliCommand(process.argv[1]);

function resolveSlug(brainDir: string): string | undefined {
  // SB_ACTIVE_SLUG (explicit override) first; else the shared resolver
  // (CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd).
  return process.env.SB_ACTIVE_SLUG || resolveActiveSlug(brainDir);
}

async function main(): Promise<void> {
  const brainDir = resolveBrainDir();
  const projectRoot = process.env.SCAN_ROOT || process.cwd();
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('scan: could not resolve the active project. cd into a project.'); return; }
  // Source of truth = the scanned resource, not the ambient session. Refuse a destination that
  // disagrees with the repo being scanned unless SB_ACTIVE_SLUG explicitly overrides.
  const originSlug = slugFromProjectDir(projectRoot);
  const guard = originGuard(originSlug, slug, !!process.env.SB_ACTIVE_SLUG);
  if (!guard.ok) { console.log(`scan: ${guard.reason}`); return; }
  const dryRun = process.argv.includes('--dry-run');
  try {
    const r = await runScan(projectRoot, brainDir, slug, { dryRun, origin: originSlug });
    if (dryRun) {
      console.log(`${r.candidates.length} high-signal doc(s) to capture into ${slug}'s raw inbox:`);
      for (const p of r.candidates) console.log(`  - ${relative(projectRoot, p).split(/[\\/]+/).join('/')}`);
      if (r.candidates.length === 0) console.log('  (no high-signal docs found)');
      if (r.overflow.length) {
        console.log(`  …and ${r.overflow.length} more over the SB_SCAN_MAX cap (NOT captured — raise SB_SCAN_MAX or /second-brain:track them):`);
        for (const p of r.overflow) console.log(`    · ${relative(projectRoot, p).split(/[\\/]+/).join('/')}`);
      }
    } else {
      const more = r.truncated ? `, ${r.truncated} over the cap (raise SB_SCAN_MAX or /second-brain:track them)` : '';
      const errNote = r.errored ? ` (${r.errored} unreadable)` : '';
      console.log(`Captured ${r.captured}, skipped ${r.skipped} already-in-inbox${errNote}${more}. Review: ${RAW_CAPTURE_CLI} --slug ${shellWord(slug)} list (/second-brain:maintain drains them)`);
    }
  } catch (e) {
    console.log(`scan error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
