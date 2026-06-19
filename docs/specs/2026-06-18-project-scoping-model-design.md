# Project Scoping Model + Attribution Correctness — Design

**Date:** 2026-06-18
**Status:** APPROVED — all sections user-approved (incident fix, M3 scoping, migration & collision).
Ready for `writing-plans`. Pending: spec self-review (done inline) + final user review.
**Trigger:** A setup deep-scan in `claude-code-plugin` filed 88 docs into `witcherrpg`'s raw inbox.

---

## Problem

Project attribution across capture → drain → consolidate rides on the ambient active session slug
(`resolveActiveSlug`: `CLAUDE_PROJECT_DIR > cwd-if-known-project > .active-session-slug pin > cwd`).
When that resolves wrong (stale shared pin + no per-process signal, or a forced `SB_ACTIVE_SLUG`),
work lands under the wrong project **silently**. Separately, the *scoping model* (which nodes a
session can see/update) is underspecified for real-world project relationships.

## Verified findings (research workflow wf_ff362962, 3 agents)

1. **Capture** (`mcp/src/tools/raw-scan-cli.ts:8-17`) files into `projects/<resolveActiveSlug()>/raw/`,
   independent of the `SCAN_ROOT` it scanned. Scanning A from a cwd resolving to B files A's docs into B.
2. **Drain** (`agents/knowledge-maintainer.md:313-316`) stamps each new node with *"the active `project:`
   facet"* and only sees the active project's inbox (`raw-capture-cli pending` → `projects/<active-slug>/raw/`,
   `raw-inbox.ts:34-36`). It uses the item's `source:` only for the `## Sources` line (`:317-318`) — never
   to decide the project. No guard against a foreign-origin item in the inbox.
3. **Schema** (`knowledge-search.ts:449`,`:67`): `project:` is read as a **single scalar** (`extractYamlValue`).
   A node has exactly one project **or none**. "Global/shared" = *empty* `project:` → search tier 3,
   in-scope for **every** project, no MOC (`project-moc.ts:13-14`). Search is a **shared corpus, tiered not
   partitioned**: `tier = proj===slug?1 : neigh.has(sl)?2 : proj===''?3 : 4` (`knowledge-search.ts:337`),
   in-scope pool = `tier<=3` with auto-broaden. So "A sees A + global, excludes B" already works today;
   tier-2 already boosts direct graph-neighbors.
4. **Dream** (`skills/dream/SKILL.md:34-36`, `agents/dream-runner.md:117-124`) is project-agnostic: never
   sets `project:`, consolidates the whole shared wiki, and **by default mines transcripts from all projects**.
   Optional `--slug` filter exists (`dream.ts:137-139`, `dream-snapshot.sh:118-121`) but is not used by default.
5. **Hierarchy primitive exists:** `part_of` edge type in the relational graph; `kb-project-backfill.sh`
   "walks `part_of` ancestry from registry anchors and sets `project:` on members"; `knowledge_neighbors`
   walks `part_of`. Not yet wired into search/drain/dream scoping.

## Settled decisions (incident fix — independent of the scoping model)

- **Source of truth = the resource, not ambient session.** Capture derives the destination from
  `basename(SCAN_ROOT)`; cross-checks `resolveActiveSlug()`; on mismatch **fail loud** (refuse unless
  `SB_ACTIVE_SLUG` is explicitly set). `setup/SKILL.md` step 6 `cd "$SCAN_ROOT"` before invoking. Each raw
  item gains an authoritative **`origin:`** field at capture.
- **Drain mismatch guard:** maintainer compares each item's `origin:` to the active slug; on mismatch
  **skip + flag** (never drain a foreign-origin item silently). Node `project:` is set from `origin:`.
- **Dream default-scope:** Creation passes `transcript_filter.project_slug = resolveActiveSlug()` by default;
  persist it in `status.json`; `project_slug:"all"` is the explicit cross-project opt-out. Staging-wiki
  consolidation stays project-neutral; only mining input is scoped.

