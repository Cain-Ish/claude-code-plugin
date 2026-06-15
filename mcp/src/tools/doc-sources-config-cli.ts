import { homedir } from 'os';
import { join, basename } from 'path';
import { existsSync, readFileSync } from 'fs';
import { addLocation, removeLocation, listLocations } from './doc-sources.js';
import { resolveActiveSlug } from './project-dir.js';
import { cleanEnvPath } from '../path-guard.js';

function resolveSlug(brainDir: string): string | undefined {
  // The shared resolver: CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd.
  return resolveActiveSlug(brainDir);
}

async function main(): Promise<void> {
  const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(homedir(), '.second-brain');
  const action = process.argv[2];
  const location = process.argv[3];
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('track: could not resolve the active project (no slug)'); return; }
  try {
    if (action === 'list') {
      const locs = await listLocations(brainDir, slug);
      console.log(`Tracked doc locations for ${slug} (${locs.length}):`);
      for (const l of locs) console.log(`  - ${l}`);
      if (locs.length === 0) console.log('  (none — add one, e.g. /second-brain:track docs/)');
    } else if (action === 'add') {
      if (!location) { console.log('usage: track add <path-or-glob>'); return; }
      const r = await addLocation(brainDir, slug, location);
      console.log(r.added ? `Tracking "${location}" for ${slug}. Locations: ${r.locations.join(', ')}` : `"${location}" is already tracked.`);
      console.log('(scanned into the searchable registry at next session start)');
    } else if (action === 'remove') {
      if (!location) { console.log('usage: track remove <path-or-glob>'); return; }
      const r = await removeLocation(brainDir, slug, location);
      console.log(r.removed ? `Untracked "${location}". Remaining: ${r.locations.join(', ') || '(none)'}` : `"${location}" was not tracked.`);
    } else {
      console.log('usage: track add|remove|list [location]');
    }
  } catch (e) {
    console.log(`track error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
