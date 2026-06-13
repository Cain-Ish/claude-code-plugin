import { describe, it, expect } from 'vitest';
import { extractYamlValue } from './knowledge-search.js';

describe('extractYamlValue', () => {
  it('parses an empty quoted value to "" (not the closing quote)', () => {
    expect(extractYamlValue('description: ""', 'description')).toBe('');
  });
  it('parses a normal quoted value', () => {
    expect(extractYamlValue('title: "Hello World"', 'title')).toBe('Hello World');
  });
  it('parses an unquoted value', () => {
    expect(extractYamlValue('type: entities', 'type')).toBe('entities');
  });
  it('returns "" for an absent key', () => {
    expect(extractYamlValue('title: X', 'description')).toBe('');
  });
  it('parses a bare empty value (key:)', () => {
    expect(extractYamlValue('description:', 'description')).toBe('');
  });
});
