# Consolidation v2 (community summaries + reconciliation) — Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. Spec: `docs/specs/2026-06-01-dream-consolidation-v2-design.md`.

**Goal:** (B1) the **dream** generates whole-corpus theme pages by deterministically clustering the staging wiki link graph (label propagation) and LLM-summarizing each cluster; (B2) the **live `knowledge-maintainer`** dedups/merges/supersedes pages with retrieval grounding (`knowledge_search` top-k) and a deterministic, explicitly-enumerated SUPERSEDE edge loop.

**Split by execution context (load-bearing):** edge writes live on the **live maintainer** (the dream provably cannot touch `graph/edges.jsonl`); theme pages live in the **dream staging** copy (applied on `dream_accept`). The dream-runner cannot run `node` → the cluster CLI is reached via a `scripts/*.sh` shim.

**Tech stack:** TypeScript (ESM, Node 20, vitest, esbuild bundle) for clustering; Bash for the shim, FORGET, and dream/maintainer wiring; `tests/test-*.sh` + colocated vitest.

**Phases (each ships working, testable software):**
- **A** — `graph-cluster.ts` core (TS pure logic + vitest): deterministic label propagation. The foundation.
- **B** — `graph-cluster-cli.ts` + bundle + `scripts/graph-cluster.sh` shim.
- **C** — dream `SUMMARIZE` phase (SKILL.md + dream-runner.md insertion) + theme-page generation + `tests/test-dream-summarize.sh`.
- **D** — FORGET protection for `themes` (`wiki-forget-score.sh`).
- **E** — B2 reconciliation in `knowledge-maintainer` (retrieval-grounded dedup + deterministic SUPERSEDE).
- **F** — `knowledge-validate` theme awareness + `session-load` theme surfacing.
- **G** — version bump (MCP 2.3.1), migration, gate.

**Conventions (verified):**
- vitest colocated `mcp/src/tools/<name>.test.ts`; run `cd mcp && npm run test -- <name>`.
- Shell tests `tests/test-<name>.sh` (`set -u`, `fail()`/`pass()`, `mktemp -d`, `trap`); auto-discovered by `tests/run-all.sh`.
- Every new bundled CLI **must** be appended to the `bundle` script in `mcp/package.json`.
- MCP path safety: validate slug args with `validateSlug` from `src/path-guard.js`.
- `SB_DREAM_SUMMARIZE=off` / `SB_RECONCILE=off` ⇒ byte-for-byte 0.22.x. Commit after each green task.

---

## Phase A — `graph-cluster.ts` core (deterministic label propagation)

The determinism contract (spec §B1.1) is the load-bearing claim. Build it test-first; the headline test shuffles the input.

**Files:** Create `mcp/src/tools/graph-cluster.ts`, `mcp/src/tools/graph-cluster.test.ts`.

### Task A1: `buildAdjacency` from page links

- [ ] **Step 1: failing test**

```ts
import { describe, it, expect } from 'vitest';
import { buildAdjacency } from './graph-cluster.js';

describe('buildAdjacency', () => {
  it('builds an undirected adjacency from related: + body links, deduped', () => {
    const pages = [
      { slug: 'a', related: ['b'], bodyLinks: ['c'] },
      { slug: 'b', related: ['a'], bodyLinks: [] },
      { slug: 'c', related: [], bodyLinks: ['a'] },
    ];
    const adj = buildAdjacency(pages);
    expect([...adj.get('a')!].sort()).toEqual(['b', 'c']);   // undirected: a-c from either side, once
    expect([...adj.get('c')!]).toEqual(['a']);
  });
});
```

- [ ] **Step 2:** `cd mcp && npm run test -- graph-cluster` → FAIL (module missing).
- [ ] **Step 3: impl** — `export interface ClusterPage { slug: string; related: string[]; bodyLinks: string[] }`; `buildAdjacency(pages): Map<string, Set<string>>` — for each page, add undirected edges `slug↔neighbor` for every neighbor in `related ∪ bodyLinks` that is itself a known slug; ignore self-loops and unknown slugs.
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(cluster): buildAdjacency from page links`.

### Task A2: `labelPropagate` — deterministic (the headline)

- [ ] **Step 1: failing test** (spec test #1, #2):

```ts
import { labelPropagate } from './graph-cluster.js';