## Scoping model — RESOLVED (M3 hierarchy + global)

**Confirmed requirement: BOTH topologies must work** — (a) standalone single repos/projects, and
(b) a monorepo parent A containing sub-projects B,C,D,E. A standalone repo is simply the **no-parent
degenerate case** of the hierarchy: no `part_of` parent ⇒ scope = `{itself} + global` (today's behavior,
unchanged). A sub-project additionally sees its family: working in B → **B + parent A + siblings + global**.
So one model covers both; there is no separate single-vs-mono mode. Candidate representations:

- **M1 Global-only** — node ∈ one project, or global (empty). Search already implements it. No schema change.
  Covers user-prefs / general-rules sharing, but NOT monorepo families.
- **M2 Multi-project list** — `project: [a,b]`. Arbitrary co-membership. Bigger ripple (parse/tiering/MOC/scripts).
  Probably unnecessary if hierarchy covers "related projects."
- **M3 Hierarchical groups (SELECTED)** — model the monorepo as `B part_of A`. Make scoping
  hierarchy-aware: a session in B treats its `part_of` ancestors (A) and their members (C,D,E) as in-scope
  (a new tier between "own project" and "global"), plus global. Reuses the existing `part_of` edge +
  `kb-project-backfill` ancestry walk + tier-2 neighbor logic; the work is making search/drain/dream honor
  the *family* boundary, and a registry notion of parent/child projects.

**Direction (confirmed): M3 (hierarchy) + global (M1)** — single repos are the no-parent case, so this one
model serves both topologies. M2 (arbitrary multi-project list) is **dropped** unless a concrete A+B-but-not-C
case appears.

### Settled (2026-06-18 design session)

- **Two registries exist, solving orthogonal problems** (research wf_b2fced07):
  - `~/.second-brain/projects.jsonl` (hot tier) — *project/session* registry `{slug,name,last_session_iso,hot_byte_count}`,
    written by `session-load.sh:57` + setup. Keyed on `.slug`; **adding fields is back-compat** (all readers use `.slug`).
  - `~/knowledge/graph/project-registry.jsonl` (cold tier) — `{anchor,project}` rows that `kb-project-backfill.sh:20`
    walks via **page-level `part_of` edges** to stamp `project:` facets on wiki nodes.
  - Page-level `part_of` (weight 0.8; undirected 2-hop neighbourhood `knowledge-search.ts:332`) already decides
    *which node carries which `project:` facet*. M3 adds the missing **project↔project topology** the search tier
    needs to answer "is candidate facet C in active-project B's family?". Current tier cascade:
    `proj===slug?1 : neigh.has(sl)?2 : proj===''?3 : 4` (`knowledge-search.ts:337`) — M3 inserts a **family tier**
    between own-project (1) and global (3).
- **Registration mechanism = BOTH (projects.jsonl is truth, projected to graph).** Setup writes an optional
  `parent: <slug>` onto the project's `projects.jsonl` record (authoritative, human-editable; absent = standalone
  root, today's behavior unchanged). A **reconciliation step** (setup after write; re-validated by the maintainer)
  mirrors the link into the cold-tier graph: a project-level `part_of` edge between the two projects' MOC pages
  + a `project-registry.jsonl` anchor row, so `knowledge_neighbors`, MOC cross-linking, and backfill stay fed.
  - **Facet-merge guard (load-bearing):** the projection must NOT cause `kb-project-backfill` to rewrite a child's
    `project:` facet to the parent key. Each project anchors its OWN MOC with its OWN key; the parent→child MOC
    edge is for navigation/scoping awareness only. Backfill is already idempotent/never-overwrite — a test must
    assert "child page facet unchanged after projecting a parent link."
  - **Scoping reads truth, not the projection:** the search family-membership test reads `projects.jsonl parent`
    directly (small, fast, hot). The graph projection is for the graph-native consumers + re-parent history
    (bi-temporal `valid_to`), not the load-bearing scope path. This keeps scoping correct even if the projection drifts.

