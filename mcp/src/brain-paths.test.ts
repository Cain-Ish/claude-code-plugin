import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'fs';
import { isAbsolute, join } from 'path';
import { homedir } from 'os';
import { globSync } from 'glob';
import { fileURLToPath } from 'url';
import { resolveBrainDir, resolveKnowledgeDir } from './brain-paths.js';

// The bug: tools resolved `join(process.env.HOME ?? '', '.second-brain')`. On
// Windows HOME is unset, so the result was a CWD-RELATIVE `.second-brain` that
// landed in whatever repo the MCP server was launched from. These tests pin the
// contract that closes that class: always absolute, anchored on os.homedir(),
// never reading process.env.HOME.

const ENV_KEYS = [
  'HOME',
  'SB_BRAIN_DIR',
  'BRAIN_DIR',
  'KNOWLEDGE_DIR',
  'CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR',
];

describe('brain-paths resolvers', () => {
  const saved: Record<string, string | undefined> = {};
  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it('resolveBrainDir falls back to homedir(), never a relative path', () => {
    const dir = resolveBrainDir();
    expect(isAbsolute(dir)).toBe(true);
    expect(dir).toBe(join(homedir(), '.second-brain'));
  });

  it('resolveBrainDir ignores process.env.HOME (Windows regression)', () => {
    // Even with HOME deliberately set to a bogus relative value, the resolver
    // must anchor on homedir() — the old code would have produced "x/.second-brain".
    process.env.HOME = 'x';
    expect(resolveBrainDir()).toBe(join(homedir(), '.second-brain'));
  });

  it('resolveBrainDir honors SB_BRAIN_DIR over BRAIN_DIR', () => {
    process.env.BRAIN_DIR = '/tmp/brain-b';
    process.env.SB_BRAIN_DIR = '/tmp/brain-a';
    expect(resolveBrainDir()).toBe('/tmp/brain-a');
  });

  it('resolveBrainDir strips CR/LF from env overrides', () => {
    process.env.SB_BRAIN_DIR = '/tmp/brain\r\n';
    expect(resolveBrainDir()).toBe('/tmp/brain');
  });

  it('resolveBrainDir explicit override wins over env', () => {
    process.env.SB_BRAIN_DIR = '/tmp/env';
    expect(resolveBrainDir('/tmp/override')).toBe('/tmp/override');
  });

  it('resolveKnowledgeDir falls back to homedir(), never a relative path', () => {
    const dir = resolveKnowledgeDir();
    expect(isAbsolute(dir)).toBe(true);
    expect(dir).toBe(join(homedir(), 'knowledge'));
  });

  it('resolveKnowledgeDir honors CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR over KNOWLEDGE_DIR', () => {
    process.env.KNOWLEDGE_DIR = '/tmp/kd-b';
    process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR = '/tmp/kd-a';
    expect(resolveKnowledgeDir()).toBe('/tmp/kd-a');
  });

  it('resolveKnowledgeDir explicit override wins over env', () => {
    process.env.KNOWLEDGE_DIR = '/tmp/env';
    expect(resolveKnowledgeDir('/tmp/override')).toBe('/tmp/override');
  });

  // Guards absorbed from the deleted server.ts/dream.ts local copies (0.33.38
  // single-source consolidation) — the canonical resolver must carry them.
  it('resolveKnowledgeDir expands a leading ~ against homedir()', () => {
    process.env.KNOWLEDGE_DIR = '~/kd';
    expect(resolveKnowledgeDir()).toBe(join(homedir(), 'kd'));
  });

  it('resolveKnowledgeDir rejects an unexpanded ${...} placeholder (root .mcp.json gotcha)', () => {
    process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR = '${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR}';
    process.env.KNOWLEDGE_DIR = '/tmp/kd-real';
    expect(resolveKnowledgeDir()).toBe('/tmp/kd-real');
  });

  it('resolveKnowledgeDir skips a whitespace-only candidate', () => {
    process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR = '   ';
    expect(resolveKnowledgeDir()).toBe(join(homedir(), 'knowledge'));
  });
});

// Bug-class guard: no source file may read `process.env.HOME` for path
// resolution again. os.homedir() is the only sanctioned cross-OS primitive
// (see brain-paths.ts). This fails loudly if a future tool reintroduces the
// Windows CWD-relative-`.second-brain` footgun. brain-paths.ts itself is
// exempt (its doc comment names the antipattern); test files are excluded.
describe('source guard: no direct process.env.HOME path resolution', () => {
  it('no non-test source file references process.env.HOME', () => {
    const srcDir = join(fileURLToPath(new URL('.', import.meta.url)));
    const files = globSync('**/*.ts', { cwd: srcDir, absolute: true })
      .filter((f) => !f.endsWith('.test.ts') && !f.endsWith('brain-paths.ts'));
    const offenders = files.filter((f) =>
      readFileSync(f, 'utf-8').includes('process.env.HOME')
    );
    expect(offenders, `process.env.HOME found in: ${offenders.join(', ')}`).toEqual([]);
  });

  // Constitution single-source guard: brain-dir resolution lives ONLY in brain-paths.ts.
  // Any other file embedding the literal '.second-brain' is re-implementing the resolver —
  // the copy-paste antipattern that produced the 0.33.17 stray-folder bug across ~21 sites.
  it('no non-test source file constructs a .second-brain path (single-source resolution)', () => {
    const srcDir = join(fileURLToPath(new URL('.', import.meta.url)));
    const files = globSync('**/*.ts', { cwd: srcDir, absolute: true })
      .filter((f) => !f.endsWith('.test.ts') && !f.endsWith('brain-paths.ts'));
    // Match a STRING LITERAL starting with `.second-brain` (resolver construction such as
    // join(homedir(), '.second-brain')) — NOT prose/doc mentions of `~/.second-brain`.
    const RESOLVER_RE = /['"`]\.second-brain/;
    const offenders = files.filter((f) => RESOLVER_RE.test(readFileSync(f, 'utf-8')));
    expect(offenders, `.second-brain resolver literal found in: ${offenders.join(', ')}`).toEqual([]);
  });

  // Knowledge-dir single-source guard (0.33.38): server.ts and dream.ts each carried a
  // local resolveKnowledgeDir with the OPPOSITE precedence to brain-paths (env over
  // plugin option), so the server and its tools could read two different wikis. Any
  // re-implementation signature — a same-named local function, a read of the plugin
  // option var, or a fallback-chain read of KNOWLEDGE_DIR — must live in brain-paths.ts
  // only. (A bare required-arg read like graph-neighbors-cli's `process.env.KNOWLEDGE_DIR;`
  // followed by exit-if-unset is not a resolution chain and stays allowed.)
  it('no non-test source file re-implements knowledge-dir resolution (single-source)', () => {
    const srcDir = join(fileURLToPath(new URL('.', import.meta.url)));
    const files = globSync('**/*.ts', { cwd: srcDir, absolute: true })
      .filter((f) => !f.endsWith('.test.ts') && !f.endsWith('brain-paths.ts'));
    const RE = /function\s+resolveKnowledgeDir|process\.env\.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR|process\.env\.KNOWLEDGE_DIR\s*(\|\||\?\?)/;
    const offenders = files.filter((f) => RE.test(readFileSync(f, 'utf-8')));
    expect(offenders, `local knowledge-dir resolution found in: ${offenders.join(', ')}`).toEqual([]);
  });
});
