# Local Doc-Sources — Phase 1: registry core (`doc-sources.ts`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the deterministic, testable core of local doc-source tracking: a `doc-sources.ts` module that reads a per-project config, scans the declared locations (honoring `.gitignore`), extracts a gist + headings + content-hash per file, and produces/loads a per-project registry. Lifecycle (move/remove) is realized implicitly by re-scanning the live FS with content-hash identity — no explicit diff.

**Architecture:** Pure functions where possible. `extractGist`/`extractHeadings`/`hashContent` are pure; `scanLocations` does FS + `git check-ignore` filtering; `buildRegistry`/`loadRegistry` read/write `~/.second-brain/projects/<slug>/doc-sources.json`. No LLM, no network. Spec: `docs/superpowers/specs/2026-05-24-local-doc-sources-design.md`.

**Tech Stack:** TypeScript (ESM, node20), Vitest, `glob` (dep), node `crypto` + `child_process` (stdlib). No new deps.

**Scope:** Phase 1 of 4 (spec §9). Phase 2 = CLI + SessionStart hook; Phase 3 = knowledge_search/fetch merge; Phase 4 = `/second-brain:track` skill.

**Build/test (from `mcp/`):** targeted `npx vitest run test/doc-sources.test.ts`; full `npm test`.
**Commit:** Conventional Commits; trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Commit directly to `main` (maintainer works main-only).

---

### Task 1: extraction helpers (pure)

**Files:** Create `mcp/src/tools/doc-sources.ts`; Test `mcp/test/doc-sources.test.ts`

- [ ] **Step 1: failing test** — `mcp/test/doc-sources.test.ts`:
```ts
import { describe, it, expect } from 'vitest';
import { extractGist, extractHeadings, hashContent } from '../src/tools/doc-sources.js';

describe('extractGist', () => {
  it('prefers the H1 heading', () => {
    expect(extractGist('---\ntitle: "FM"\n---\n# The H1\n\nbody')).toBe('The H1');
  });
  it('falls back to frontmatter title when no H1', () => {
    expect(extractGist('---\ntitle: "FM title"\n---\n\n## Sub\n')).toBe('FM title');
  });
  it('falls back to first non-empty line when neither', () => {
    expect(extractGist('\n\nFirst real line\nsecond')).toBe('First real line');
  });
});

describe('extractHeadings', () => {
  it('returns H2/H3 headings, not H1', () => {
    expect(extractHeadings('# Title\n## A\ntext\n### B\n#### C')).toEqual(['## A', '### B']);
  });
});

describe('hashContent', () => {
  it('is stable and content-sensitive', () => {
    expect(hashContent('abc')).toBe(hashContent('abc'));
    expect(hashContent('abc')).not.toBe(hashContent('abd'));
    expect(hashContent('abc')).toMatch(/^[0-9a-f]{64}$/);
  });
});
```

- [ ] **Step 2: run, expect FAIL** — `cd mcp && npx vitest run test/doc-sources.test.ts` (module missing).

- [ ] **Step 3: implement** — create `mcp/src/tools/doc-sources.ts`:
```ts
import { createHash } from 'crypto';

export function hashContent(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}

/** Gist = first H1 / frontmatter title / first non-empty line. Deterministic, no LLM. */
export function extractGist(content: string): string {
  const fm = content.match(/^---\n([\s\S]*?)\n---/);
  const body = fm ? content.slice(fm[0].length) : content;
  const h1 = body.match(/^#\s+(.+)$/m);
  if (h1) return h1[1].trim();
  if (fm) {
    const t = fm[1].match(/^title:\s*["']?(.+?)["']?\s*$/m);
    if (t) return t[1].trim();
  }
  const first = body.split('\n').map((l) => l.trim()).find((l) => l.length > 0);
  return first ?? '';
}

/** H2/H3 headings, in order (excludes the H1 title). */
export function extractHeadings(content: string): string[] {
  return content.split('\n').map((l) => l.trim()).filter((l) => /^#{2,3}\s+\S/.test(l));
}
```

- [ ] **Step 4: run, expect PASS** — `cd mcp && npx vitest run test/doc-sources.test.ts`.

- [ ] **Step 5: commit**
```bash
git add mcp/src/tools/doc-sources.ts mcp/test/doc-sources.test.ts
git commit -m "$(printf 'feat(doc-sources): gist/headings/hash extraction helpers (phase 1)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: config read + `.gitignore`-aware scan

**Files:** Modify `mcp/src/tools/doc-sources.ts`; Test `mcp/test/doc-sources.test.ts` (append)

- [ ] **Step 1: failing test** — append (add imports to the existing import line):
```ts
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import { readConfig, scanLocations } from '../src/tools/doc-sources.js';

describe('readConfig', () => {
  it('returns {locations:[]} when no config exists', async () => {
    const brain = mkdtempSync(join(tmpdir(), 'ds-b-'));
    expect((await readConfig(brain, 'proj')).locations).toEqual([]);
    rmSync(brain, { recursive: true, force: true });
  });
});

