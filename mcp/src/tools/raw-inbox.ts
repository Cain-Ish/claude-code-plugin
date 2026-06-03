import { promises as fs } from 'fs';
import { join, basename, extname } from 'path';
import { hashContent, assertSafeSlug } from './doc-sources.js';

export type RawStatus = 'unprocessed' | 'processed' | 'discarded';
export type CapturedBy = 'user' | 'setup-scan' | 'dream';

export interface RawItem {
  id: string;
  source: string;
  captured_at: string;
  captured_by: CapturedBy;
  content_type: string;
  status: RawStatus;
  target_node?: string;
  blob?: string;
  hash: string;
  gist: string;
  body: string;
  malformed?: boolean;
}

export interface CaptureInput {
  brainDir: string;
  slug: string;
  source: string;                 // file path, url, or 'paste'
  kind: 'file' | 'url' | 'paste';
  content?: string;               // paste text / url string; for files it is read from disk
  targetNode?: string;
  capturedBy?: CapturedBy;
  now?: string;                   // ISO timestamp; injectable for deterministic tests
}

export function rawDir(brainDir: string, slug: string): string {
  return join(brainDir, 'projects', slug, 'raw');
}

/** kebab slug from arbitrary text: lowercase, non-alnum→'-', collapse, trim, cap length. */
function slugify(text: string): string {
  const s = text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
  return s || 'item';
}

