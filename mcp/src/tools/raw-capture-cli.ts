import { homedir } from 'os';
import { join, basename } from 'path';
import { existsSync, readFileSync, statSync } from 'fs';
import { captureItem, listItems, setStatus, unprocessedCount, markProcessed, rawDir, partitionPending } from './raw-inbox.js';
import { resolveActiveSlug } from './project-dir.js';
import { cleanEnvPath } from '../path-guard.js';

function resolveSlug(brainDir: string): string | undefined {
  // SB_ACTIVE_SLUG (explicit override) first; else the shared resolver
  // (CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd).
  return process.env.SB_ACTIVE_SLUG || resolveActiveSlug(brainDir);
}

/** Pull `--node <slug>` out of argv; return the rest + the node value. */
function takeNode(args: string[]): { rest: string[]; node?: string } {
  const i = args.indexOf('--node');
  if (i >= 0 && args[i + 1]) return { rest: [...args.slice(0, i), ...args.slice(i + 2)], node: args[i + 1] };
  return { rest: args };
}

async function main(): Promise<void> {
  const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(homedir(), '.second-brain');
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('capture: could not resolve the active project (no slug). cd into a project.'); return; }

  const action = process.argv[2];
  const { rest, node } = takeNode(process.argv.slice(3));

  try {
    if (action === 'list') {
      const items = await listItems(brainDir, slug);
      const open = items.filter(i => i.status === 'unprocessed' || i.malformed).length;
      console.log(`Raw inbox for ${slug} — ${items.length} item(s), ${open} unprocessed:`);
      for (const i of items) {
        console.log(`  - ${i.id} [${i.malformed ? 'malformed' : i.status}] ${i.gist || i.source}`);
      }
      if (items.length === 0) console.log('  (empty — capture something, e.g. /second-brain:capture ./notes.md)');
    } else if (action === 'discard') {
      const id = rest[0];
      if (!id) { console.log('usage: capture --discard <id>'); return; }
      console.log(await setStatus(brainDir, slug, id, 'discarded')
        ? `Discarded ${id}.` : `No raw item with id ${id}.`);
    } else if (action === 'pending') {
      // Deterministic TSV work-list for the maintainer drain (Phase 4c): own/legacy-origin drainable only.
      const { drainable, foreign } = partitionPending(await listItems(brainDir, slug), slug);
      for (const i of drainable) {
        const path = join(rawDir(brainDir, slug), `${i.id}.md`).replace(/\\/g, '/');
        const cell = (s: string) => (s || '').replace(/[\t\r\n]+/g, ' ');
        // cell() every variable field — a tab in target_node (fmValue strips CR/LF, not tabs)
        // would otherwise shift the TSV columns and corrupt the machine work-list.
        console.log([i.id, path, i.captured_by, cell(i.target_node ?? ''), cell(i.gist)].join('\t'));
      }
      if (foreign.length) {
        // fail loud: foreign-origin items are NEVER drained silently (the 88-doc misroute class).
        console.error(`pending: held back ${foreign.length} foreign-origin item(s) (origin≠${slug}): ` +
          `${foreign.map(i => i.id).join(', ')} — re-capture in the right project or /second-brain:capture --discard <id>`);
      }
    } else if (action === 'process') {
      const id = rest[0];
      if (!id) { console.log('usage: capture process <id> [--node <slug>]'); return; }
      console.log(await markProcessed(brainDir, slug, id, node)
        ? `Processed ${id}` : `No raw item with id ${id}.`);
    } else if (action === 'paste') {
      const content = readFileSync(0, 'utf-8');           // stdin
      if (!content.trim()) { console.log('capture: nothing on stdin.'); return; }
      const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content, targetNode: node, origin: slug });
      console.log(`${r.duplicate ? 'Already captured' : 'Captured'} ${r.id} — ${r.unprocessed} unprocessed.`);
    } else if (action === 'capture') {
      const src = rest[0];
      if (!src) { console.log('usage: capture <path|url> [--node <slug>]  |  capture paste'); return; }
      let kind: 'file' | 'url' | 'paste'; let content: string | undefined; let source = src;
      if (/^https?:\/\//i.test(src)) { kind = 'url'; content = src; }
      else if (existsSync(src) && statSync(src).isFile()) { kind = 'file'; }
      else { kind = 'paste'; content = src; source = 'paste'; } // inline text → canonical paste source
      const r = await captureItem({ brainDir, slug, kind, source, content, targetNode: node, origin: slug });
      console.log(`${r.duplicate ? 'Already captured' : 'Captured'} ${r.id} (${kind}) — ${r.unprocessed} unprocessed.`);
    } else {
      const n = await unprocessedCount(brainDir, slug);
      console.log(`usage: capture <path|url> | capture paste | capture --list | capture --discard <id>  (${n} unprocessed)`);
    }
  } catch (e) {
    console.log(`capture error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
