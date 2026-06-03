# SP-1 — Project-Scoped Serving Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** `knowledge_search` serves the active project's knowledge + shared first (scoped-first), broadening to other projects only when the scoped result is thin — and the per-prompt persona injection inherits it via the CLI.

**Architecture:** A pure reorder+filter at the end of `knowledgeSearch` (after all boosts, before the existing top-K cut): classify each scored candidate into tiers (project / neighbourhood / shared / other-project), sort scoped tiers first, and drop other-project pages unless in-scope hits are below a threshold. Two small pure helpers (`graphNeighbourhood`, `clampEnvInt`). The search CLI forwards `SB_ACTIVE_SLUG`/`BRAIN_DIR` so the persona hook is scoped too. Spec: `docs/specs/2026-06-03-project-scoped-serving-design.md`.

**Tech Stack:** TypeScript (MCP server, vitest); two bash one-liners (hooks export the slug).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `mcp/src/tools/knowledge-search.ts` | scoped-first reorder + 2 helpers | Modify |
| `mcp/src/tools/knowledge-search.test.ts` | scoping test matrix | Modify |
| `mcp/src/tools/knowledge-search-cli.ts` | forward project context to the search | Modify |
| `scripts/persona-context.sh` | export `SB_ACTIVE_SLUG` before the search CLI | Modify (1 line) |
| `scripts/session-load.sh` | export `SB_ACTIVE_SLUG` if it calls the search CLI | Modify (only if it calls the CLI) |

---