### Approved design (2026-06-18, user-approved)

**Detection = auto-detect + confirm + marker fallback.** `setup` probes git + workspace manifests, proposes the
parent and a path-qualified child slug, and the operator accepts/edits/clears before any write — never silent.
The three topologies: (1) **single-git monorepo** — one `.git` at root + a workspace manifest
(`pnpm-workspace.yaml`, `nx.json`, `turbo.json`, `lerna.json`, `go.work`, `Cargo [workspace]`,
`package.json#workspaces`); the package subdir is the child. (2) **git submodule** — parent via
`git rev-parse --show-superproject-working-tree`. (3) **sibling repos under a plain dir** — no git signal →
committed `.sb-monorepo.json` marker at the parent root, else prompt.

1. **Data model (`projects.jsonl`, both fields optional, absent = today's behavior):**
   - `parent: <root-slug>` — the monorepo *root* slug. **Flat single-level** (nearest workspace root; no
     grandparent chains — deeper nesting collapses to the nearest root).
   - `root_path: <abs path>` — lets `resolveActiveSlug` map cwd → the *registered* slug by **longest-prefix
     match**, so single-git-monorepo subdirs stop collapsing to the root basename. Doubles as collision identity.
   - (collision identity also carries `git_remote` — see migration section.)
2. **Path-qualified slug = `<root>__<leaf>`** (double underscore). Only sub-projects are qualified; roots and
   standalones keep bare slugs. Intra-monorepo name clash (two `utils`) → relpath-with-`__` fallback.
3. **Family computation:** `root(X) = X.parent ?? X.slug`; `family(X) = {root} ∪ {Y : Y.parent === root}`
   (parent + all siblings + self). Standalone → `family = {self}` (degenerate = unchanged). **Sibling visibility
   is symmetric** (B↔C).
4. **Search tier** (monotonic insert at `knowledge-search.ts:337`):
   `own(1) > family(2, NEW) > graph-neighbour(3) > global(4) > other-project(5)`. In-scope cutoff `tier≤3 → tier≤4`;
   other(5) dropped unless auto-broaden. Net: B sees **B + parent A + siblings C,D,E + global**, excludes unrelated.
5. **Drain stays narrow (leaf default):** capture → active child's inbox (origin-based, incident fix); maintainer
   stamps drained nodes with the **leaf** facet. Parent is never an auto drain target; cross-family → global
   (empty facet). Family changes what you READ, not where new knowledge is WRITTEN.
6. **Reconciliation (the "Both" projection):** at setup, right after writing `parent`, mirror as a project-level
   `part_of` edge (child-MOC `part_of` parent-MOC) + a `project-registry.jsonl` anchor; the maintainer re-validates
   `projects.jsonl ↔ graph` on its normal cadence (re-parent = invalidate-then-assert, bi-temporal). **Facet-merge
   guard:** scoping reads `projects.jsonl` truth; the graph projection is only for graph-native consumers + history.
   Test must assert a child page's `project:` facet is unchanged after projecting a parent link.
7. **`resolveActiveSlug` gains a registry-path lookup** (approved): reads `projects.jsonl`, longest-prefix-matches
   cwd against `root_path`. New precedence: `CLAUDE_PROJECT_DIR (mapped via registry) > cwd longest-prefix-match on
   root_path > .active-session-slug pin > bare basename`. This is the load-bearing change that makes the resolver
   correct for monorepos (same resolver the 88-doc misroute touched).
8. **Dream:** default mines the **leaf** (`project_slug = resolveActiveSlug()`); `--family` mines the whole family;
   `--slug all` = everything. Consolidation stays project-neutral.

## Migration & setup-collision — RESOLVED (2026-06-18, user-approved)

Grounded by research wf_b48e318c. Key facts: migration files are `skills/upgrade/migrations/<ver>.md`
(`## What changed` + `## Action/idempotent check`, semver-gated by `sort -V`); `knowledge_validate` autofix is
the deterministic shaper (`knowledge-validate.ts`: patchFrontmatter is additive/never-overwrites/uses mtime,
normalizeFrontmatter dedupes keys keeping LAST + re-serializes `related:`/`tags:`, deletes empty pages, never
strips unknown fields); backup-before-user-data is mandatory (`SKILL.md:62-63`). **`projects.jsonl` has NO
normalization migration today** and identity is **basename-only** (`lib.sh:343-353`) — so two different repos
named `utils` silently clobber each other's `PROJECT.md` (confirmed existing bug, the motivation for Layer 3).
`RawItem` (`raw-inbox.ts:8-21`) has **no `origin:` field yet**. `kb-project-suggest.sh` (neighbor-facet
plurality) + `kb-project-backfill.sh` (part_of walk, never-overwrite, reversible) already do the deterministic
core of semantic re-attribution.

**Layer 1 — Deterministic structural (in `/upgrade`, no LLM, idempotent, backup-first).** New migration file
(recommend the next minor shipping M3, e.g. `0.33.0.md`):
- **`projects.jsonl` hardening** — the only rewrite, backed up first: `jq -e '.'` smoke-test; if pretty-printed
  / duplicated / malformed, rewrite to canonical one-record-per-line, dedup by slug keeping newest
  (`group_by(.slug)|map(max_by(.last_session_iso))`). Closes the malformed→silent-no-op / unbounded-duplicate
  risk; folds in a CRLF re-normalize on `PROJECT.md` load (Windows — ties to this branch).
- **Identity/parent fields fill LAZILY, not at upgrade** — can't know a repo's abs path/remote unless we're in
  it. `root_path`/`git_remote`/`parent` populate on the next `session-load`/`setup` per repo; old records work
  as standalone until re-touched.
- **`origin:` on raw items** — additive, read-tolerant (unset = legacy). Migration never invents provenance:
  legacy items without `origin:` drain under the conservative default (current active slug); the drain-guard
  flags rather than silently re-attributes.
- **`knowledge_validate` autofix** runs (idempotent) for frontmatter shape/empties — no facet semantics.
- **Flagged-dir reconciliation = report + confirm, never silent delete:** ensure canonical dirs; if top-level
  `scratch/` or `~/knowledge/raw` exist non-empty, report for confirmed cleanup; `.graph` dropped (non-issue,
  `graph/` is canonical); `regressions/` left as-is (harmless, vestigial).

**Layer 2 — Semantic re-attribution (maintainer's job, OPT-IN — NOT in `/upgrade`).** Assigning `project:` to
old untagged nodes + building `part_of` families needs judgment. `/upgrade` finishes Layer 1 then **prints**
"run `/second-brain:maintain` to attribute untagged nodes and build families" — it does **not** auto-dispatch
the maintainer (user rejected that twice this session; keeps the LLM pass explicit + respects the 50-change
cap). The maintainer gains a backfill mode for the unattributed-KB case (staged, capped, reported), built on
the existing `kb-project-suggest.sh` + `kb-project-backfill.sh`.

**Layer 3 — Setup collision detection (in `/setup`).** Store `{root_path, git_remote}` identity at setup. On an
existing `projects/<slug>/`:
- same remote (or both null + same `root_path`) → **same project** → migrate if old format, else leave alone
  (today's idempotency, unchanged);
- identity differs → **collision** → **prompt** (consistent with detection — never silent): offer
  (i) path-qualified slug `<root>__<leaf>` (monorepo sub-project case), (ii) rename to a user-chosen unique
  slug (standalone collision case — no auto-hashing), (iii) use-existing/abort. Never merge or clobber.

Principles: read-tolerant, additive, backup-before-any-rewrite, fail-loud, never destructive without confirmation.

**Top-level state inventory (migration/cleanup scope).** Canonical hot-tier dirs created by
`scripts/ensure-dirs.sh:8-12`: `projects/`, `transcripts/`, `dreams/`, `wiki-archive/`, `regressions/`.
Cold tier `~/knowledge/`: `wiki/`, `graph/`, `.embeddings`. Verified state (2026-06-18, research wf_b48e318c):
- **used:** `projects/` (per-project hot tier), `transcripts/` (episodic store + dream source), `dreams/`
  (staging, on-demand), `wiki-archive/` (FORGET archive, on-demand), `~/knowledge/wiki` + `graph` + `.embeddings`.
- **`regressions/`** — CONFIRMED vestigial: created by `ensure-dirs.sh:9`, only referenced by the `doubt` skill,
  no active use. Decision: **leave as-is** (empty harmless dir); do not expand migration scope to remove it.
- **top-level `scratch/`** — NOT in the canonical set; stray (or a `tmp.*`→`scratch` project materialized at the
  wrong level). Layer 1 reports it if non-empty for **confirmed** cleanup.
- **`~/knowledge/raw`** — CONFIRMED unused (raw goes to `projects/<slug>/raw/`); a pre-1.0 artifact if present.
  Layer 1 reports it if non-empty for **confirmed** cleanup.
- **`.graph` vs `graph/`** — CONFIRMED non-issue: `graph/` (slash) is canonical, no `.graph` exists in code.
  **Dropped** from migration scope.

## Non-goals

No change to BM25/graph scoring beyond scoping tiers. Not per-project physical wikis — single shared corpus,
scoped by ranking. No *forced/destructive* auto-migration — back-compat reads (old `project:` stays valid)
plus guided/opt-in normalization, never a silent rewrite of user data.

## Implementation plan scope (for `writing-plans`)

Design is complete and approved. Suggested **phasing** (each phase is independently shippable; later phases
depend on earlier data-model changes, so order matters):

- **Phase A — Incident fix (independent, ships value first).** `origin:` field on `RawItem`
  (`raw-inbox.ts` schema + serialize/parse + capture CLIs); capture derives destination from `basename(SCAN_ROOT)`
  and cross-checks `resolveActiveSlug()`, fail-loud on mismatch; `setup/SKILL.md` `cd "$SCAN_ROOT"`; drain
  mismatch guard in the maintainer (Phase 4c); dream default-scope (`project_slug = resolveActiveSlug()`).
- **Phase B — Scoping model (M3).** `projects.jsonl` gains `parent` / `root_path` / `git_remote` (additive);
  `resolveActiveSlug` registry-path longest-prefix lookup (TS + bash parity); path-qualified slugs; family
  computation; family tier inserted at `knowledge-search.ts:337` (cutoff `≤3 → ≤4`); the "Both" reconciliation
  (setup writes parent + projects-level `part_of` edge + registry anchor) with the **facet-merge guard test**;
  `dream --family`.
- **Phase C — Migration & collision.** Layer 1 deterministic migration file (`<ver>.md`: `projects.jsonl`
  hardening + backup, lazy identity fields, `origin:` back-compat, autofix, flagged-dir report); Layer 2
  maintainer backfill mode + the `/upgrade` print-recommendation; Layer 3 setup collision detection (identity
  compare + prompt).

Implementation units (for plan decomposition): `capture-origin`, `drain-guard`, `dream-scope`,
`projects-registry-fields`, `resolve-active-slug-registry`, `family-tier-search`, `reconciliation-projection`,
`migration-layer1`, `maintainer-backfill`, `setup-collision`.

## Status / next step

Design APPROVED across all three blocks. Spec self-review done inline (placeholders, consistency, scope,
ambiguity — see git history of this file). **Next: user reviews this spec, then `writing-plans` to produce the
phased implementation plan.** No implementation until the plan is written and approved.