function adjOf(edges: [string,string][]): Map<string,Set<string>> {
  const m = new Map<string,Set<string>>();
  const add = (x:string,y:string)=>{ (m.get(x) ?? m.set(x,new Set()).get(x)!).add(y); };
  for (const [x,y] of edges){ add(x,y); add(y,x); }
  return m;
}

describe('labelPropagate (deterministic)', () => {
  const barbell: [string,string][] = [['a','b'],['b','c'],['a','c'], ['x','y'],['y','z'],['x','z'], ['c','x']];
  it('partitions a barbell into two communities', () => {
    const r = labelPropagate(adjOf(barbell));
    const comm = (s:string)=> r.get(s)!;
    expect(comm('a')).toBe(comm('b')); expect(comm('b')).toBe(comm('c'));
    expect(comm('x')).toBe(comm('y')); expect(comm('y')).toBe(comm('z'));
    expect(comm('a')).not.toBe(comm('z'));
  });
  it('is byte-identical across repeated runs AND shuffled insertion order', () => {
    const a1 = labelPropagate(adjOf(barbell));
    const shuffled = adjOf([...barbell].reverse().map(([u,v])=>[v,u] as [string,string]));
    const a2 = labelPropagate(shuffled);
    const norm = (m:Map<string,string>)=> [...m.entries()].sort().map(([k,v])=>`${k}:${v}`).join(',');
    expect(norm(a1)).toBe(norm(a2));   // shuffle-invariant => no visit-order leakage
  });
});
```

- [ ] **Step 2:** FAIL.
- [ ] **Step 3: impl** — `labelPropagate(adj, opts?: {maxIter?: number}): Map<string,string>` per spec §B1.1:
  - init each node's label = its own slug;
  - **synchronous rounds**: compute every node's next label from the **previous** round's labels; iterate nodes in **lexicographic slug order**;
  - next label = plurality of neighbor labels; **tie-break** = keep own current label if it is among the tied plurality, else the **smallest slug** among tied labels;
  - stop when a round changes nothing or at `maxIter` (default 20);
  - normalize: a community's canonical id = the smallest slug among its members (relabel at the end so labels ARE the min-slug).
- [ ] **Step 4:** PASS (incl. shuffle-invariance). **Step 5: Commit** — `feat(cluster): deterministic synchronous label propagation`.

### Task A3: `assignNewNode` (incremental)

- [ ] **Step 1: failing test** (spec test #3): a node linked to 2 nodes of community A and 1 of B → assigned A, without re-running global propagation.
- [ ] **Step 3: impl** — `assignNewNode(adj, labels, node): string` — single synchronous step over the node's neighbors' current labels, same tie-break.
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(cluster): incremental assignNewNode`.

### Task A4: `clusters` + content-aware `member_hash`