## Task 1: Scoped-first reorder in `knowledgeSearch`

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts`
- Test: `mcp/src/tools/knowledge-search.test.ts`

- [ ] **Step 1: Write the failing tests** — append to `knowledge-search.test.ts` (it already imports `knowledgeSearch`, `appendEdge`, and has a `wiki()`/`slugs()` helper):

```typescript
describe('SP-1 project-scoped serving', () => {
  async function scopedWiki(): Promise<string> {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-scope-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    const w = (s: string, project: string, body: string) =>
      fsp.writeFile(join(dir, 'wiki', 'learnings', `${s}.md`),
        `---\ntitle: ${s}\ntype: learnings\n${project ? `project: ${project}\n` : ''}description: ${body}\n---\n\n# ${s}\n\n${body} ${'detail '.repeat(40)}\n`);
    await w('a1', 'alpha', 'wireguard tunnel keyword');
    await w('a2', 'alpha', 'wireguard tunnel keyword');
    await w('b1', 'beta', 'wireguard tunnel keyword');
    await w('s1', '', 'wireguard tunnel keyword');           // shared (no facet)
    await w('n1', '', 'wireguard tunnel keyword');           // untagged, will be graph-linked to a1
    return dir;
  }

  it('in project alpha, returns alpha + shared first and excludes beta (in-scope strong)', async () => {
    const dir = await scopedWiki();
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const s = slugs(r);
    expect(s).toContain('a1'); expect(s).toContain('a2'); expect(s).toContain('s1');
    expect(s).not.toContain('b1');   // other-project suppressed (>=3 in-scope hits)
  });

  it('auto-broadens to other-project when in-scope is thin', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-broaden-'));
    await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'b1.md'),
      `---\ntitle: b1\ntype: learnings\nproject: beta\n---\n\n# b1\n\nwireguard tunnel ${'x '.repeat(40)}\n`);
    // querying in alpha (no alpha/shared page matches) → must still return b1 (broadened, not hidden)
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    expect(slugs(r)).toContain('b1');
  });

  it('neighbourhood: a graph-linked untagged page ranks in-scope (above an unrelated other-project page)', async () => {
    const dir = await scopedWiki();
    // add a project:gamma page that also matches, and link n1<->a1 in the graph
    await fsp.writeFile(join(dir, 'wiki', 'learnings', 'g1.md'),
      `---\ntitle: g1\ntype: learnings\nproject: gamma\ndescription: wireguard tunnel keyword\n---\n\n# g1\n\nwireguard tunnel keyword ${'detail '.repeat(40)}\n`);
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a1', to: 'n1', type: 'relates', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    const s = slugs(r);
    expect(s).toContain('n1');                    // neighbour pulled in-scope
    expect(s.indexOf('n1')).toBeLessThan(s.indexOf('g1') === -1 ? 999 : s.indexOf('g1')); // n1 (T2) before g1 (other-project)
  });

  it('scope:"all" and SB_PROJECT_SCOPE=off restore global ranking (beta included)', async () => {
    const dir = await scopedWiki();
    const all = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir, scope: 'all' });
    expect(slugs(all)).toContain('b1');
    process.env.SB_PROJECT_SCOPE = 'off';
    const off = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir, projectSlug: 'alpha', brainDir: dir });
    delete process.env.SB_PROJECT_SCOPE;
    expect(slugs(off)).toContain('b1');
  });

  it('back-compat: no projectSlug → unchanged global behaviour (beta present)', async () => {
    const dir = await scopedWiki();
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    expect(slugs(r)).toContain('b1');
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`cd mcp && npx vitest run src/tools/knowledge-search.test.ts`) on "excludes beta" (beta not yet suppressed).

- [ ] **Step 3a: Add the two pure helpers** near the other top-level helpers in `knowledge-search.ts` (e.g. after `aiBlockText`):

```typescript
/** Parse an env int with a default + clamp; tolerant of unset/garbage. */
function clampEnvInt(name: string, def: number, lo: number, hi: number): number {
  const n = parseInt(process.env[name] ?? '', 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : def;
}

/** Slugs reachable within `hops` undirected graph hops from any seed slug (excludes nothing —
 *  seeds themselves are classified tier-1 by the caller regardless). Empty when no graph. */
function graphNeighbourhood(seeds: string[], edges: CurrentEdge[], hops: number): Set<string> {
  const adj = new Map<string, string[]>();
  for (const e of edges) for (const [a, b] of [[e.from, e.to], [e.to, e.from]] as [string, string][]) {
    if (!adj.has(a)) adj.set(a, []);
    adj.get(a)!.push(b);
  }
  const reached = new Set<string>(seeds);
  let frontier = [...seeds];
  for (let h = 0; h < hops; h++) {
    const next: string[] = [];
    for (const node of frontier) for (const to of adj.get(node) ?? []) if (!reached.has(to)) { reached.add(to); next.push(to); }
    frontier = next;
  }
  return reached;
}
```

- [ ] **Step 3b: Add `tier` to each scored item.** In the `scored = allDocs.map(...)` object literal, add a field (initialised 0 = "no scoping"):

```typescript
  const scored = allDocs.map(({ doc, rawContent, source, tokens }) => ({
    path: doc.path,
    tier: 0,
    score: scoreBM25(queryTokens, doc, avgDL, N, dfMap),
    related: doc.related,
    description: (doc.aiBlock && Object.keys(doc.aiBlock).length)
      ? aiBlockSnippet(doc.type, doc.aiBlock).slice(0, SNIPPET_CHARS)
      : (source === 'local-doc'
        ? doc.description
        : (doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim())),
    tokens,
    source,
  }));
```

- [ ] **Step 3c: Replace the final sort + cut** (the `scored.sort((a, b) => b.score - a.score); const topScore = ...; const candidates = scored.filter(...).slice(0, TOP_K).map(({ related, ...rest }) => rest);` block) with:

```typescript
  // --- SP-1 project-scoped serving (scoped-first, auto-broaden). Pure reorder + filter. ---
  const scopeOn = !!args.projectSlug && process.env.SB_PROJECT_SCOPE !== 'off' && args.scope !== 'all';
  if (scopeOn) {
    const slug = args.projectSlug!;
    const projBySlug = new Map(allDocs.map(d => [slugFromPath(d.doc.path), d.doc.project ?? '']));
    const anchors = allDocs.filter(d => (d.doc.project ?? '') === slug).map(d => slugFromPath(d.doc.path));
    const neigh = graphNeighbourhood(anchors, graphEdges, clampEnvInt('SB_SCOPE_HOPS', 2, 0, 4));
    for (const s of scored) {
      const sl = slugFromPath(s.path);
      const proj = projBySlug.get(sl) ?? '';
      s.tier = proj === slug ? 1 : neigh.has(sl) ? 2 : proj === '' ? 3 : 4;
    }
  }

  scored.sort((a, b) => (scopeOn ? (a.tier - b.tier) || (b.score - a.score) : b.score - a.score));
  const topScore = scored.reduce((m, s) => Math.max(m, s.score), 0);
  const passesFloor = (c: { score: number }) => c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO);

  let pool = scored;
  if (scopeOn) {
    const inScope = scored.filter(s => s.tier <= 3);
    const strong = inScope.filter(passesFloor);
    // Enough in-scope hits → drop other-project (tier 4). Thin → broaden (keep all; in-scope already sorted first).
    pool = strong.length >= clampEnvInt('SB_SCOPE_MIN_HITS', 3, 0, 100) ? inScope : scored;
  }

  const candidates = pool
    .filter(passesFloor)
    .slice(0, TOP_K)
    .map(({ related, tier, ...rest }) => rest);
```

- [ ] **Step 4: Run — expect PASS** (`cd mcp && npx vitest run src/tools/knowledge-search.test.ts` → all green, incl. the existing graph-boost + back-compat cases).
- [ ] **Step 5: Commit** — `git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts && git commit -m "feat(kb): project-scoped search — scoped-first + auto-broaden (SP-1 Task 1)"`.

## Task 2: Wire project context through the search CLI (scope the persona injection)

**Files:**
- Modify: `mcp/src/tools/knowledge-search-cli.ts`
- Modify: `scripts/persona-context.sh`
- Test: extend `tests/test-persona-capability-awareness.sh`? No — add a focused `tests/test-search-cli-scope.sh`.

- [ ] **Step 1: Write the failing test** — `tests/test-search-cli-scope.sh`:

```bash
#!/bin/bash
# Guard: the search CLI forwards project context (SB_ACTIVE_SLUG + BRAIN_DIR) so the per-prompt
# persona injection is project-scoped, and persona-context.sh exports SB_ACTIVE_SLUG.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node"; exit 0; }
[ -f "$CLI" ] || { echo "SKIP: CLI bundle not built"; exit 0; }
# the CLI source must read SB_ACTIVE_SLUG + BRAIN_DIR and pass projectSlug/brainDir
grep -q 'SB_ACTIVE_SLUG' "$ROOT/mcp/src/tools/knowledge-search-cli.ts" || fail "CLI does not read SB_ACTIVE_SLUG"
grep -q 'projectSlug' "$ROOT/mcp/src/tools/knowledge-search-cli.ts" || fail "CLI does not pass projectSlug"
pass "search CLI forwards project context"
# persona-context.sh exports SB_ACTIVE_SLUG before invoking the search CLI
grep -q 'SB_ACTIVE_SLUG' "$ROOT/scripts/persona-context.sh" || fail "persona-context.sh does not export SB_ACTIVE_SLUG"
pass "persona-context.sh exports SB_ACTIVE_SLUG"
# functional: a project:beta page is suppressed when SB_ACTIVE_SLUG=alpha + enough alpha hits
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
for s in a1 a2 a3; do printf '%s\n' '---' "title: $s" 'type: learnings' 'project: alpha' '---' "# $s" "wireguard tunnel keyword $(printf 'd %.0s' $(seq 1 40))" > "$KD/wiki/learnings/$s.md"; done
printf '%s\n' '---' 'title: b1' 'type: learnings' 'project: beta' '---' '# b1' "wireguard tunnel keyword $(printf 'd %.0s' $(seq 1 40))" > "$KD/wiki/learnings/b1.md"
OUT=$(KNOWLEDGE_DIR="$KD" BRAIN_DIR="$TMP/.second-brain" SB_ACTIVE_SLUG="alpha" node "$CLI" "wireguard tunnel" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'b1' && fail "beta page not suppressed under SB_ACTIVE_SLUG=alpha"
printf '%s' "$OUT" | grep -qE 'a1|a2|a3' || fail "alpha pages missing"
pass "CLI scopes to the active project (beta suppressed, alpha kept)"
rm -rf "$TMP"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL** (`bash tests/test-search-cli-scope.sh`) → "CLI does not read SB_ACTIVE_SLUG".

- [ ] **Step 3a: Edit `mcp/src/tools/knowledge-search-cli.ts`** — replace the `knowledgeSearch({ query, knowledgeDir })` call:

```typescript
const knowledgeDir = process.env.KNOWLEDGE_DIR || undefined;
const brainDir = process.env.BRAIN_DIR || (process.env.HOME ? `${process.env.HOME}/.second-brain` : undefined);
const projectSlug = process.env.SB_ACTIVE_SLUG || undefined;
// ... (minScore unchanged) ...
const result = await knowledgeSearch({ query, knowledgeDir, brainDir, projectSlug });
```

- [ ] **Step 3b: Edit `scripts/persona-context.sh`** — it already resolves the active slug? It writes `$slug` to `.active-session-slug` in `session-load.sh`, but `persona-context.sh` may not compute it. Add, just before the `node "$SEARCH_CLI"` invocation:

```bash
# SP-1: scope the per-prompt wiki injection to the active project (read the slug session-load pinned).
SB_ACTIVE_SLUG_VAL=$(cat "$BRAIN_DIR/.active-session-slug" 2>/dev/null || true)
```

and change the search-CLI invocation line to export it:

```bash
  WIKI_RAW=$(KNOWLEDGE_DIR="$KD" KNOWLEDGE_MIN_SCORE="$WIKI_MIN_SCORE" BRAIN_DIR="$BRAIN_DIR" SB_ACTIVE_SLUG="$SB_ACTIVE_SLUG_VAL" \
    node "$SEARCH_CLI" "$KEYWORDS" 2>/dev/null || true)
```

- [ ] **Step 4: Build + run** — `cd mcp && npm run build && cd .. && bash tests/test-search-cli-scope.sh` → ALL PASS.
- [ ] **Step 5: Commit** — `git add mcp/src/tools/knowledge-search-cli.ts scripts/persona-context.sh tests/test-search-cli-scope.sh && git commit -m "feat(kb): scope the per-prompt persona injection to the active project (SP-1 Task 2)"`.

## Task 3: Build + suite + release

- [ ] **Step 1:** `cd mcp && npm run build` (knowledge-search + CLI bundles).
- [ ] **Step 2:** `bash tests/run-all.sh` → ALL GREEN (known `test-lib-extractor-backend` flake aside — confirm standalone).
- [ ] **Step 3:** Deep-review gate — `/second-brain:code-review-deep` on the branch; fix confirmed findings.
- [ ] **Step 4:** Version bump 0.24.8 → 0.24.9 (`plugin.json` + `marketplace.json` + `server.ts` knowledge-base 2.6.3 → 2.6.4, since `knowledge-search` behaviour changed); `0.24.9` upgrade migration row (project-scoped serving; kill switch `SB_PROJECT_SCOPE=off`, `scope:"all"` override; no state migration).
- [ ] **Step 5:** Commit + open PR + merge.

---

## Self-Review

- **Spec coverage:** tier model (T1/T2/T3/OUT) ✔ Task 1 Step 3c; scoped-first + auto-broaden + `SB_SCOPE_MIN_HITS` ✔; neighbourhood via graph (`SB_SCOPE_HOPS`) ✔ helper; kill switch `SB_PROJECT_SCOPE=off` + `scope:"all"` ✔; CLI wiring so persona injection is scoped (spec §6) ✔ Task 2; back-compat (no projectSlug → unchanged) ✔ Task 1 test + the `scopeOn` guard; episodic out of scope ✔ (untouched).
- **Placeholder scan:** none — exact TS/bash/commands throughout.
- **Type/name consistency:** `tier` added to the scored literal AND stripped in the final `.map(({ related, tier, ...rest }))`; `clampEnvInt`/`graphNeighbourhood`/`scopeOn`/`passesFloor` used as defined; env names `SB_PROJECT_SCOPE`/`SB_SCOPE_MIN_HITS`/`SB_SCOPE_HOPS`/`SB_ACTIVE_SLUG` identical across TS, bash, and tests.