describe('scanLocations', () => {
  let root: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'ds-r-'));
    mkdirSync(join(root, 'docs'), { recursive: true });
    writeFileSync(join(root, 'docs', 'deploy.md'), '# Deploy\n\n## Steps\n\ndo it\n');
    writeFileSync(join(root, 'docs', 'secret.md'), '# Secret\n\ntoken\n');
  });
  afterEach(() => rmSync(root, { recursive: true, force: true }));

  it('scans a folder location into entries with gist+headings+hash', async () => {
    const entries = await scanLocations(root, ['docs/']);
    const deploy = entries.find((e) => e.rel === 'docs/deploy.md');
    expect(deploy).toBeDefined();
    expect(deploy!.gist).toBe('Deploy');
    expect(deploy!.headings).toEqual(['## Steps']);
    expect(deploy!.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(deploy!.id).toBe(deploy!.hash.slice(0, 12));
  });

  it('honors .gitignore (git repo) — ignored files are excluded', async () => {
    execFileSync('git', ['-C', root, 'init', '-q']);
    writeFileSync(join(root, '.gitignore'), 'docs/secret.md\n');
    const entries = await scanLocations(root, ['docs/']);
    expect(entries.some((e) => e.rel === 'docs/secret.md')).toBe(false);
    expect(entries.some((e) => e.rel === 'docs/deploy.md')).toBe(true);
  });
});
```

- [ ] **Step 2: run, expect FAIL** — `readConfig`/`scanLocations` not exported.

- [ ] **Step 3: implement** — append to `doc-sources.ts`:
```ts
import { promises as fs } from 'fs';
import { join, relative } from 'path';
import { spawnSync } from 'child_process';
import { glob } from 'glob';

export interface DocSourceConfig { locations: string[]; }
export interface DocEntry {
  id: string; path: string; rel: string; gist: string;
  headings: string[]; hash: string; mtime: string; size: number;
}

const JUNK_DIRS = new Set(['node_modules', '.git', '.venv', 'venv', '.next', 'dist', 'build']);

export async function readConfig(brainDir: string, slug: string): Promise<DocSourceConfig> {
  try {
    const j = JSON.parse(await fs.readFile(join(brainDir, 'projects', slug, 'doc-sources.config.json'), 'utf-8'));
    return { locations: Array.isArray(j.locations) ? j.locations : [] };
  } catch { return { locations: [] }; }
}

/** Drop junk dirs always; then drop git-ignored paths via `git check-ignore` when in a repo. */
function filterIgnored(projectRoot: string, absPaths: string[]): string[] {
  const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split('/').some((seg) => JUNK_DIRS.has(seg)));
  if (nonJunk.length === 0) return [];
  const rels = nonJunk.map((p) => relative(projectRoot, p));
  const res = spawnSync('git', ['-C', projectRoot, 'check-ignore', '--stdin'], { input: rels.join('\n'), encoding: 'utf-8' });
  // status 0 = some ignored (listed on stdout); 1 = none ignored; other (128/ENOENT) = not a repo / no git → junk-skip only
  if (res.status === 0 || res.status === 1) {
    const ignored = new Set((res.stdout || '').split('\n').filter(Boolean).map((r) => join(projectRoot, r)));
    return nonJunk.filter((p) => !ignored.has(p));
  }
  return nonJunk;
}

export async function scanLocations(projectRoot: string, locations: string[]): Promise<DocEntry[]> {
  const seen = new Set<string>();
  const absPaths: string[] = [];
  for (const loc of locations) {
    const pattern = /[*?[\]{}]/.test(loc) ? loc : `${loc.replace(/\/+$/, '')}/**/*.md`;
    const matches = await glob(pattern, { cwd: projectRoot, absolute: true, nodir: true }).catch(() => [] as string[]);
    for (const m of matches) if (!seen.has(m)) { seen.add(m); absPaths.push(m); }
  }
  const kept = filterIgnored(projectRoot, absPaths);
  const entries: DocEntry[] = [];
  for (const p of kept) {
    try {
      const content = await fs.readFile(p, 'utf-8');
      const st = await fs.stat(p);
      const hash = hashContent(content);
      entries.push({
        id: hash.slice(0, 12), path: p, rel: relative(projectRoot, p),
        gist: extractGist(content), headings: extractHeadings(content),
        hash, mtime: st.mtime.toISOString(), size: st.size,
      });
    } catch { /* unreadable — skip */ }
  }
  entries.sort((a, b) => a.path.localeCompare(b.path)); // deterministic order
  return entries;
}
```
Add `import { describe, it, expect, beforeEach, afterEach } from 'vitest';` coverage in the test file if not already importing `beforeEach`/`afterEach`.

- [ ] **Step 4: run, expect PASS** — `cd mcp && npx vitest run test/doc-sources.test.ts`. (The `.gitignore` test requires `git` on PATH; it is available in this repo's dev env.)

- [ ] **Step 5: commit**
```bash
git add mcp/src/tools/doc-sources.ts mcp/test/doc-sources.test.ts
git commit -m "$(printf 'feat(doc-sources): config read + gitignore-aware scan (phase 1)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: `buildRegistry` / `loadRegistry` + lifecycle behavior

