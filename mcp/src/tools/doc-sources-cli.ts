import { homedir } from 'os';
import { join } from 'path';
import { buildRegistry } from './doc-sources.js';

// Thin entry: BRAIN_DIR from env, projectRoot + slug from argv. Invoked by
// scripts/discover-doc-sources.sh at SessionStart. Fail-soft (always exit 0).
async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
  const projectRoot = process.argv[2] || process.cwd();
  const slug = process.argv[3];
  if (!slug) { process.stderr.write('doc-sources-cli: missing slug arg\n'); return; }
  try {
    const reg = await buildRegistry(projectRoot, brainDir, slug);
    process.stderr.write(`doc-sources: ${reg.entries.length} entries for ${reg.project}\n`);
  } catch (e) {
    process.stderr.write(`doc-sources-cli error: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

main();
