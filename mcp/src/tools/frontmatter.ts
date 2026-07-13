// Canonical frontmatter fence + flat-YAML helpers — the single source for the
// fence regexes that were previously copy-pasted across 8 files (each copy a
// chance to reintroduce the LF-only bug). Every fence pattern here MUST stay
// CRLF-tolerant (0.28.3): a wiki page hand-edited on Windows / checked out with
// autocrlf has `---\r\n` fences, and an LF-only `^---\n` silently misses the
// whole frontmatter (title/type/related lost from search). Dependency-free
// (pure ai-block module only) so CLI bundles can import it without dragging
// glob/js-yaml.
import { parseAiBlock, stripAiBlock } from './ai-block.js';

/** Opening fence only — "does this file START a frontmatter block?". The
 *  missing_frontmatter check deliberately does NOT require a CLOSED fence. */
export const FM_OPEN_RE = /^---\r?\n/;

export interface Frontmatter { fm: string; body: string }

/** Split content into { fm, body }. `body` excludes the fences and at most ONE
 *  newline after the closing `---`. Returns null when there is no CLOSED
 *  frontmatter block (unterminated fence = no frontmatter). */
export function matchFrontmatter(content: string): Frontmatter | null {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}

/** Body without the frontmatter block (content unchanged when none). */
export function stripFrontmatter(content: string): string {
  const m = matchFrontmatter(content);
  return m ? m.body : content;
}

/** Replace the FIRST frontmatter block's YAML, preserving the body. The
 *  replacement is a function so `$&`/`$1` sequences inside newFm can never be
 *  interpreted as regex replacement patterns. No-op when no closed block. */
export function replaceFrontmatter(content: string, newFm: string): string {
  return content.replace(/^---\r?\n[\s\S]*?\r?\n---/, () => `---\n${newFm}\n---`);
}

export function extractYamlValue(yaml: string, key: string): string {
  // `(.*?)` not `(.+?)`: an empty quoted value `key: ""` must parse to '' — with
  // `.+?` the opening quote is eaten by `['"]?` and the closing quote becomes the
  // captured value (`"`), which then leaks into MOC descriptions and breaks reindex
  // idempotency once a page carries `description: ""`.
  const re = new RegExp(`^${key}:\\s*['"]?(.*?)['"]?\\s*$`, 'm');
  const m = yaml.match(re);
  return m ? m[1].trim() : '';
}

export function extractYamlList(yaml: string, key: string): string[] {
  // The wiki uses a non-standard `related: [[slug]], [[other]]` convention for
  // wiki-links in frontmatter. The naive `^key:\s*\[(.+?)\]` regex misparses
  // these as YAML inline lists, capturing `[slug` (with leading bracket) and
  // breaking every link-validity check. Detect the wikilink convention first
  // and extract `[[slug]]` tokens directly; only fall through to the standard
  // YAML inline / block parsers if no wikilinks are present on the line.
  const lineMatch = yaml.match(new RegExp(`^${key}:[ \\t]+(\\S.*?)\\s*$`, 'm'));
  if (lineMatch) {
    const value = lineMatch[1];
    const wikiLinks = value.match(/\[\[([^\]\[]+)\]\]/g);
    if (wikiLinks && wikiLinks.length > 0) {
      return [...new Set(
        wikiLinks.map(l => l.slice(2, -2).trim()).filter(Boolean)
      )];
    }
  }
  const inline = yaml.match(new RegExp(`^${key}:\\s*\\[(.+?)\\]`, 'm'));
  if (inline) {
    return inline[1].split(',').map(s => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  }
  const items: string[] = [];
  const lines = yaml.split('\n');
  let collecting = false;
  for (const line of lines) {
    if (line.match(new RegExp(`^${key}:`))) { collecting = true; continue; }
    if (collecting) {
      const itemMatch = line.match(/^\s+-\s+(.+)/);
      if (itemMatch) { items.push(itemMatch[1].trim().replace(/^['"]|['"]$/g, '')); }
      else { collecting = false; }
    }
  }
  return items;
}

export interface ParsedDoc {
  title: string;
  description: string;
  type: string;
  tags: string[];
  related: string[];
  body: string;
  path: string;
  updated: string;
  created: string;
  project: string;
  area: string;
  aiBlock?: Record<string, string>;
}

export function parseDoc(content: string, filePath: string): ParsedDoc {
  const doc: ParsedDoc = {
    title: '', description: '', type: '', tags: [], related: [], body: content, path: filePath,
    updated: '', created: '', project: '', area: '',
  };

  let hasRelatedKey = false;   // P1: distinguish an explicit `related: []` from an ABSENT key
  const fmMatch = matchFrontmatter(content);
  if (fmMatch) {
    const fm = fmMatch.fm;
    doc.body = fmMatch.body;
    doc.title = extractYamlValue(fm, 'title');
    doc.description = extractYamlValue(fm, 'description');
    doc.type = extractYamlValue(fm, 'type');
    doc.tags = extractYamlList(fm, 'tags');
    doc.related = extractYamlList(fm, 'related');
    hasRelatedKey = /^related:/m.test(fm);
    doc.updated = extractYamlValue(fm, 'updated');
    doc.created = extractYamlValue(fm, 'created');
    doc.project = extractYamlValue(fm, 'project');
    doc.area = extractYamlValue(fm, 'area');
  }

  if (!doc.title) {
    const headingMatch = doc.body.match(/^#\s+(.+)/m);
    if (headingMatch) doc.title = headingMatch[1].trim();
  }

  if (!doc.type) {
    const rel = filePath.split('/');
    const wikiIdx = rel.lastIndexOf('wiki');
    if (wikiIdx >= 0 && wikiIdx + 1 < rel.length) {
      doc.type = rel[wikiIdx + 1];
    }
  }

  doc.aiBlock = parseAiBlock(content) ?? undefined;

  if (!hasRelatedKey) {
    // P1: scrape body [[links]] ONLY when the related: KEY is ABSENT — an explicit
    // `related: []` is authoritative (it is the projector's canonical cleaned form
    // for an edgeless page; re-filling it from body links would resurrect false
    // related_drift + phantom boosts on exactly the pages the projector just cleaned).
    // Strip the ai-block first (block values are plain slugs; a stray bracket there
    // must not pollute related:).
    const wikiLinks = stripAiBlock(doc.body).match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map(l => l.slice(2, -2)))];
    }
  }

  return doc;
}
