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
});
