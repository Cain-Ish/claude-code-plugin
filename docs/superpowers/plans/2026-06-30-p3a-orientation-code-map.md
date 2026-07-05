# P3a — Orientation Code-Structure Map (layer 4 + layer 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This is an **XL** plan — it is phased; each Phase is a self-contained, shippable, version-locked release.

**Goal:** Build the missing orientation pillar — an auto-generated, **token-capped, PageRank-ranked CODE-STRUCTURE MAP** of the active project's own source (spec layer 4) plus **typed code↔knowledge relations** (layer 5), exposed via MCP for blast-radius queries, and **regenerated out-of-band on code change** (drift detection). This is the plugin's weakest, highest-user-value facet (spec §1): Claude should start *oriented* — knowing WHAT exists and WHERE it lives — instead of re-deriving the repo by grep.

**Architecture:** A pure-JS/regex symbol+import extractor walks the project's tracked source, builds a directed file/symbol graph, ranks nodes by PageRank, and serializes a token-capped Markdown map. The graph + map persist **per-project under `BRAIN_DIR`** (NOT in `KNOWLEDGE_DIR/graph`, which is the wiki graph — see §"Separation from the wiki graph"). Two new MCP tools — `code_map` (the ranked map) and `code_neighbors` (blast-radius) — read that store, mirroring how `knowledge_neighbors` reads the wiki edge store but kept entirely separate. Regeneration runs in the existing out-of-band drainer (`extract-drain.sh`) under its single-flight lock, gated by git-rev drift; queries return a `stale` flag when the stored rev no longer matches `git rev-parse HEAD`. Layer-5 edges (code↔wiki) reuse the bi-temporal `graph-store.ts` JSONL machinery in a **physically separate** store file.

**Tech Stack:** TypeScript (MCP server + CLIs, bundled with esbuild `--external:@huggingface/transformers`, tested with vitest); bash hooks/drainer (`extract-drain.sh`, `install-extract-timer.sh`); pure-JS extractor (no native dep) with an **optional** WASM tree-sitter accuracy upgrade vetted exactly like the vector-deps.

This plan is **P3a** — the *orientation code-map* half of spec workstream **P3** (`docs/superpowers/specs/2026-06-26-second-brain-constitution-and-diet-design.md` §6). **Out of scope (sibling follow-up):** the **P3b cross-encoder reranker** over hybrid-search candidates — a separate plan, independent of this one. It is mentioned here only so the reader knows P3 is two parts; do not build it in P3a.

---

## Global Constraints

- **Constitution (hard):** Fully autonomous (zero required user interaction — the map must exist and refresh with no manual step); cross-platform macOS/Windows-MSYS/Linux/BSD; reversible. See `CONSTITUTION.md`.
  - **Autonomy ⇒ the default path takes NO heavy native dep.** Per `CONSTITUTION.md` ("the orientation layer's tree-sitter must have a pure-JS/regex fallback, the way vector-deps were handled") and spec §9, the **shipped default is the pure-JS/regex extractor** (Task group A), which compiles into the bundle and works on every OS with zero install. tree-sitter is an *opt-in accuracy upgrade* (Phase 5), never a requirement.
- **Version lockstep:** every shipped Phase bumps `version` in `.claude-plugin/plugin.json` + the `second-brain` entry of `.claude-plugin/marketplace.json` + a `CHANGELOG.md` entry, in the same commit. Current version at authoring: `0.33.29` → first shippable Phase target `0.33.30` (advance per Phase).
- **Surface-budget ratchet (R8, `docs/surface-budget.json`):** `validate-plugin.sh` counts only `skills/` dirs, `agents/*.md`, `scripts/*.sh`, and `tests/test-*.sh`. **New MCP tools and `mcp/src/**/*.test.ts` are NOT counted.** This plan deliberately adds **zero `scripts/*.sh`** (regen folds into the existing `extract-drain.sh`) and **zero `tests/test-*.sh`** (all tests are vitest under `mcp/src/`), so **no budget bump is required**. If any Phase later adds a `scripts/*.sh` or `tests/test-*.sh`, bump the matching key in `docs/surface-budget.json` in the same commit.
- **Bundle list:** every new CLI under `mcp/src/**` that is invoked at runtime must be added to the `bundle` npm script in `mcp/package.json` with `--external:@huggingface/transformers` (see the existing 20-entry chain). The bundle-drift check in `scripts/validate-plugin.sh` fails if `dist/` is stale.
- **Single-source resolution:** brain/knowledge dir resolution lives ONLY in `mcp/src/brain-paths.ts` (`resolveBrainDir`/`resolveKnowledgeDir`); active-slug resolution lives ONLY in `mcp/src/tools/project-dir.ts` (`resolveActiveSlug`). New code MUST import these — never re-read `process.env.HOME`/`BRAIN_DIR` ad hoc (the `brain-paths.test.ts` source-scan guard enforces this; spec P0).
- **Fail loud:** route failures through the existing error channels (`sb_log_error` in bash; MCP tools return `isError` text), not `2>/dev/null` silent exits (user feedback: fail-loud over silent fallback).

