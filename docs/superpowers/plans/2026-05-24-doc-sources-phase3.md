# Local Doc-Sources — Phase 3: searchable via knowledge_search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Make local doc sources **show up in `knowledge_search`**, ranked alongside wiki pages and **scoped to the active project**, so when Claude searches for something that lives in a project's docs it gets the path + gist. This is the phase that makes the feature user-visible.

**Architecture:** Doc-source registry entries are merged into `knowledge_search`'s **unified candidate corpus *before* scoring** (not appended after) — this keeps them calibrated with the existing BM25 + ONNX-RRF fusion, which rewrites scores to a tiny scale when embeddings are on (a late raw-BM25 append would mis-rank). Each entry becomes a pseudo-doc (`description = gist`, `body = headings`), tagged `source:"local-doc"`, exempt from the stub-penalty (short bodies are expected) and from access-count recording. The active project slug is resolved server-side (T2) and passed in; when absent, behavior is byte-for-byte the old wiki-only path.

**Tech Stack:** TypeScript (ESM), Vitest. Reuses Phase-1 `loadRegistry` (which already rejects unsafe slugs → returns null).

**Build/test (from `mcp/`):** `npx vitest run test/knowledge-search.test.ts`; full `npm test`; build `npm run build`.
**Commit:** Conventional Commits + trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Commit to `main`.

**Scope:** Phase 3 of 4. `knowledge_fetch` doc-source resolution → **deferred to Phase 3b** (additive; Claude can `Read` the path from a search result already). Phase 4 = `/second-brain:track` skill.

---

### Task 1: merge registry entries into `knowledge_search` (unified corpus)

**Files:** Modify `mcp/src/tools/knowledge-search.ts`; Test `mcp/test/knowledge-search.test.ts` (append).

READ `knowledge-search.ts` first. The relevant anchors: `KnowledgeSearchArgs`/`KnowledgeSearchResult` (lines ~6-7), the `allDocs` collection + the wiki `for` loop (~71-83), `avgDL`/`N`/`dfMap`/`scored` (~87-98), the stub-penalty loop (`AUTO_EXTRACTED_RE`/`MIN_SUBSTANTIVE_LENGTH`), the final `candidates` map (`.map(({ related, ...rest }) => rest)`), and the access-recording loop. Integrate against the real code; if structure differs materially, report NEEDS_CONTEXT.

- [ ] **Step 1: failing tests** — append inside `describe('knowledge_search v1', ...)` (the suite already runs with embeddings disabled, so this exercises the BM25 path):
```ts
  it('surfaces an active-project local doc as a local-doc candidate', async () => {
    // brainDir with a registry for project 'proj' pointing at a doc
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain-'));
    mkdirSync(join(brainDir, 'projects', 'proj'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'proj', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'proj',
      entries: [{ id: 'abc123', path: '/abs/docs/deploy-runbook.md', rel: 'docs/deploy-runbook.md',
        gist: 'Deploy runbook for the cluster', headings: ['## Steps', '## Rollback'],
        hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 1200 }],
    }));
    const res = await knowledgeSearch({ query: 'deploy runbook cluster', knowledgeDir, brainDir, projectSlug: 'proj' });
    const hit = res.candidates.find(c => c.path === '/abs/docs/deploy-runbook.md');
    expect(hit).toBeDefined();
    expect(hit!.source).toBe('local-doc');
    expect(hit!.description).toBe('Deploy runbook for the cluster');
    expect(hit!.tokens).toBe(Math.ceil(1200 / 4));
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('does not leak another project\'s docs (scoping) and wiki results carry source:wiki', async () => {
    const brainDir = mkdtempSync(join(tmpdir(), 'ks-brain2-'));
    mkdirSync(join(brainDir, 'projects', 'other'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'other', 'doc-sources.json'), JSON.stringify({
      generated_at: 'x', project: 'other',
      entries: [{ id: 'x', path: '/abs/secret.md', rel: 'secret.md', gist: 'counting pipeline grep secret',
        headings: [], hash: 'h', mtime: '2026-05-24T00:00:00Z', size: 100 }],
    }));
    // active project is 'proj' (no registry) → 'other' must not appear
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir, brainDir, projectSlug: 'proj' });
    expect(res.candidates.some(c => c.path === '/abs/secret.md')).toBe(false);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
    rmSync(brainDir, { recursive: true, force: true });
  });

  it('is unchanged (wiki-only) when no brainDir/projectSlug given', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates.every(c => c.source === 'wiki')).toBe(true);
  });
```
(Ensure the test file imports `mkdtempSync, mkdirSync, rmSync, writeFileSync` from 'fs', `join` from 'path', `tmpdir` from 'os' — add any missing.)

- [ ] **Step 2: run, expect FAIL** — `cd mcp && npx vitest run test/knowledge-search.test.ts` (`source` undefined; doc not surfaced; `brainDir`/`projectSlug` not in args type → TS error is also an acceptable red).

- [ ] **Step 3: implement** in `knowledge-search.ts`:

(a) import at top: `import { loadRegistry } from './doc-sources.js';`

(b) extend args + result types:
```ts
export interface KnowledgeSearchArgs { query: string; scope?: string; knowledgeDir?: string; brainDir?: string; projectSlug?: string; }
export interface KnowledgeSearchResult { candidates: { path: string; score: number; description: string; tokens: number; source: string }[]; }
```

(c) change the `allDocs` declaration to carry source + precomputed tokens:
```ts
  const allDocs: { doc: ParsedDoc; rawContent: string; source: 'wiki' | 'local-doc'; tokens: number }[] = [];
```
and the wiki push inside the scope loop becomes:
```ts
        allDocs.push({ doc, rawContent: content, source: 'wiki', tokens: estimateTokens(content) });
```

