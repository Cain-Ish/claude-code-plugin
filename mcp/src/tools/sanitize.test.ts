import { describe, it, expect } from 'vitest';
import { stripInvisible } from './sanitize.js';

describe('stripInvisible (canonical sanitizer)', () => {
  it('removes the Unicode Tags block (ASCII-smuggling channel)', () => {
    const smuggled = 'hello' + String.fromCodePoint(0xE0041, 0xE0042) + 'world';
    expect(stripInvisible(smuggled)).toBe('helloworld');
  });

  it('removes zero-width space, word joiner, and BOM', () => {
    const dirty = 'a' + String.fromCodePoint(0x200B) + 'b'
      + String.fromCodePoint(0x2060) + 'c' + String.fromCodePoint(0xFEFF) + 'd';
    expect(stripInvisible(dirty)).toBe('abcd');
  });

  it('preserves ZWNJ/ZWJ used by scripts and emoji sequences', () => {
    const family = String.fromCodePoint(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467);
    expect(stripInvisible(family)).toBe(family);
  });

  it('is idempotent and handles empty input', () => {
    expect(stripInvisible('')).toBe('');
    const once = stripInvisible('x' + String.fromCodePoint(0x200B) + 'y');
    expect(stripInvisible(once)).toBe(once);
  });
});