---

## Separation from the wiki graph (do NOT duplicate `knowledge_neighbors`)

| | Wiki graph (EXISTS) | Code graph (THIS PLAN) |
|---|---|---|
| Store | `KNOWLEDGE_DIR/graph/edges.jsonl` | `BRAIN_DIR/projects/<slug>/codemap/` |
| Nodes | wiki page slugs | source files + code symbols |
| Edges | `requires/affects/relates/part_of/supersedes` (human/LLM-asserted) | `imports`, `references` (machine-extracted) + ranks |
| Query tool | `knowledge_neighbors` | `code_neighbors` (NEW) |
| Lifecycle | dream/maintainer + `knowledge_relate` | out-of-band regen on code drift |

`knowledge_neighbors` (`mcp/src/tools/knowledge-neighbors.ts`) stays **untouched**. The code graph is a separate scope, separate store, separate tool. The ONLY shared code is the bi-temporal fold machinery in `graph-store.ts` (`EdgeRecord`/`loadEdges`/`foldToCurrent`/`validAt`), reused by **layer 5** (Task group D) via import — not copy — in a physically separate JSONL file.

---

## Data model (target)

Per-project store at `BRAIN_DIR/projects/<slug>/codemap/`:

- **`graph.json`** — full generated graph (machine tier):
  ```jsonc
  {
    "schema": 1,
    "slug": "<project-slug>",
    "repo_root": "<abs path used>",          // the CLAUDE_PROJECT_DIR root mapped
    "git_rev": "<sha or 'nogit'>",           // drift key (see Task C)
    "dirty": false,                           // working tree had uncommitted changes
    "generated_at": "2026-06-30T..Z",
    "generator": "regex-v1 | tree-sitter-v1", // which tier produced it
    "files": [ { "id": "src/a.ts", "lang": "ts", "rank": 0.0123, "symbols": ["foo","Bar"] } ],
    "symbols": [ { "id": "src/a.ts#foo", "kind": "function", "file": "src/a.ts", "rank": 0.0098 } ],
    "edges": [ { "from": "src/a.ts", "to": "src/b.ts", "type": "imports" } ]
  }
  ```
