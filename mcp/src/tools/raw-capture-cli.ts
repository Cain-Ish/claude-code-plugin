import { homedir } from 'os';
import { join, basename } from 'path';
import { existsSync, readFileSync, statSync } from 'fs';
import { captureItem, listItems, setStatus, unprocessedCount, markProcessed, rawDir } from './raw-inbox.js';

function resolveSlug(brainDir: string): string | undefined {
  if (process.env.SB_ACTIVE_SLUG) return process.env.SB_ACTIVE_SLUG;
  // CLAUDE_PROJECT_DIR (per-session project root) beats the shared pin — a concurrent
  // session can clobber the pin. tmp→scratch mirrors project-dir.ts / lib.sh sb_slug_from_dir.
  if (process.env.CLAUDE_PROJECT_DIR) {
    const b = basename(process.env.CLAUDE_PROJECT_DIR);
    if (b && b !== '/' && b !== '.' && b !== '..') return /^tmp\.|^tmp$|^\.tmp\.|^tmpfs$/.test(b) ? 'scratch' : b;
  }
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  const base = basename(process.cwd());
  return base && base !== '/' && base !== '.' && base !== '..' ? base : undefined;
}

/** Pull `--node <slug>` out of argv; return the rest + the node value. */
function takeNode(args: string[]): { rest: string[]; node?: string } {
  const i = args.indexOf('--node');
  if (i >= 0 && args[i + 1]) return { rest: [...args.slice(0, i), ...args.slice(i + 2)], node: args[i + 1] };
  return { rest: args };
}

async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
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
      // Deterministic TSV work-list for the maintainer drain (Phase 4c): drainable items only.
      for (const i of await listItems(brainDir, slug)) {
        if (i.status !== 'unprocessed' || i.malformed) continue;
        const path = join(rawDir(brainDir, slug), `${i.id}.md`);
        const cell = (s: string) => (s || '').replace(/[\t\r\n]+/g, ' ');
        // cell() every variable field — a tab in target_node (fmValue strips CR/LF, not tabs)
        // would otherwise shift the TSV columns and corrupt the machine work-list.
        console.log([i.id, path, i.captured_by, cell(i.target_node ?? ''), cell(i.gist)].join('\t'));
      }
    } else if (action === 'process') {
      const id = rest[0];
      if (!id) { console.log('usage: capture process <id> [--node <slug>]'); return; }
      console.log(await markProcessed(brainDir, slug, id, node)
        ? `Processed ${id}` : `No raw item with id ${id}.`);
    } else if (action === 'paste') {
      const content = readFileSync(0, 'utf-8');           // stdin
      if (!content.trim()) { console.log('capture: nothing on stdin.'); return; }
      const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content, targetNode: node });
      console.log(`${r.duplicate ? 'Already captured' : 'Captured'} ${r.id} — ${r.unprocessed} unprocessed.`);
    } else if (action === 'capture') {
      const src = rest[0];
      if (!src) { console.log('usage: capture <path|url> [--node <slug>]  |  capture paste'); return; }
      let kind: 'file' | 'url' | 'paste'; let content: string | undefined; let source = src;
      if (/^https?:\/\//i.test(src)) { kind = 'url'; content = src; }
      else if (existsSync(src) && statSync(src).isFile()) { kind = 'file'; }
      else { kind = 'paste'; content = src; source = 'paste'; } // inline text → canonical paste source
      const r = await captureItem({ brainDir, slug, kind, source, content, targetNode: node });
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
