import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { loadRegistry, projectFamily, resolveSlugByPath } from './project-registry.js';

function brain(records: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'sb-reg-'));
  writeFileSync(join(dir, 'projects.jsonl'), records);
  return dir;
}

const FAMILY =
  '{"slug":"acme","root_path":"/repos/acme"}\n' +
  '{"slug":"acme__api","parent":"acme","root_path":"/repos/acme/packages/api"}\n' +
  '{"slug":"acme__web","parent":"acme","root_path":"/repos/acme/packages/web"}\n' +
  '{"slug":"companion","root_path":"/repos/companion"}\n';

describe('loadRegistry', () => {
  it('parses JSONL tolerantly, skipping blank and malformed lines', () => {
    const dir = brain(FAMILY + '\n{ not json }\n');
    const recs = loadRegistry(dir);
    expect(recs.map(r => r.slug).sort()).toEqual(['acme', 'acme__api', 'acme__web', 'companion']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('returns [] when the registry is absent', () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-reg-empty-'));
    expect(loadRegistry(dir)).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('projectFamily', () => {
  it('a sub-project sees root + all siblings + itself (symmetric)', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'acme__api')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    expect([...projectFamily(dir, 'acme__web')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('the root sees all its children + itself', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'acme')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('a standalone project is its own singleton family', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'companion')]).toEqual(['companion']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('an unregistered slug is its own singleton family', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'ghost')]).toEqual(['ghost']);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('resolveSlugByPath', () => {
  it('longest-prefix matches a cwd inside a registered child', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme/packages/api/src/x')).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('matches the monorepo root when cwd is the root (not a child)', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme')).toBe('acme');
    rmSync(dir, { recursive: true, force: true });
  });
  it('returns undefined when no root_path is a prefix', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/somewhere/else')).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });
  it('does not match a sibling-prefix false positive (/repos/acme-other)', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme-other/src')).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });
});