- **`map.md`** — the **token-capped, PageRank-ordered** serialized form for injection/`code_map` (top-ranked files + their key symbols until the token budget fills). Default cap `SB_CODEMAP_TOKEN_BUDGET=2000` tokens (≈ session-load's hot-tier byte budget posture).
- **`code-links.jsonl`** (Task group D, layer 5) — bi-temporal `EdgeRecord`-shaped lines linking a code node id ↔ a wiki slug; loaded with the SAME `loadEdges`/`foldToCurrent` from `graph-store.ts`.

All paths via `path.join` (cross-OS). Node ids use **forward-slash POSIX-relative** paths (normalize `path.sep` → `/`) so a graph generated on Windows compares/queries identically on Linux CI.

---

## Phase / Task overview (dependency-ordered)

- **Phase 0 — Generator-choice spike (HIGHEST RISK; do first).** Task 0.
- **Phase 1 — Pure-JS extractor + PageRank + store + CLI.** Tasks A1–A4.
- **Phase 2 — MCP surface (`code_map`, `code_neighbors`).** Tasks B1–B2.
- **Phase 3 — Out-of-band drift detection + regen.** Tasks C1–C2.
- **Phase 4 — Layer-5 code↔knowledge relations.** Tasks D1–D2.
- **Phase 5 (optional accuracy upgrade) — web-tree-sitter WASM tier.** Task E1.

Phases 1→4 ship sequentially; each is independently releasable (a map with no MCP tool is useless, so Phase 1+2 are the first meaningful release). Phase 5 is optional and gated behind the same deferral discipline as the reranker.

---

## Phase 0

### Task 0: Generator choice & cross-platform vetting (decision spike — NO feature code)

**Why first:** native tree-sitter bindings are the single biggest cross-platform risk (node-gyp/prebuild on Windows-MSYS and especially BSD CI). This task records the decision so all later tasks are unblocked. The recommendation below is the expected outcome; the spike exists to *confirm*, not re-litigate.

**Assessment (record in the plan's decision log / a wiki decision page):**

| Option | Native build? | Win/BSD risk | Verdict |
|---|---|---|---|
| **node-tree-sitter** (native N-API bindings + per-grammar native modules) | YES (node-gyp) | HIGH — prebuilds often missing for MSYS/BSD; node-gyp needs a toolchain | **REJECT** — reintroduces the exact problem `CONSTITUTION.md` forbids |
| **web-tree-sitter** (WASM core) + `tree-sitter-wasms` (prebuilt `.wasm` grammars) | NO (pure WASM) | LOW — same `.wasm` runs on every OS; no toolchain | **ACCEPT as the optional Tier-1 upgrade (Phase 5)** |
| **Pure-JS regex/heuristic extractor** (in-repo, no dep) | NO | NONE | **ACCEPT as the shipped Tier-0 default (Phase 1)** |

**Decision (recommended, to confirm in the spike):**
1. **Default = pure-JS Tier-0** — guarantees the map exists with zero install on all four OSes (autonomy hard constraint). Good enough for import-graph + exported-symbol ranking, which is what blast-radius needs.
2. **web-tree-sitter is the *opt-in* Tier-1** (Phase 5), installed via a `bin/install-codemap-deps.sh` that mirrors `bin/install-vector-deps.sh` exactly (shared version-independent dir, staging-then-swap, junction-on-MSYS via `node fs.symlinkSync(...,'junction')`, `--relink-only` no-download mode, `deps_ok`/`import_ok` validation). esbuild keeps it `--external` like `@huggingface/transformers`; graceful degrade to Tier-0 when absent (mirror `embeddings.ts` `getPipeline()` → `null` → fallback). **No native build anywhere** — WASM sidesteps it.

**Precondition / idempotent check:** none (decision doc only).
**Files to touch:** this plan's decision log; optionally a `wiki/decisions/2026-06-30-codemap-generator-choice.md` via the normal pin/archive path.
**Test:** none (no code).
**Risks:** choosing tree-sitter-as-default would violate autonomy + cross-platform — the spike must explicitly reject that.

---

## Phase 1 — Pure-JS extractor + PageRank + store + CLI

### Task A1: Source enumeration (repo scoping + ignore rules)

**Precondition/idempotent:** function is pure (dir in → file list out); safe to call repeatedly.
**Files:**
- Create: `mcp/src/tools/codemap/scan-sources.ts`
- Test: `mcp/src/tools/codemap/scan-sources.test.ts`

**Change:**
- `export async function scanSources(repoRoot: string): Promise<{ id: string; abs: string; lang: 'ts'|'js'|'py' }[]>`.
- **Bounding strategy (cross-platform, respects .gitignore for free):** if `repoRoot` is a git repo, enumerate via `git -C <root> ls-files` (tracked files only — auto-excludes `node_modules`/`dist`/anything gitignored; `git` is already a runtime dependency of the plugin). If not a git repo, fall back to `glob('**/*')` with a hardcoded ignore list: `node_modules`, `dist`, `build`, `.git`, `coverage`, `vendor`, `.next`, `out`, minified `*.min.js`.
- **Language coverage v1:** `.ts .tsx .js .jsx .mjs .cjs` → ts/js; `.py` → py. (Spec open question: TS/JS/Python first.)
- **Size caps (repo-blowup guard):** skip files > `SB_CODEMAP_MAX_FILE_BYTES` (default 512 KiB); cap total files at `SB_CODEMAP_MAX_FILES` (default 4000) taking the most-recently-modified first; record truncation in `graph.json.truncated`.
- Normalize ids to POSIX-relative (`path.relative(root,abs).split(path.sep).join('/')`).

**Test:** fixture dir `mcp/src/tools/codemap/__fixtures__/sample/` with a few `.ts`/`.py` files + a `node_modules/` and `dist/` that MUST be excluded; assert excluded dirs absent, langs tagged, ids POSIX even when run on Windows (assert no `\\` in any id), and the size cap drops an oversized fixture file.
**Risks:** `git ls-files` quoting of non-ASCII paths (`-z` + split on NUL to be safe); huge monorepos (covered by caps).

### Task A2: Symbol + import extraction (Tier-0 regex)

**Precondition/idempotent:** pure per-file parse.
**Files:**
- Create: `mcp/src/tools/codemap/extract.ts`
- Test: `mcp/src/tools/codemap/extract.test.ts`

**Change:**
- `export function extractFile(id: string, src: string, lang: Lang): { symbols: Symbol[]; imports: string[] }`.
- TS/JS: regex/heuristic capture of top-level `export function|class|const|let|async function`, `class X`, `export default`, and method names; imports from `import ... from '<spec>'`, `require('<spec>')`, `export ... from '<spec>'`, dynamic `import('<spec>')`.
- Python: `def `, `class `, `import x`, `from x import ...`.
- **Import resolution:** resolve relative specifiers (`./`, `../`) against the file id to a node id (try the candidate extensions + `/index.*`); leave bare/package specifiers unresolved (external — dropped from the internal graph but counted for fan-out weight). Document the regex limits in a comment (no scope analysis, no re-export following beyond one hop) and that Tier-1 (Phase 5) tree-sitter raises fidelity.

**Test:** feed representative TS + Python strings (built from literals — keep source pure-ASCII); assert exported symbols and resolved internal imports; assert a `require`/dynamic-`import` is caught; assert bare specifier `'react'` is NOT added as an internal edge.
**Risks:** regex false positives in comments/strings — acceptable for a ranking heuristic (Aider's repo-map is itself approximate); explicitly out-of-scope to be a real parser (that's Tier-1).

### Task A3: Graph build + deterministic PageRank

**Precondition/idempotent:** pure (files+edges in → ranks out); same input → byte-identical output.
**Files:**
- Create: `mcp/src/tools/codemap/pagerank.ts`
- Create: `mcp/src/tools/codemap/build-graph.ts`
- Tests: `mcp/src/tools/codemap/pagerank.test.ts`, `build-graph.test.ts`

**Change:**
- `pagerank(nodes: string[], edges: [from,to][], opts?)`: standard PageRank, damping `0.85`, **deterministic**: iterate nodes in **sorted id order**, fixed `iterations` (default 30) OR L1-convergence epsilon `1e-6` (whichever first), dangling-node mass redistributed uniformly. Returns a `Map<id, rank>`.
- `buildGraph(scanned, extracted)`: assemble `files`/`symbols`/`edges`, run PageRank over the **file import graph** (and, where symbol refs are detectable, fold a symbol-reference graph weighted by identifier mentions — Aider's approach; v1 may rank files only and inherit symbol rank from the file), attach ranks, sort outputs by `rank desc, id asc` (stable tie-break).

**Test:** a tiny hand-checkable graph (A→B, A→C, B→C): assert C outranks B outranks A; assert **determinism** — two runs on the same input produce identical rank arrays AND identical ordering (the contract `code_map` relies on for a stable token-capped slice); assert a node with no edges still appears with the base rank.
**Risks:** floating-point nondeterminism across platforms — mitigate by fixed iteration count + sorted accumulation order (don't rely on `Map` insertion order for the sum); test asserts equality to a fixed tolerance only on values, exact equality on ordering.

### Task A4: Serializer (token cap) + store writer + `code-map-cli`

**Precondition/idempotent:** writing `graph.json`+`map.md` for the same input is idempotent (atomic temp-write + rename).
**Files:**
- Create: `mcp/src/tools/codemap/serialize.ts` (graph → token-capped `map.md`)
- Create: `mcp/src/tools/codemap/store.ts` (`codemapDir(brainDir,slug)`, read/write `graph.json`)
- Create: `mcp/src/tools/codemap/code-map-cli.ts` (CLI entry: generate + write, used by the drainer)
- Tests: `serialize.test.ts`, `store.test.ts`
- Modify: `mcp/package.json` (`bundle` script — add `code-map-cli` with `--external:@huggingface/transformers`)

**Change:**
- `serialize(graph, tokenBudget)`: emit top-ranked files (`path — symbol, symbol, …`) descending by rank, stopping when the running token estimate (chars/4 heuristic, same coarse model used elsewhere) hits `tokenBudget`; append a `(+N more files omitted)` footer. **Never exceed the budget** (the load-bearing invariant).
- `store.ts` uses `resolveBrainDir()` + `resolveActiveSlug()` for the path; writes via temp+rename; creates dirs with `recursive:true`.
- `code-map-cli.ts`: resolves repo root (`CLAUDE_PROJECT_DIR` || cwd), slug (`resolveActiveSlug`), runs scan→extract→build→serialize→write; prints a one-line summary to stderr; exit 0 always (fail-soft like other CLIs). Accepts `--check` (drift only, see Task C) and `--force`.

**Test:** assert serialized `map.md` byte length ⇒ token estimate ≤ budget for a graph that overflows it, and that the highest-rank file appears and a low-rank file is omitted; round-trip `graph.json` write/read; assert the store path lands under `BRAIN_DIR/projects/<slug>/codemap/` (with a temp `BRAIN_DIR`).
**Risks:** token estimate drift vs real tokenizer — coarse chars/4 is the project's existing convention; cap with margin (budget × 0.95).

**Phase-1 release step:** add the CLI to the bundle, `cd mcp && npm run build`, then version-lockstep bump + CHANGELOG + run the gates (see Verification). (Phase 1 alone is not user-visible without Phase 2; ship them together if preferred.)

---

## Phase 2 — MCP surface

### Task B1: `code_map` tool

**Precondition/idempotent:** read-only; returns whatever the store holds (or a "not generated yet" notice).
**Files:**
- Create: `mcp/src/tools/codemap/code-map.ts` (`codeMap({brainDir, slug, tokenBudget?})` → `{ map, generated_at, git_rev, stale, generator }`)
- Modify: `mcp/src/server.ts` (register `code_map`)
- Test: `mcp/src/tools/codemap/code-map.test.ts`

**Change:** register mirroring the existing tools (read-only ⇒ no `guardDestructive`):
```ts
server.registerTool("code_map", {
  description: "Return the token-capped, PageRank-ranked code-structure map for the active project (orientation: what exists / where it lives). Read-only; regenerated out-of-band on code change. Carries `stale:true` when the repo changed since generation. This is the CODE map — distinct from knowledge_search/knowledge_neighbors (the wiki).",
  inputSchema: { token_budget: z.number().min(200).max(8000).optional() },
}, async ({ token_budget }) => { /* codeMap(...) using BRAIN_DIR + resolveActiveSlug() */ });
```
Return a graceful text notice when no `graph.json` exists yet (first run before the drainer has generated one) — point the model at the fact that it generates automatically out-of-band.

**Test:** with a temp `BRAIN_DIR` containing a fixture `graph.json`, assert the tool returns the capped map + `stale` flag; assert the no-store path returns the notice, not an error.

### Task B2: `code_neighbors` tool (blast-radius)

**Files:**
- Create: `mcp/src/tools/codemap/code-neighbors.ts`
- Modify: `mcp/src/server.ts` (register `code_neighbors`)
- Test: `mcp/src/tools/codemap/code-neighbors.test.ts`

**Change:**
- `codeNeighbors({brainDir, slug, node, direction, depth})`: BFS over `graph.json.edges` from a file/symbol id. `direction:'in'` = **importers/callers = blast radius** ("what breaks if I change this"); `'out'` = dependencies; `'both'` default. Reuse the BFS shape from `graph-store.ts::neighbors` (min-hop dedup) but over the code edge list. Cap result count (`SB_CODEMAP_NEIGHBORS_MAX`, default 50).
- Accept a fuzzy node arg (exact id, else basename match) so the model can ask `code_neighbors("server.ts", direction:"in")` without the full path.

**Test:** fixture graph A→B, C→B; `code_neighbors("B", direction:"in")` returns {A,C}; `direction:"out"` from A returns {B}; depth>1 transitive; unknown node returns empty (not error); fuzzy basename resolves.
**Risks:** ambiguous basename — return all matches with their full ids and a note, never silently pick one.

**Phase-2 release step:** version-lockstep bump + CHANGELOG + gates. Now user-visible: ask `code_map` / `code_neighbors`.

---

## Phase 3 — Out-of-band drift detection + regen

### Task C1: Drift detection + `--check`/`--force` in the CLI

**Precondition/idempotent:** `--check` is read-only and cheap.
**Files:**
- Modify: `mcp/src/tools/codemap/code-map-cli.ts` (drift logic)
- Create: `mcp/src/tools/codemap/drift.ts` (`isStale(graph, repoRoot)`)
- Test: `mcp/src/tools/codemap/drift.test.ts`

**Change:**
- `currentRev(repoRoot)`: `git -C <root> rev-parse HEAD` (→ `'nogit'` if not a repo); `isDirty`: `git status --porcelain` non-empty.
- `isStale`: `graph.git_rev !== currentRev` OR (`nogit` repo: newest tracked-source mtime > `graph.generated_at`) OR `graph.dirty` was true (always re-check a previously-dirty tree). `code_map`/`code_neighbors` compute `stale` the same way at query time so a query between regens is honest.
- CLI `--check` prints `stale|fresh` + exit 0; `code-map-cli` (no flag) regenerates only when stale unless `--force`.

**Test:** stub `git` via an injectable `runGit` fn (don't shell out in unit tests): same rev ⇒ fresh; changed rev ⇒ stale; `nogit` + newer mtime ⇒ stale; previously-dirty ⇒ stale.
**Risks:** `git` absent — `runGit` returns `'nogit'`, falls to mtime path (covered).

### Task C2: Wire regen into the out-of-band drainer (autonomy-safe, NOT in-session)

**Precondition/idempotent:** runs under the drainer's existing single-flight lock; `--check` gate makes it a no-op when fresh.
**Files:**
- Modify: `scripts/extract-drain.sh` (add a content-free codemap-regen block alongside the existing `maintain-deterministic.sh` block)
- Modify: `mcp/src/tools/codemap/code-map-cli.ts` (already the entry)
- Test: extend an existing drainer shell test OR add assertions in a vitest harness; **do not add a new `tests/test-*.sh`** (budget). Prefer a vitest test that runs `code-map-cli` against a temp repo fixture + temp `BRAIN_DIR` and asserts `graph.json`/`map.md` appear and refresh on a simulated rev change.

**Change:** in `extract-drain.sh`, after the `maintain-deterministic.sh` block (both are deterministic/content-free and share the lock + defer guards), add:
```bash
# Out-of-band code-map regen (deterministic, content-free). Default on; gated on
# git-rev drift via the CLI's own --check so a fresh tree costs ~nothing. The
# heavy walk stays OUT of any Claude session (autonomy + cost). Kill: auto_codemap:false.
if [ "$(sb_config_bool .auto_codemap on)" = "on" ]; then
  # Flat dist path — Phase 1 shipped the bundle at dist/tools/ (NOT dist/tools/codemap/;
  # 0.33.33 Task A4 deviation note). Fail LOUD on a missing bundle: a silent
  # `[ -f ] … || true` here would no-op the whole regen forever on a path typo
  # (adversarial-review finding, 0.33.33 pre-release).
  CM_CLI="$PLUGIN_ROOT/mcp/dist/tools/code-map-cli.bundle.js"
  if [ -f "$CM_CLI" ] && command -v node >/dev/null 2>&1; then
    CLAUDE_PROJECT_DIR="${SB_CODEMAP_REPO:-$PWD}" node "$CM_CLI" >/dev/null 2>&1 || \
      sb_log_error "extract-drain.sh" "codemap regen failed" 0
  else
    sb_log_error "extract-drain.sh" "codemap regen skipped: bundle or node missing ($CM_CLI)" 0
  fi
fi
```
- **Repo targeting note (spec open question):** the out-of-band drainer has no session cwd. v1 regenerates the codemap for the **last-active project** (resolve its `root_path` from `projects.jsonl`, the same source `session-load.sh` uses), so the drainer maps the repo the user actually works in. Add a `SB_CODEMAP_REPO` override and document the limitation (multi-repo users: each becomes active in turn and gets mapped on the next tick). A complementary **detached SessionStart catch-up** (mirroring the existing stale-`wiki/index.md` background reindex in `session-load.sh` lines ~701-717) may regen-if-stale in the background `&` for the *current* repo — cheap, deterministic, non-blocking — but the authoritative regen stays in the drainer.
- Add the new bundle path to `mcp/package.json` if not already (Task A4).

**Test:** vitest: point the CLI at a temp git repo fixture (init + commit), run it, assert store files exist with that rev; `git commit` a change (or stub the rev), run again, assert `git_rev` updated and `stale` cleared.
**Risks:** drainer defers while an interactive session is live — acceptable (the SessionStart catch-up covers the in-use repo); regen cost is bounded (deterministic Tier-0, single-flight, drift-gated).

---

## Phase 4 — Layer-5 code↔knowledge relations

### Task D1: Deterministic code↔wiki edge mining (no LLM, autonomy-safe)

**Precondition/idempotent:** re-running rewrites the same edges (append-only bi-temporal log; re-assert is a no-op via fold).
**Files:**
- Create: `mcp/src/tools/codemap/code-links.ts` (mine + store, reusing `graph-store.ts`)
- Test: `mcp/src/tools/codemap/code-links.test.ts`

**Change:**
- Reuse `graph-store.ts`: `EdgeRecord`/`appendEdge`/`loadEdges`/`foldToCurrent`/`validAt` — **import, do not copy** (single-source discipline). Store at `BRAIN_DIR/projects/<slug>/codemap/code-links.jsonl` (physically separate from the wiki `edges.jsonl`).
- Edge identity: `from` = code node id (e.g. `src/a.ts#foo`), `to` = wiki slug, `type:'relates'`, `source:'codemap-mine'`, `confidence:'medium'`.
- v1 miner (deterministic, cheap): scan wiki page bodies (via `KNOWLEDGE_DIR/wiki`) for tokens that exactly match codemap symbol/file basenames above a length threshold (≥4 chars, skip stop-symbols) → assert a `relates` edge. Conservative (favor precision); document that LLM-inferred traceability is a later enhancement (spec open question: manual / LLM-inferred / commit-mined).
- **Staleness:** when the codemap regenerates and a code node disappears, `invalidate` its edges (bi-temporal close, never hard-delete — matches the wiki graph's append-only contract and the constitution's reversibility).

**Test:** temp wiki page mentioning a symbol that exists in a fixture graph ⇒ a `relates` edge is asserted; a regen dropping that symbol ⇒ edge invalidated (folded `valid_to` set), not deleted; re-mine is idempotent.
**Risks:** false-positive token matches (e.g. common words as symbol names) — length + stop-list + exact-match keep precision high; this is metadata, not a trust boundary.

### Task D2: Expose layer-5 in `code_neighbors`

**Files:**
- Modify: `mcp/src/tools/codemap/code-neighbors.ts` (+ optional `include_knowledge` flag)
- Test: extend `code-neighbors.test.ts`

**Change:** when `include_knowledge:true` (default true), fold current-valid `code-links.jsonl` edges into the neighbor result so blast-radius answers "changing `src/a.ts#foo` affects wiki page `<slug>`" (traceability). Mark these edges `type:'relates', scope:'knowledge'` in the output so the model distinguishes code edges from doc links.
**Test:** fixture code graph + one code-link edge ⇒ `code_neighbors` on that node surfaces the wiki slug with the knowledge scope tag.

**Phase-4 release step:** version-lockstep bump + CHANGELOG + gates.

---

## Phase 5 (OPTIONAL accuracy upgrade) — web-tree-sitter WASM tier

### Task E1: Optional WASM tree-sitter extractor with graceful degradation

Defer unless Tier-0 fidelity proves insufficient (treat like the reranker: ship only if it earns its complexity).
**Files:**
- Create: `bin/install-codemap-deps.sh` (mirror `bin/install-vector-deps.sh` — shared dir, staging+swap, junction-on-MSYS, `--relink-only`, `deps_ok`/`import_ok`)
- Create: `mcp/src/tools/codemap/extract-treesitter.ts` (dynamic `import('web-tree-sitter')` + load `.wasm` grammars; `null` on failure)
- Modify: `mcp/src/tools/codemap/extract.ts` (try Tier-1, fall back to Tier-0 regex — mirror `embeddings.ts getPipeline()`)
- Modify: `mcp/package.json` (`web-tree-sitter` + `tree-sitter-wasms` as deps; keep `--external` in bundle)
- Tests: `extract-treesitter.test.ts` + a **graceful-degradation** test + a **source-scan guard**

**Change:** extractor selects Tier-1 when the optional dep imports, else Tier-0. Record `generator` in `graph.json`. No native build (WASM).
**Tests (mirror vector-deps discipline):**
- With the dep absent (the CI default), `extractFile` STILL returns a valid Tier-0 result — the map degrades, never fails (the exact `embeddings.ts` fallback contract).
- **Source-scan guard** (like `brain-paths.test.ts`): assert no codemap module `import`s `web-tree-sitter` at top level (must be a dynamic `import()` inside the try), so a missing optional dep can never break the bundle/load — and assert Tier-0 has zero third-party imports.
**Risks:** WASM grammar load path resolution under the bundle (load grammars by absolute path from the installed shared dir, like the transformers model); larger install — gated behind the opt-in installer, never auto-downloaded (consent boundary, matching vector-deps).

---

## Verification (end-to-end, run after each shippable Phase)

1. **Unit suite:** `cd mcp && npm ci && npm test` — all vitest green incl. the new `codemap/*.test.ts` (determinism, token-cap, blast-radius, drift, graceful degradation).
2. **Build/bundle:** `cd mcp && npm run build` — `tsc --noEmit` clean; esbuild regenerates `dist/` incl. `code-map-cli.bundle.js`.
3. **Gates (the user's required pre-push set):** `bash scripts/validate-plugin.sh` (bundle-drift fresh, version lockstep, **surface-budget not exceeded** — confirm no new `scripts/*.sh` or `tests/test-*.sh` slipped the budget) and `bash tests/run-all.sh` — all green. Run on Linux/BSD CI too (subagents on Windows miss BSD/Linux failures — user feedback).
4. **Manual smoke:** in a real project session, run `code-map-cli` (or let the drainer tick), then call `code_map` (ranked map appears, ≤ budget) and `code_neighbors("<a core file>", direction:"in")` (importers listed). Edit a file + commit ⇒ next query reports `stale:true` ⇒ after a drainer tick ⇒ fresh.
5. **Separation check:** `knowledge_neighbors` behavior unchanged; `KNOWLEDGE_DIR/graph/edges.jsonl` untouched by codemap; codemap store lives only under `BRAIN_DIR/projects/<slug>/codemap/`.

---

## Risks (consolidated) & mitigations

- **Native build on Windows/BSD (TOP risk):** eliminated by shipping the pure-JS Tier-0 default; WASM (not native) for the optional Tier-1 — no node-gyp anywhere. (Task 0.)
- **Repo-size blowup / regen cost:** `git ls-files` scoping + per-file byte cap + max-file cap + truncation flag; regen is deterministic, single-flight-locked, and **drift-gated** (`--check` no-ops a fresh tree). (Tasks A1, C.)
- **Token-cap correctness:** explicit test that the serialized map never exceeds the budget, with a 5% margin. (Task A4.)
- **PageRank nondeterminism across OS:** fixed iterations + sorted accumulation + POSIX-normalized ids; determinism is a tested contract. (Task A3.)
- **Duplicating the wiki graph:** separate store, separate tools, shared-by-import-only fold machinery; `knowledge_neighbors` untouched. (§Separation.)
- **Autonomy regression:** map exists with zero install (Tier-0), refreshes via the existing drainer with no user action; optional deps never auto-download (consent boundary). (Tasks 0, C2.)
- **Stale/misleading map:** `stale` flag computed at query time; layer-5 edges invalidated (not deleted) on regen — reversible. (Tasks C1, D1.)
- **Surface-budget trip:** plan adds zero counted surface; if a Phase needs a `scripts/*.sh`/`tests/test-*.sh`, bump `docs/surface-budget.json` same-commit. (Global Constraints.)

## Effort & sequencing

XL — phase it. Recommended order and rough size: **Phase 0** (S, decision) → **Phase 1** (L, the extractor/PageRank/store core) → **Phase 2** (M, MCP tools — first user-visible release) → **Phase 3** (M, drift+regen — makes it autonomous) → **Phase 4** (M, layer-5 traceability) → **Phase 5** (M, optional WASM accuracy, defer like the reranker). Ship Phase 1+2 together as the first meaningful release; Phases 3/4 each as their own version-locked release.

## Sibling follow-up (NOT this plan)

**P3b — cross-encoder reranker** over hybrid-search candidates (return a reranked top-3–5; vet cross-platform like vector-deps, pure-JS/no-rerank fallback). Independent of P3a; its own plan. Mentioned per spec §6 P3 so the reader knows P3 has two halves.

---

## Decision log

- **2026-07-05 — Task 0 CONFIRMED (Phase 0 closed):** Tier-0 default = pure-JS regex/heuristic
  extractor (zero deps, compiles into the bundle, works on all four OSes — satisfies the
  autonomy + no-native-deps hard constraints); node-tree-sitter REJECTED (node-gyp/prebuild risk
  on MSYS/BSD — exactly the CONSTITUTION.md class the vector-deps saga proved); web-tree-sitter
  WASM stays the OPT-IN Phase 5 accuracy tier behind the vector-deps install discipline. No new
  `dependencies` entry in mcp/package.json for Phases 1-4. Shared type contract anchored at
  `mcp/src/tools/codemap/types.ts`. Version target recomputed at implementation time per
  sb-change-control: Phases 1+2 ship together as 0.33.33 (plan authored at 0.33.29).