Re-scanning the live FS with content-hash identity yields the spec's reconcile for free: a moved file keeps its `id`/`hash` with a new `path`; a removed file simply isn't in the new scan; an edited file gets a new hash. Tests assert that behavior.

**Files:** Modify `mcp/src/tools/doc-sources.ts`; Test `mcp/test/doc-sources.test.ts` (append)

- [ ] **Step 1: failing test** — append:
```ts
import { renameSync, unlinkSync } from 'fs';
import { buildRegistry, loadRegistry } from '../src/tools/doc-sources.js';

describe('buildRegistry / lifecycle', () => {
  let root: string; let brain: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'ds-pr-'));
    brain = mkdtempSync(join(tmpdir(), 'ds-bn-'));
    mkdirSync(join(brain, 'projects', 'proj'), { recursive: true });
    mkdirSync(join(root, 'docs'), { recursive: true });
    writeFileSync(join(brain, 'projects', 'proj', 'doc-sources.config.json'), JSON.stringify({ locations: ['docs/'] }));
    writeFileSync(join(root, 'docs', 'a.md'), '# Alpha\n\nbody\n');
  });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); rmSync(brain, { recursive: true, force: true }); });

  it('builds and loads a registry of the live files', async () => {
    const reg = await buildRegistry(root, brain, 'proj');
    expect(reg.project).toBe('proj');
    expect(reg.entries.map((e) => e.rel)).toEqual(['docs/a.md']);
    const loaded = await loadRegistry(brain, 'proj');
    expect(loaded!.entries).toEqual(reg.entries);
  });

  it('moved file keeps its id/hash with the new path', async () => {
    const r1 = await buildRegistry(root, brain, 'proj');
    const before = r1.entries[0];
    renameSync(join(root, 'docs', 'a.md'), join(root, 'docs', 'b.md'));
    const r2 = await buildRegistry(root, brain, 'proj');
    expect(r2.entries).toHaveLength(1);
    expect(r2.entries[0].rel).toBe('docs/b.md');
    expect(r2.entries[0].id).toBe(before.id);     // content-hash identity stable across move
    expect(r2.entries[0].hash).toBe(before.hash);
  });

  it('removed file drops out of the registry', async () => {
    await buildRegistry(root, brain, 'proj');
    unlinkSync(join(root, 'docs', 'a.md'));
    const r2 = await buildRegistry(root, brain, 'proj');
    expect(r2.entries).toEqual([]);
  });
});
```

- [ ] **Step 2: run, expect FAIL** — `buildRegistry`/`loadRegistry` not exported.

- [ ] **Step 3: implement** — append to `doc-sources.ts`:
```ts
export interface DocRegistry { generated_at: string; project: string; entries: DocEntry[]; }

function registryPath(brainDir: string, slug: string): string {
  return join(brainDir, 'projects', slug, 'doc-sources.json');
}

export async function loadRegistry(brainDir: string, slug: string): Promise<DocRegistry | null> {
  try { return JSON.parse(await fs.readFile(registryPath(brainDir, slug), 'utf-8')); }
  catch { return null; }
}

/** Scan the live FS (config-declared locations) and write the registry. The fresh
 *  scan IS the reconciled state: content-hash ids are stable across moves, removed
 *  files are simply absent, edits get a new hash. */
export async function buildRegistry(projectRoot: string, brainDir: string, slug: string): Promise<DocRegistry> {
  const { locations } = await readConfig(brainDir, slug);
  const entries = await scanLocations(projectRoot, locations);
  const reg: DocRegistry = { generated_at: new Date().toISOString(), project: slug, entries };
  const out = registryPath(brainDir, slug);
  await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
  const tmp = `${out}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(reg, null, 2));
  await fs.rename(tmp, out); // atomic
  return reg;
}
```

- [ ] **Step 4: run targeted + full suite** — `cd mcp && npx vitest run test/doc-sources.test.ts` → PASS; `cd mcp && npm test` → all green.

- [ ] **Step 5: commit**
```bash
git add mcp/src/tools/doc-sources.ts mcp/test/doc-sources.test.ts
git commit -m "$(printf 'feat(doc-sources): buildRegistry/loadRegistry with re-scan lifecycle (phase 1)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

## Definition of done (Phase 1)
- `mcp/src/tools/doc-sources.ts` exports `extractGist`, `extractHeadings`, `hashContent`, `readConfig`, `scanLocations`, `buildRegistry`, `loadRegistry`.
- `.gitignore` honored (git repos) with junk-skip fallback; move/remove correctness proven by tests.
- `cd mcp && npm test` green. No server wiring yet (Phase 2/3).

## Hand-off
- **Phase 2:** `doc-sources-cli.ts` (calls `buildRegistry`) + `scripts/discover-doc-sources.sh` SessionStart hook + esbuild bundle entry + `find -newer` fast-path.
- **Phase 3:** `knowledge_search` merges `loadRegistry(active project)` entries (BM25 over gist+headings, `source:"local-doc"`); `knowledge_fetch` resolves registry entries (full = read file, capped).
- **Phase 4:** `/second-brain:track` skill writes `doc-sources.config.json`.