/** ISO '2026-06-03T14:15:00Z' → compact sortable '20260603T141500Z'. */
function compactStamp(iso: string): string {
  return iso.replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

function isBinary(buf: Buffer): boolean {
  const n = Math.min(buf.length, 8192);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

function contentTypeForFile(path: string, binary: boolean): string {
  const ext = extname(path).toLowerCase();
  if (binary) return ext === '.pdf' ? 'application/pdf' : 'application/octet-stream';
  return ext === '.md' || ext === '.markdown' ? 'text/markdown' : 'text/plain';
}

/** Flatten a frontmatter value to a single line. The parser is unquoted-flat-YAML, so a value
 *  containing a newline would otherwise inject a spurious field (e.g. a fake `status:` line that
 *  the first-match parser reads back, silently flipping the item's status). Strip CR/LF on write. */
function fmValue(s: string): string { return s.replace(/[\r\n]+/g, ' '); }

/** A raw item id is always `<stamp>-<slug>` (internally generated). Reject anything that could
 *  escape the raw/ dir when an id arrives from outside (e.g. `--discard ../../wiki/page`). */
function isSafeId(id: string): boolean { return !!id && !/[\\/]|\.\./.test(id); }

function serialize(item: RawItem): string {
  const fm: string[] = ['---'];
  fm.push(`id: ${fmValue(item.id)}`);
  fm.push(`source: ${fmValue(item.source)}`);
  fm.push(`captured_at: ${fmValue(item.captured_at)}`);
  fm.push(`captured_by: ${fmValue(item.captured_by)}`);
  fm.push(`content_type: ${fmValue(item.content_type)}`);
  fm.push(`status: ${fmValue(item.status)}`);
  if (item.target_node) fm.push(`target_node: ${fmValue(item.target_node)}`);
  if (item.blob) fm.push(`blob: ${fmValue(item.blob)}`);
  fm.push(`hash: ${fmValue(item.hash)}`);
  fm.push(`gist: ${fmValue(item.gist)}`);
  fm.push('---', '', item.body, '');
  return fm.join('\n');
}

/** Tolerant flat-frontmatter parse. id comes from the filename (authoritative). */
function parse(content: string, id: string): RawItem {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  const base: RawItem = {
    id, source: '', captured_at: '', captured_by: 'user', content_type: '',
    status: 'unprocessed', hash: '', gist: '', body: '',
  };
  if (!m) { return { ...base, body: content, malformed: true }; }
  const [, fmText, body] = m;
  const get = (k: string): string | undefined => {
    const mm = fmText.match(new RegExp(`^${k}:[ \\t]*(.*)$`, 'm'));
    return mm ? mm[1].trim() : undefined;
  };
  const status = (get('status') ?? '') as RawStatus;
  const validStatus = status === 'unprocessed' || status === 'processed' || status === 'discarded';
  const item: RawItem = {
    id,
    source: get('source') ?? '',
    captured_at: get('captured_at') ?? '',
    captured_by: (get('captured_by') as CapturedBy) ?? 'user',
    content_type: get('content_type') ?? '',
    status: validStatus ? status : 'unprocessed',
    target_node: get('target_node') || undefined,
    blob: get('blob') || undefined,
    hash: get('hash') ?? '',
    gist: get('gist') ?? '',
    body: body.trim(),
  };
  // Malformed = missing the fields a well-formed capture always writes, or a bad status.
  if (!item.source || !item.captured_at || !item.content_type || !validStatus) item.malformed = true;
  return item;
}

async function readItems(brainDir: string, slug: string): Promise<RawItem[]> {
  const dir = rawDir(brainDir, slug);
  let names: string[] = [];
  try { names = (await fs.readdir(dir)).filter(n => n.endsWith('.md')); } catch { return []; }
  const items: RawItem[] = [];
  for (const name of names.sort()) {
    try {
      const content = await fs.readFile(join(dir, name), 'utf-8');
      items.push(parse(content, name.replace(/\.md$/, '')));
    } catch { /* skip unreadable */ }
  }
  return items;
}

export async function listItems(brainDir: string, slug: string): Promise<RawItem[]> {
  assertSafeSlug(slug);
  return readItems(brainDir, slug);
}

export async function unprocessedCount(brainDir: string, slug: string): Promise<number> {
  assertSafeSlug(slug);
  const items = await readItems(brainDir, slug);
  // malformed items count as unprocessed so they stay visible in the backlog.
  return items.filter(i => i.status === 'unprocessed' || i.malformed).length;
}

export async function setStatus(brainDir: string, slug: string, id: string, status: RawStatus): Promise<boolean> {
  assertSafeSlug(slug);
  if (!isSafeId(id)) return false; // never let an external id (`--discard <id>`) escape raw/
  const file = join(rawDir(brainDir, slug), `${id}.md`);
  let content: string;
  try { content = await fs.readFile(file, 'utf-8'); } catch { return false; }
  const next = /^status:[ \t]*.*$/m.test(content)
    ? content.replace(/^status:[ \t]*.*$/m, `status: ${status}`)
    : content.replace(/^---\r?\n/, `---\nstatus: ${status}\n`);
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, next);
  await fs.rename(tmp, file); // atomic
  return true;
}

export async function captureItem(input: CaptureInput): Promise<{ id: string; duplicate: boolean; unprocessed: number }> {
  assertSafeSlug(input.slug);
  const dir = rawDir(input.brainDir, input.slug);
  const now = input.now ?? new Date().toISOString();
  const capturedBy = input.capturedBy ?? 'user';

  // Resolve content + blob + content_type by kind.
  let body = '';
  let blobBuf: Buffer | undefined;
  let blobExt = '';
  let contentType = '';
  let gistSeed = '';
  let hashInput = '';

  if (input.kind === 'paste') {
    body = input.content ?? '';
    contentType = 'text/markdown';
    gistSeed = body;
    hashInput = `paste:${body}`;
  } else if (input.kind === 'url') {
    const url = input.content ?? input.source;
    body = url;
    contentType = 'text/uri-list';
    gistSeed = url;
    hashInput = `url:${url}`;
  } else {
    const buf = await fs.readFile(input.source);
    const binary = isBinary(buf);
    contentType = contentTypeForFile(input.source, binary);
    hashInput = `file:${hashContent(buf.toString('binary'))}`;
    if (binary) {
      blobBuf = buf;
      blobExt = extname(input.source) || '.bin';
      gistSeed = basename(input.source);
      body = `(binary ${contentType}; original captured as the sibling blob) — ${basename(input.source)}`;
    } else {
      body = buf.toString('utf-8');
      gistSeed = body;
    }
  }

  const hash = hashContent(hashInput);

  // Dedup: an existing UNPROCESSED item with the same hash → return it.
  const existing = (await readItems(input.brainDir, input.slug))
    .find(i => i.hash === hash && i.status === 'unprocessed');
  if (existing) {
    return { id: existing.id, duplicate: true, unprocessed: await unprocessedCount(input.brainDir, input.slug) };
  }

  // Unique id (collision suffix).
  await fs.mkdir(dir, { recursive: true });
  const sourceSlug = input.kind === 'url' ? slugify(input.content ?? input.source)
    : input.kind === 'file' ? slugify(basename(input.source))
    : slugify(body);
  const baseId = `${compactStamp(now)}-${sourceSlug}`;
  let id = baseId;
  for (let n = 2; ; n++) {
    try { await fs.access(join(dir, `${id}.md`)); id = `${baseId}-${n}`; } catch { break; }
  }

  const blob = blobBuf ? `${id}${blobExt}` : undefined;
  if (blobBuf && blob) {
    const btmp = join(dir, `${blob}.tmp`);
    await fs.writeFile(btmp, blobBuf);
    await fs.rename(btmp, join(dir, blob));
  }

  const gist = gistSeed.replace(/^#\s*/, '').split('\n').map(l => l.trim()).find(Boolean)?.slice(0, 120) ?? '';
  const item: RawItem = {
    id, source: input.source, captured_at: now, captured_by: capturedBy,
    content_type: contentType, status: 'unprocessed',
    target_node: input.targetNode, blob, hash, gist, body,
  };
  const file = join(dir, `${id}.md`);
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, serialize(item));
  await fs.rename(tmp, file);

  return { id, duplicate: false, unprocessed: await unprocessedCount(input.brainDir, input.slug) };
}