(d) **immediately after the wiki collection loop, before** the `if (allDocs.length === 0)` check, merge the active project's registry (so it joins the corpus used for avgDL/N/dfMap/scoring/RRF):
```ts
  if (args.brainDir && args.projectSlug) {
    const reg = await loadRegistry(args.brainDir, args.projectSlug); // rejects unsafe slug → null
    for (const e of reg?.entries ?? []) {
      const doc: ParsedDoc = {
        title: '', description: e.gist, type: 'local-doc', tags: [],
        related: [], body: e.headings.join('\n'), path: e.path,
        updated: e.mtime, created: e.mtime,
      };
      allDocs.push({ doc, rawContent: `${e.gist}\n${e.headings.join('\n')}`, source: 'local-doc', tokens: Math.ceil(e.size / 4) });
    }
  }
```

(e) update the `scored` map to use the tuple's `source`/`tokens` and keep local-doc description = gist:
```ts
  const scored = allDocs.map(({ doc, rawContent, source, tokens }) => ({
    path: doc.path,
    score: scoreBM25(queryTokens, doc, avgDL, N, dfMap),
    related: doc.related,
    description: source === 'local-doc'
      ? doc.description
      : (doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim()),
    tokens,
    source,
  }));
```

(f) in the **stub-penalty loop**, skip local-doc (short heading bodies are expected, not stubs). At the top of that loop body add:
```ts
    if (allDocs[i].source === 'local-doc') continue;
```

(g) the final candidates `.map(({ related, ...rest }) => rest)` already passes `source` through — no change.

(h) in the **access-recording loop**, skip local-doc (they have no wiki slug):
```ts
  for (const c of candidates) {
    if (c.source === 'local-doc') continue;
    // ...existing body...
  }
```

- [ ] **Step 4: run targeted + full** — `cd mcp && npx vitest run test/knowledge-search.test.ts` → PASS (new 3 + all existing, incl. the Phase-2 `description`/`tokens` tests); `cd mcp && npm test` → all green.

- [ ] **Step 5: commit**
```bash
git add mcp/src/tools/knowledge-search.ts mcp/test/knowledge-search.test.ts
git commit -m "$(printf 'feat(doc-sources): merge project doc registry into knowledge_search (phase 3)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: server wiring (resolve active slug) + rebuild bundle

`knowledgeSearch` only merges docs when given `brainDir`+`projectSlug`. The MCP server must resolve the active project the same way the hooks do (pin-aware, else `basename(cwd)`) and pass them.

**Files:** Modify `mcp/src/server.ts`; rebuild `mcp/dist`.

- [ ] **Step 1: add a slug resolver + BRAIN_DIR in `server.ts`.** Near the existing `BRAIN_DIR` constant (there is already `const BRAIN_DIR = path.join(os.homedir(), '.second-brain');` further down — reuse it; if it's declared after the knowledge_search registration, hoist a `const BRAIN_DIR = ...` up near `KNOWLEDGE_DIR` so it's in scope, and remove the duplicate). Add:
```ts
function resolveActiveSlug(): string | undefined {
  // Mirror scripts/lib.sh sb_resolve_slug: prefer the pin (if its PROJECT.md exists), else basename(cwd).
  try {
    const pin = fs.readFileSync(path.join(BRAIN_DIR, '.active-session-slug'), 'utf-8').trim();
    if (pin && fs.existsSync(path.join(BRAIN_DIR, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  const base = path.basename(process.cwd());
  return base && base !== '/' ? base : undefined;
}
```
(`fs`, `path`, `os` are already imported in server.ts.)

- [ ] **Step 2: pass them in the `knowledge_search` handler.** Change the `knowledgeSearch({ query, scope, knowledgeDir: KNOWLEDGE_DIR })` call to:
```ts
      const result = await knowledgeSearch({ query, scope, knowledgeDir: KNOWLEDGE_DIR, brainDir: BRAIN_DIR, projectSlug: resolveActiveSlug() });
```

- [ ] **Step 3: type-check + build** — `cd mcp && npm run build`. Expect `tsc` exit 0; bundles regenerate.

- [ ] **Step 4: verify the wiring is in the bundle** —
```bash
cd mcp && grep -q 'resolveActiveSlug' dist/server.bundle.js && echo "wiring in bundle"
```
Expected: `wiring in bundle`.

- [ ] **Step 5: full suite** — `cd mcp && npm test` → all green (server isn't unit-tested; the knowledgeSearch unit tests from T1 cover the merge logic; this step guards no regressions + the build).

- [ ] **Step 6: commit (source + regenerated dist)**
```bash
git add mcp/src/server.ts mcp/dist
git commit -m "$(printf 'feat(doc-sources): server resolves active slug + passes it to knowledge_search (phase 3)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

## Definition of done (Phase 3)
- `knowledge_search` returns active-project local docs as `source:"local-doc"` candidates, ranked in the unified BM25/RRF corpus, with `description`=gist, `tokens` from size; another project's docs do not leak; wiki-only behavior is unchanged when no `brainDir`/`projectSlug`.
- Server resolves the active slug (pin-aware) and passes it; bundle rebuilt.
- `cd mcp && npm test` green. **Doc sources are now user-visible end-to-end** (declare in config → SessionStart scan builds registry → search surfaces them).

## Hand-off
- **Phase 3b (small):** `knowledge_fetch` resolves a doc-source entry (by `rel`/`id`/abs-path) → gist/skeleton from registry, full = read file GUARD-capped, vanished-file defensive.
- **Phase 4:** `/second-brain:track` skill to declare locations (until then, hand-write `doc-sources.config.json`).
