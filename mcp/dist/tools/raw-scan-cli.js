import { homedir } from 'os';
import { join, basename, relative } from 'path';
import { existsSync, readFileSync } from 'fs';
import { runScan } from './raw-scan.js';
function resolveSlug(brainDir) {
    if (process.env.SB_ACTIVE_SLUG)
        return process.env.SB_ACTIVE_SLUG;
    // CLAUDE_PROJECT_DIR (per-session project root) beats the shared pin — a concurrent
    // session can clobber the pin. tmp→scratch mirrors project-dir.ts / lib.sh sb_slug_from_dir.
    if (process.env.CLAUDE_PROJECT_DIR) {
        const b = basename(process.env.CLAUDE_PROJECT_DIR);
        if (b && b !== '/' && b !== '.' && b !== '..')
            return /^tmp\.|^tmp$|^\.tmp\.|^tmpfs$/.test(b) ? 'scratch' : b;
    }
    try {
        const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
        if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md')))
            return pin;
    }
    catch { /* no pin */ }
    const base = basename(process.cwd());
    return base && base !== '/' && base !== '.' && base !== '..' ? base : undefined;
}
async function main() {
    const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
    const projectRoot = process.env.SCAN_ROOT || process.cwd();
    const slug = resolveSlug(brainDir);
    if (!slug) {
        console.log('scan: could not resolve the active project. cd into a project.');
        return;
    }
    const dryRun = process.argv.includes('--dry-run');
    try {
        const r = await runScan(projectRoot, brainDir, slug, { dryRun });
        if (dryRun) {
            console.log(`${r.candidates.length} high-signal doc(s) to capture into ${slug}'s raw inbox:`);
            for (const p of r.candidates)
                console.log(`  - ${relative(projectRoot, p)}`);
            if (r.candidates.length === 0)
                console.log('  (no high-signal docs found)');
            if (r.overflow.length) {
                console.log(`  …and ${r.overflow.length} more over the SB_SCAN_MAX cap (NOT captured — raise SB_SCAN_MAX or /second-brain:track them):`);
                for (const p of r.overflow)
                    console.log(`    · ${relative(projectRoot, p)}`);
            }
        }
        else {
            const more = r.truncated ? `, ${r.truncated} over the cap (raise SB_SCAN_MAX or /second-brain:track them)` : '';
            const errNote = r.errored ? ` (${r.errored} unreadable)` : '';
            console.log(`Captured ${r.captured}, skipped ${r.skipped} already-in-inbox${errNote}${more}. Review: /second-brain:capture --list`);
        }
    }
    catch (e) {
        console.log(`scan error: ${e instanceof Error ? e.message : String(e)}`);
    }
}
main();
//# sourceMappingURL=raw-scan-cli.js.map