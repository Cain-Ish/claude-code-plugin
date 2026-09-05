import { describe, it, expect } from 'vitest';
import { matchFrontmatter, stripFrontmatter, replaceFrontmatter, FM_OPEN_RE, parseDoc, extractYamlValue, extractYamlList, stripBom, hasFrontmatterFence } from './frontmatter.js';
import * as ks from './knowledge-search.js';

const LF = '---\ntitle: a\ntype: entities\n---\n\n# A\n\nbody line\n';
const CRLF = '---\r\ntitle: a\r\ntype: entities\r\n---\r\n\r\n# A\r\n\r\nbody line\r\n';

describe('frontmatter fence helpers', () => {
  it('matchFrontmatter splits fm and body on LF fences', () => {
    const m = matchFrontmatter(LF)!;
    expect(m.fm).toBe('title: a\ntype: entities');
    expect(m.body).toBe('\n# A\n\nbody line\n');
  });

  it('matchFrontmatter splits fm and body on CRLF fences (Windows/autocrlf pages)', () => {
    const m = matchFrontmatter(CRLF)!;
    expect(m.fm).toBe('title: a\r\ntype: entities');
    expect(m.body).toBe('\r\n# A\r\n\r\nbody line\r\n');
  });

  it('matchFrontmatter is null on plain text and on an UNTERMINATED fence', () => {
    expect(matchFrontmatter('# just a heading\n')).toBeNull();
    expect(matchFrontmatter('---\ntitle: a\nno closing fence\n')).toBeNull();
  });

  it('matchFrontmatter handles a closing fence at EOF (no trailing newline)', () => {
    const m = matchFrontmatter('---\ntitle: a\n---')!;
    expect(m.fm).toBe('title: a');
    expect(m.body).toBe('');
  });

  // D054: a UTF-8 BOM (U+FEFF) shifts the fence to offset 1; the anchored `^---` regexes
  // silently saw "no frontmatter", and knowledge_validate's autofix prepended a SECOND block on
  // top of the original (losing project:/tags: and re-dating created/updated to today).
  it('stripBom removes a leading U+FEFF and is a no-op on clean input', () => {
    expect(stripBom('﻿' + LF)).toBe(LF);
    expect(stripBom(LF)).toBe(LF);
  });

  it('matchFrontmatter parses a BOM-prefixed file the same as its clean equivalent', () => {
    const m = matchFrontmatter('﻿' + LF)!;
    expect(m.fm).toBe('title: a\ntype: entities');
    expect(m.body).toBe('\n# A\n\nbody line\n');
  });

  it('hasFrontmatterFence is true for a BOM-prefixed fence (FM_OPEN_RE alone is not)', () => {
    expect(hasFrontmatterFence('﻿' + LF)).toBe(true);
    expect(FM_OPEN_RE.test('﻿' + LF)).toBe(false);   // documents the raw regex's blind spot
  });

  it('stripFrontmatter removes the block; passes non-frontmatter content through unchanged', () => {
    expect(stripFrontmatter(LF)).toBe('\n# A\n\nbody line\n');
    expect(stripFrontmatter('plain content')).toBe('plain content');
  });

  it('replaceFrontmatter swaps the YAML, normalizes fences to LF, keeps the body', () => {
    expect(replaceFrontmatter(CRLF, 'title: b')).toBe('---\ntitle: b\n---\r\n\r\n# A\r\n\r\nbody line\r\n');
  });

  it('replaceFrontmatter never interprets $& / $1 in the new YAML (function replacement)', () => {
    const out = replaceFrontmatter('---\nold: 1\n---\nbody', 'v: "a$&b$1"');
    expect(out).toBe('---\nv: "a$&b$1"\n---\nbody');
  });

  it('FM_OPEN_RE detects an OPEN fence without requiring a closed block (missing_frontmatter contract)', () => {
    expect(FM_OPEN_RE.test('---\nunterminated')).toBe(true);
    expect(FM_OPEN_RE.test('---\r\nunterminated')).toBe(true);
    expect(FM_OPEN_RE.test('no fence')).toBe(false);
  });
});

// Back-compat lock: knowledge-search.ts re-exports the moved parsers, so any
// importer not yet migrated keeps getting the SAME functions (not stale copies).
describe('knowledge-search re-exports (back-compat)', () => {
  it('parseDoc / extractYamlValue / extractYamlList are identity re-exports', () => {
    expect(ks.parseDoc).toBe(parseDoc);
    expect(ks.extractYamlValue).toBe(extractYamlValue);
    expect(ks.extractYamlList).toBe(extractYamlList);
  });
});