- [ ] **Step 1: failing test** (spec test #4, #5):

```ts
import { clusters, memberHash } from './graph-cluster.js';
describe('clusters + memberHash', () => {
  it('groups by community and drops clusters below minSize', () => {
    const labels = new Map(Object.entries({a:'a',b:'a',c:'a',d:'a', x:'x',y:'x'}));
    const cs = clusters(labels, { minSize: 4 });
    expect(cs.map(c=>c.id)).toEqual(['a']);                  // {x,y} dropped (size 2 < 4)
    expect(cs[0].members.sort()).toEqual(['a','b','c','d']);
  });
  it('memberHash changes when a member content-hash changes at stable membership', () => {
    const m = ['a','b'];
    const h1 = memberHash(m, { a: 'h1', b: 'h2' });
    const h2 = memberHash(m, { a: 'h1', b: 'CHANGED' });
    expect(h1).not.toBe(h2);                                 // content-aware, not set-only
  });
});
```

- [ ] **Step 3: impl** — `clusters(labels, {minSize})` → `{id, members[]}[]`; `memberHash(sortedMembers, contentHashBySlug)` = a **self-contained** stable hash (e.g. djb2) over `sortedMembers.join('|') + '::' + sortedMembers.map(s=>contentHashBySlug[s]).join('|')`. **Do not** import `embeddings.ts`'s `simpleHash` (unexported, truncated). The caller supplies per-member content hashes (full file bytes).
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(cluster): clusters + content-aware memberHash`.

---

## Phase B — CLI + shim

**Files:** Create `mcp/src/tools/graph-cluster-cli.ts`, `scripts/graph-cluster.sh`; modify `mcp/package.json` (`bundle` script).

### Task B1: `graph-cluster-cli.ts`

- [ ] **Step 1:** CLI reads a staging wiki dir (arg or `KNOWLEDGE_DIR`), parses each page's frontmatter `related:` + body `[[links]]` (reuse `parseDoc`-style extraction), runs `buildAdjacency`→`labelPropagate`→`clusters({minSize: SB_SUMMARIZE_MIN_CLUSTER})`, and prints JSON `[{id, members, member_hash}]` to stdout. No writes.
- [ ] **Step 2: build** — add `graph-cluster-cli` to the `bundle` script in `mcp/package.json`; `cd mcp && npm run build`; confirm `dist/tools/graph-cluster-cli.bundle.js` exists.
- [ ] **Step 3:** smoke — point it at a fixture wiki dir, assert valid JSON out.
- [ ] **Step 4: Commit** — `feat(cluster): graph-cluster-cli + bundle`.

### Task B2: `scripts/graph-cluster.sh` shim (node-via-scripts)

- [ ] **Step 1: failing test** — `tests/test-graph-cluster-shim.sh`: build a 4-page clique fixture, run `bash scripts/graph-cluster.sh --knowledge-dir "$DIR"`, assert JSON with one cluster of 4 members.
- [ ] **Step 3: impl** — `scripts/graph-cluster.sh` resolves `node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/graph-cluster-cli.bundle.js" "$@"` (fail-safe: if node or the bundle is missing, print `[]` and exit 0 so SUMMARIZE skips). This is the dream-runner-invokable entry (`Bash(bash $CLAUDE_PLUGIN_ROOT/scripts/*)`), mirroring `wiki-forget-candidates.sh`.
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(cluster): graph-cluster.sh shim (dream-invokable)`.

---

## Phase C — Dream SUMMARIZE phase

Insert SUMMARIZE **after ENRICH, before REINDEX**; protect with `SB_DREAM_SUMMARIZE`. Land the insertion in **both** phase vocabularies.

**Files:** `skills/dream/SKILL.md`, `agents/dream-runner.md`, `tests/test-dream-summarize.sh`.

### Task C1: SUMMARIZE phase wiring

- [ ] **Step 1:** `skills/dream/SKILL.md` — fix the stale `### Step 2: 5-Phase` heading to `6-Phase` (it already lists six); insert `**2e. SUMMARIZE**` between ENRICH and REINDEX and renumber `REINDEX→2f`, `FORGET→2g`. `agents/dream-runner.md` — insert a `SUMMARIZE` phase between Phase 4 (ENRICH) and REINDEX, renumbering consistently. Document the procedure (skip if `SB_DREAM_SUMMARIZE=off`):
  1. `CLUST=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/graph-cluster.sh" --knowledge-dir <staging-knowledge-dir>)`
  2. for each cluster (cap `SB_SUMMARIZE_MAX_PAGES`): if a `staging/wiki/themes/<id>.md` exists with a matching `member_hash`, skip; else write/overwrite the theme page (frontmatter `type: themes`, `generated: true`, `related:` = members, `member_hash`; LLM summary inside `<!-- theme:begin -->`/`theme:end`).
- [ ] **Step 2: verify** — `grep -c 'SUMMARIZE' skills/dream/SKILL.md agents/dream-runner.md` ≥1 each; re-read both to confirm the order is ENRICH→SUMMARIZE→REINDEX→FORGET in both, and no edge writes are introduced.
- [ ] **Step 3: Commit** — `feat(dream): SUMMARIZE phase — community theme pages (staging)`.

### Task C2: Back-compat + summarize behaviour test

- [ ] **Step 1: failing test** — `tests/test-dream-summarize.sh`: stage a fixture wiki with a 4-page clique + a 2-page pair; run the cluster shim; assert (a) `SB_DREAM_SUMMARIZE=off` ⇒ shim/phase produces no `themes/` output (golden); (b) with default on, the 4-clique yields one cluster (theme-page candidate) and the 2-pair yields none (< minSize). (Theme-page *prose* is LLM-authored at dream time and out of scope for the shell test; assert the clustering contract the phase relies on.)
- [ ] **Step 3:** ensure the shim honours `SB_SUMMARIZE_MIN_CLUSTER`; `SB_DREAM_SUMMARIZE=off` is honoured in the SKILL/agent procedure (the shell test asserts the shim's min-size gate; the phase-skip is a doc guard verified by reading).
- [ ] **Step 4:** PASS. **Step 5: Commit** — `test(dream): SUMMARIZE clustering contract + min-size gate`.

---

## Phase D — FORGET protection for `themes`

**Files:** `scripts/wiki-forget-score.sh`, `tests/test-wiki-forget-themes.sh`.

### Task D1: protect theme pages

- [ ] **Step 1: failing test** — `tests/test-wiki-forget-themes.sh`: a fresh `themes/<x>.md` (0 inbound links, fresh mtime, short body) → assert `wiki-forget-candidates.sh` never emits it (its row carries a non-empty protflag).
- [ ] **Step 2:** FAIL (today `themes` hits the `*)` arm → unprotected → candidate).
- [ ] **Step 3: impl** — add a `themes)` arm to the category `case` in `wiki-forget-score.sh`: `themes) s_cat=1.0; prot="PROTECT:category";;`. Protection is via the **protflag column** (`candidates.sh` filters `$5==""`), independent of the numeric score — so the later stub-floor down-weight is harmless. Confirm `wiki-forget-candidates.sh` (the entry point) and the dream Review re-score both inherit it (they call `score.sh`).
- [ ] **Step 4:** PASS. **Step 5: Commit** — `fix(forget): protect generated themes/ pages from archiving`.

---

## Phase E — B2 reconciliation (live maintainer)

Retrieval-grounded dedup + deterministic SUPERSEDE. Edge writes are LIVE (maintainer), never the dream.

**Files:** `agents/knowledge-maintainer.md`, `tests/test-reconcile-supersede.sh`.

### Task E1: retrieval-grounded dedup (Phase 2) + reconcile op vocabulary

- [ ] **Step 1:** Edit maintainer Phase 2 DEDUPLICATE: "For each candidate (mined page / AUDIT-flagged dup), call `knowledge_search(<title-or-text>)` for the top-`SB_RECONCILE_TOPK` (default 5) nearest live pages, then choose **ADD / UPDATE `<slug>` (merge + `## History`) / NOOP / SUPERSEDE `<slug>`**. Bounded by `SB_RECONCILE_MAX` (20) and the 50-change cap. Guarded by `SB_RECONCILE` (off ⇒ today's title-overlap behaviour)." Note: `knowledge_search` already degrades to BM25 when `SECOND_BRAIN_DISABLE_EMBEDDINGS=1`.
- [ ] **Step 2: verify** — `grep -q 'knowledge_search' agents/knowledge-maintainer.md`; re-read for coherence with the existing Phase 2.
- [ ] **Step 3: Commit** — `feat(maintainer): retrieval-grounded dedup (Mem0-style reconcile)`.

### Task E2: deterministic SUPERSEDE + directionality guard (test)

- [ ] **Step 1: failing test** — `tests/test-reconcile-supersede.sh` (drives the MCP tools via their bundled CLIs / a small harness): seed edges `(old, requires, x)`, `(old, part_of, y)`, and an **inbound** `(z, requires, old)`. Simulate SUPERSEDE invalidating the explicit list `[(old,requires,x)]`. Assert: `(old,requires,x)` now closed; `(old,part_of,y)` still live (not named); the inbound `(z,requires,old)` **untouched** (directionality guard); a `(new, supersedes, old)` edge asserted.
- [ ] **Step 2:** FAIL until the procedure is documented + (if needed) a thin test harness exists.
- [ ] **Step 3: impl** — Edit maintainer Phase 3 to the spec §B2.2 procedure: write new page → `knowledge_neighbors(old, direction:"out")` to enumerate current-valid out-edges → emit an **explicit** invalidate list → loop one `knowledge_relate({from:old,type,to:X,invalidate:true,valid_to})` per named edge → assert `(new, supersedes, old)`. Document the directionality guard (out-edges only; `knowledge_relate` matches stored `(from,type,to)`, not the bidirectional read).
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(maintainer): deterministic enumerated SUPERSEDE + directionality guard`.

---

## Phase F — validate awareness + session-load theme surfacing

**Files:** `mcp/src/tools/knowledge-validate.ts` (+ test), `scripts/session-load.sh`.

### Task F1: `knowledge-validate` theme awareness

- [ ] **Step 1: failing test** — extend `knowledge-validate.test.ts`: a `type: themes`, `generated: true` page with `related:` member links to real pages raises **no** `broken_link`/orphan; add `themes` to `KNOWN_CATEGORIES` so `addFrontmatter` types a frontmatter-less theme page as `themes`.
- [ ] **Step 3: impl** — add `themes` to `KNOWN_CATEGORIES`; ensure the orphan check tolerates generated pages. (The optional generated-region hand-edit warning is a **separate** follow-up — not in this task.)
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(validate): recognize themes/ generated pages`.

### Task F2: session-load surfaces the active theme

- [ ] **Step 1: failing test** — `tests/test-session-load-theme.sh`: with a theme page covering the active project's key slug, assert `session-load` emits one theme line within the byte budget.
- [ ] **Step 3: impl** — in the wiki-enrichment region of `session-load.sh`, when an active-project key slug appears in a theme page's `related:`, append one line (`theme: <id> (<n> members)`), small cap, within budget.
- [ ] **Step 4:** PASS. **Step 5: Commit** — `feat(session-load): surface the active project's theme page`.

---

## Phase G — Release

### Task G1: Version bump, migration, gate

- [ ] **Step 1:** bump `mcp/src/server.ts` knowledge-base to `2.3.1`; `cd mcp && npm run build`; confirm the server boots and the new CLI is bundled.
- [ ] **Step 2:** add the 0.22.2 migration row to `skills/upgrade/SKILL.md` (additive: `themes/` created lazily; no data migration).
- [ ] **Step 3:** `bash tests/run-all.sh` + `cd mcp && npm run test` → all green (new TS + shell tests auto-discovered).
- [ ] **Step 4:** `/second-brain:code-review-deep` on the branch (release gate). Address findings.
- [ ] **Step 5:** smoke — run a real dream end-to-end: confirm theme pages stage into the diff, are reviewed at `dream_accept`, survive FORGET, and index after accept; run a maintainer pass and confirm reconcile decisions are bounded + git-visible. **Commit** — `chore(release): consolidation v2 — MCP 2.3.1 + migration + gate`.

## Done-when

- `labelPropagate` is shuffle-invariant (the determinism test passes); barbell splits into two; incremental assignment works.
- A 4+ clique yields a staged theme page; a 2-pair does not; `SB_DREAM_SUMMARIZE=off` ⇒ byte-identical dream.
- A fresh `themes/` page is never a FORGET candidate.
- B2 SUPERSEDE invalidates exactly the enumerated out-edges, leaves unnamed + inbound edges live, asserts the `supersedes` edge — all on the **live** path.
- `knowledge_search` BM25 fallback works under `SECOND_BRAIN_DISABLE_EMBEDDINGS=1`.
- `run-all.sh` + vitest green; deep-review pass clean.
