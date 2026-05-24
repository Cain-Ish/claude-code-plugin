import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { runSb } from '../src/cli/sb.js';

describe('sb CLI', () => {
  let brainDir: string;
  let knowledgeDir: string;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'sb-cli-brain-'));
    knowledgeDir = mkdtempSync(join(tmpdir(), 'sb-cli-know-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'entities'), { recursive: true });
    writeFileSync(join(knowledgeDir, 'wiki', 'entities', 'foo.md'),
      '---\ntitle: "Foo entity"\ntype: entities\ndescription: "About foo widget"\ntags: [foo, widget]\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nFoo is a thing for widget processing.\n',
      'utf-8');
    mkdirSync(join(brainDir, 'projects', 'test-project'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'test-project', 'PROJECT.md'),
      '# PROJECT: test-project\n\n## Goal\nA test\n\n## Open blockers\n\n## Recent decisions\n', 'utf-8');
    writeFileSync(join(brainDir, 'projects.jsonl'),
      '{"slug":"test-project","name":"test-project"}\n', 'utf-8');
  });

  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    rmSync(knowledgeDir, { recursive: true, force: true });
  });

  it('shows help with no args', async () => {
    const r = await runSb([], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('Usage:');
    expect(r.stdout).toContain('query');
    expect(r.stdout).toContain('recall');
    expect(r.stdout).toContain('pin');
    expect(r.stdout).toContain('status');
  });

  it('shows help on `help` subcommand', async () => {
    const r = await runSb(['help'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('Usage:');
  });

  it('query returns wiki results', async () => {
    const r = await runSb(['query', 'foo widget'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/foo/);
  });

  it('query surfaces the frontmatter description in output', async () => {
    // The fixture page has description: "About foo widget" — assert that exact
    // curated description appears (not just a token that also happens to be in
    // the slug or body). This would fail if description rendering were removed.
    const r = await runSb(['query', 'foo widget'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('About foo widget');
  });

  it('query with no text errors', async () => {
    const r = await runSb(['query'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('missing search text');
  });

  it('pin user appends to USER.md', async () => {
    const r = await runSb(['pin', 'user', 'prefer', 'terse', 'responses'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    const userMd = readFileSync(join(brainDir, 'USER.md'), 'utf-8');
    expect(userMd).toContain('prefer terse responses');
    expect(r.stdout).toContain('prefer terse responses');
  });

  it('pin project appends to a section', async () => {
    const r = await runSb(['pin', 'project', 'test-project', 'blockers', 'blocked', 'on', 'X'],
      { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    const pf = readFileSync(join(brainDir, 'projects', 'test-project', 'PROJECT.md'), 'utf-8');
    expect(pf).toContain('blocked on X');
  });

  it('pin project with missing args errors', async () => {
    const r = await runSb(['pin', 'project'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('usage');
  });

  it('pin user with no text errors', async () => {
    const r = await runSb(['pin', 'user'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('missing text');
  });

  it('pin with unknown sub errors', async () => {
    const r = await runSb(['pin', 'whatever'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('unknown subcommand');
  });

  it('status reports project counts and PROJECT.md size', async () => {
    const r = await runSb(['status'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('USER.md');
    expect(r.stdout).toContain('Registered projects: 1');
    expect(r.stdout).toContain('test-project/PROJECT.md');
    expect(r.stdout).toContain('Wiki pages');
    expect(r.stdout).toContain('entities: 1');
  });

  it('unknown command exits non-zero', async () => {
    const r = await runSb(['nonsense'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('unknown command');
  });

  it('recall returns empty gracefully when no transcripts exist', async () => {
    const r = await runSb(['recall', 'anything'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('no results');
  });

  describe('auth subcommand', () => {
    const originalKey = process.env.ANTHROPIC_API_KEY;
    const originalPath = process.env.PATH;
    let pathDir: string;

    beforeEach(() => {
      pathDir = mkdtempSync(join(tmpdir(), 'sb-cli-path-'));
      delete process.env.ANTHROPIC_API_KEY;
      process.env.PATH = pathDir;
    });

    afterEach(() => {
      if (originalKey !== undefined) process.env.ANTHROPIC_API_KEY = originalKey;
      else delete process.env.ANTHROPIC_API_KEY;
      process.env.PATH = originalPath;
      rmSync(pathDir, { recursive: true, force: true });
    });

    it('auth status reports api-key mode when ANTHROPIC_API_KEY is set', async () => {
      process.env.ANTHROPIC_API_KEY = 'sk-ant-test-1234567890abcdef';
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key/);
      expect(r.stdout).toContain('anthropic-api');
      expect(r.stdout).not.toContain('sk-ant-test-1234567890abcdef');
    });

    it('auth status reports subscription mode when only claude CLI is on PATH', async () => {
      writeFileSync(join(pathDir, 'claude'), '#!/bin/sh\nexit 0\n');
      mkdirSync(pathDir, { recursive: true });
      writeFileSync(join(pathDir, 'claude'), '#!/bin/sh\nexit 0\n');
      const { chmodSync } = await import('fs');
      chmodSync(join(pathDir, 'claude'), 0o755);
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: subscription/);
      expect(r.stdout).toMatch(/recursive-claude|OAuth/);
    });

    it('auth status reports none when neither key nor claude is available', async () => {
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: none/);
    });

    it('auth (no sub) defaults to status', async () => {
      process.env.ANTHROPIC_API_KEY = 'sk-ant-z';
      const r = await runSb(['auth'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key/);
    });

    it('auth doctor shows both setup paths', async () => {
      const r = await runSb(['auth', 'doctor'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/ANTHROPIC_API_KEY/);
      expect(r.stdout).toMatch(/claude \/login/);
      expect(r.stdout).toMatch(/subscription/);
    });

    it('auth with unknown sub errors out', async () => {
      const r = await runSb(['auth', 'bogus'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(2);
      expect(r.stderr).toMatch(/usage|unknown/);
    });

    it('help mentions auth', async () => {
      const r = await runSb(['help'], { brainDir, knowledgeDir });
      expect(r.stdout).toContain('auth');
    });
  });
});
