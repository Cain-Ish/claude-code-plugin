# Knowledge-Base Hierarchical Organization — Design

- **Status:** Draft (brainstormed 2026-06-02; web-researched; pending user spec review)
- **Target release:** plugin 0.23.0 (additive, flag-gated, back-compat; MCP server bump for the new projection)
- **Decision lineage:** extends `decisions/graphiti-graphrag-evaluation-2026-06-01` (LazyGraphRAG / deterministic-write stance). Honors memory `project_kb-main-groups-heterogeneous`, `feedback_source-over-symptom`, `project_validate-real-capability`.

---

## 1. Problem

The knowledge base reads as a flat hairball, two user-visible symptoms, one root cause.

**Symptom 1 — "every node connects to the index."** `wiki/index.md` is a flat catalog that `[[wiki-links]]` all ~108 pages. A markdown graph viewer (Obsidian-style) renders it as a 108-edge hub that drowns the real structure. (The bi-temporal edge log already *excludes* index, so this is a markdown-viewer gap, not an edge-log node.)

**Symptom 2 — "siblings that share a parent are separated."** Pages are organized **only by note TYPE** (`wiki/{concepts,decisions,entities,issues,learnings,security,state}/`). A single effort's notes scatter across type-folders with nothing grouping them. Evidence: `kiri-*` = 8 pages all in `decisions/` but only loosely tied; `cainish-bridge-*` = 3 pages with **zero** grouping edges.

**Root cause (one).** Hierarchy lives in the **edge log**, but it is *drowned and unsurfaced*:
- Active edge mix is **461 `relates` : 9 `part_of` : 4 `supersedes` : 4 `requires` : 1 `affects`** — ~96% untyped `relates`. The real `part_of` tree (`kiri-* → kiri-core-design → kiri-redesign`) is 2% of edges, invisible in the noise.
- There is **no `project:` facet**, so nothing groups a project's pages across type-folders.
- The only navigation surface (`index.md`) is a flat by-type catalog, not a hierarchy.

So the fix is **not** to re-file notes by hand (or by folder). It is to (a) make the latent hierarchy *first-class and surfaced*, and (b) make every editing skill *preserve* it automatically — fix the source, not the symptom.

## 2. Goals / Non-goals

**Goals**
- Group a project's scattered pages under one navigable home **without moving any file**.
- Replace the flat index hub with a shallow (2–3 level) navigable structure a graph viewer renders as clusters.
- Make structure a **deterministic projection of the edge log + frontmatter**, regenerated idempotently — so every editing skill preserves it by keeping edges + facets correct, not by curating layout.
- Keep the plugin's **search / read / write contract per main group** intact (the heterogeneous-groups invariant).
- Offline-first, deterministic where possible; LLM reserved for genuinely fuzzy judgment, gated by staging.

**Non-goals**
- No physical re-foldering into `projects/<x>/` (PARA hard hierarchy) — rejected (see §11).
- No positional / Johnny-Decimal / folgezettel numbering — rejected (paper-box artifact).
- No graph database, no new embeddings dependency for structure.
- No change to the type-folder vocabulary (the 8 types stay the enumerative backbone).

## 3. Design principles (the consensus from the web sweep)

1. **Files stay flat.** The type-folder is the single physical home = "what kind of note." Placement is incidental; links/edges are load-bearing (Zettelkasten/Matuschak). Slugs are the stable address; moving folders is never required.
2. **Hierarchy is a soft overlay in edges + frontmatter**, projected — never placed.
3. **Everything structural is a projection of the append-only edge log**, regenerated idempotently each reindex (`index.md`, `## Dependencies`, `related:`, and the new MOC pages). Source of truth = `edges.jsonl` + page frontmatter. Divergence = auto-detectable drift.
4. **Two clustering tiers** (Zep-validated over Leiden for incrementality): cheap **on-write** assignment preserves structure per edit; the nightly **dream** is the authoritative full recompute that corrects drift.
5. **Closed vocabulary, enforced.** 8 fixed types + a known project registry; a deterministic post-filter the LLM cannot bypass, so types/projects can't drift at the source.
6. **Safeguards tier by blast radius.** Reversible projections apply automatically; identity-changing edits (re-type, merge, re-parent, delete) **stage** through the dream snapshot→diff→accept flow; supersede-don't-delete everywhere.
7. **Main groups may differ** (memory `project_kb-main-groups-heterogeneous`): wiki gets the project/theme MOC overlay; learnings stay a flat pattern list; themes stay emergent; graph is the source of truth; episodic stays time-series. Uniform plugin access contract over differently-shaped groups.

## 4. The model

### 4.1 Two complementary grouping primitives
- **`project:` frontmatter facet** (flat membership) — *which* project a page serves (e.g. `project: kiri`). Optional; a page may also carry an `area:` facet for cross-cutting concerns (e.g. `area: security`). Drives MOC membership and index grouping. A page appears in its type-folder AND its project MOC AND its area MOC — one home, many indexes.
- **`part_of` edges** (intra-group depth) — explicit parent/child (`kiri-core-design --part_of--> kiri-redesign`). Drives the rendered tree and is ground-truth for clustering. Already exists; under-populated.

The two are independent: `project:` gives flat membership cheaply; `part_of` gives depth where it's known. Both project into the MOC.

### 4.2 Project registry (the assignment source — decision: registry + LLM fallback, staged)
- A small **project registry** seeds known project slugs. Seed from the existing `~/.second-brain/projects.jsonl` (session/work projects) **plus** explicit topical anchors that already exist as pages (e.g. `kiri-redesign`, `cainish-bridge-design`). Stored as a closed list the classifying skills read.
- **Deterministic path:** a page whose frontmatter/edges already name a known project → assigned deterministically (no LLM).
- **Fuzzy path:** a new/unlabeled page → the `knowledge-maintainer` proposes a `project:` via **edge-neighbor plurality vote** (assign to the project held by the majority of its `part_of`/`relates` neighbors; stable created-date tie-break; no-op if it has no edges). Proposals are **staged** (dream snapshot→diff→accept), never silently applied.
- No slug-prefix heuristics (research-rejected: brittle, misgroups non-prefixed members).

### 4.3 MOC (Map of Content) pages — the navigation overlay
Two kinds, both **generated / FORGET-protected / regenerable**, each its own main group:
- **Project MOCs** — `wiki/projects/<project-slug>.md`. Deterministic. Membership = all pages with `project: <slug>` (+ `part_of` descendants). Generated by reindex **only when the project has ≥ `SB_MOC_MIN_MEMBERS` (default 3)** pages (anti-sprawl gate). Body: a `<!-- moc:begin -->`…`<!-- moc:end -->` region listing members grouped by type, with the `part_of` sub-tree rendered; an optional LLM prose summary (dream-authored, content-hash-gated). Membership is the `project:` facet (a query), **not** a synthetic edge to the MOC slug — so the MOC has no chicken-and-egg with its own member edges.
- **Theme MOCs** — `wiki/themes/theme-<id>.md` (already exist). Emergent. Membership = deterministic label-propagation clusters of the link graph (dream SUMMARIZE). Unchanged except: excluded from being treated as hub nodes (§4.5) and fed by the cleaner edge mix (§4.4).

MOC pages hold **no source of truth** — safe to overwrite every reindex; the edge log + facets are authoritative.

### 4.4 Reducing the `relates` hairball
- **Membership is the `project:` facet, not an edge** — so no synthetic membership edges are added (this is the chicken-and-egg fix; the facet is a query, the MOC need not pre-exist). The hairball shrinks two ways: (1) project membership is recorded as the facet instead of a flat `relates`, and (2) the extractor/maintainer **promote genuinely parent/child `relates` → `part_of`** where real hierarchy is determinable (e.g. a sub-design that *is part of* a parent design). All `part_of` edges remain **page→page** and resolve to real pages — no synthetic project node, so the `merge-edges.sh` `resolves()` guard is satisfied.
- Existing junk-`relates` cleanup is out of scope here (covered by the 0.22.4 importer hardening + the optional live invalidate).

### 4.5 De-hubbing the index
- `wiki/index.md` becomes a **thin two-tier Home**: links to project MOCs + theme MOCs + per-type counts (NOT 108 flat page links). The full per-type catalog moves *into* the MOCs / a collapsed secondary section.
- Mark generated catalog/MOC pages `graph: exclude` in frontmatter and render their catalog rows as **plain text (no `[[wikilinks]]`)** so a markdown graph viewer never treats them as hubs. (The edge log already excludes index; this closes the viewer gap.)
- Clustering input **excludes** index/MOC/hub nodes so communities form from real edges, not the catalog.

## 5. Projection mechanism (reindex — the deterministic core)

`knowledge_reindex` (and `graph-project.ts`) extend their existing "project edges → `related:` + `## Dependencies`" step to also emit:
1. **Project MOC pages** — for each registry project with ≥ threshold members: write/overwrite `wiki/projects/<slug>.md` marked region (deterministic membership; LLM prose only via dream, hash-gated).
2. **Two-tier `index.md`** — Home grouped by project MOC / theme MOC / type-count, de-hubbed.
3. **`graph: exclude` markers** on generated catalog/MOC pages.

Idempotent: same edges + facets ⇒ byte-identical output. A `reindex --check` (drift detector) reports any page whose projected region is stale (CI/lint hook).

## 6. On-write structure preservation (the source fix)

Each editing skill keeps edges + facets correct so structure re-emerges; none hand-curates layout:
- **Extractor** (`merge-edges.sh` + `merge-project-update.sh`): when it creates/updates a page that names a known project, set the `project:` facet (deterministic); emit `part_of` only for real page→page hierarchy (never as a synthetic membership edge). Forbidden from rewriting existing pages' identity (type/project) — that stages.
- **knowledge-maintainer**: Phase adds **project reconciliation** — for unlabeled pages, plurality-vote a `project:` proposal (staged); promote shared-project `relates` → `part_of`; keep MOC membership coherent. Reads the closed registry; cannot invent project slugs.
- **dream**: authoritative full recompute — re-runs label-propagation (themes), recomputes project membership from the registry, authors MOC prose (hash-gated, capped per dream), all on the staging copy, reviewed at `dream_accept`.
- **reindex**: pure projection (§5).
- **lint** (`/second-brain:lint`): **fails** a page that declares `project: <known>` but lacks the `part_of` edge (or vice-versa), and reports MOC drift — structure enforced by construction.

## 7. Safeguards (tier by blast radius)

| Edit class | Mechanism |
|---|---|
| Reversible projection (MOC, index, `related:`, `## Dependencies`) | auto-apply at reindex; idempotent; drift-detectable |
| New `project:`/`part_of` on an unlabeled page | maintainer proposes → **staged** (dream diff → accept) |
| Identity change (re-type, merge, re-parent, delete) | **must** stage through snapshot→diff→accept; extractor forbidden from it |
| Edge retirement | supersede-don't-delete (append-only invalidate; replay to any `as_of`) |

Closed-vocabulary post-filter: a classifying skill's output is intersected with {8 types} ∪ {registry projects} ∪ {existing tags}; anything else is dropped, not written.

## 8. Per-main-group treatment (heterogeneous, uniform contract)

| Main group | Internal structure | Plugin search/read/write |
|---|---|---|
| **wiki** (concepts/decisions/entities/issues/security/state) | flat type-folders + soft project/area MOC overlay (this spec) | `knowledge_search` (BM25), Read, write via extractor/maintainer/dream (staged for identity) |
| **learnings** | flat imperative-pattern list (no project MOC) | same search; appended by `/second-brain:improve` |
| **themes / projects (MOCs)** | generated, regenerable, FORGET-protected, `graph: exclude` | searchable like pages; written only by reindex/dream projection |
| **graph** (`edges.jsonl`) | append-only bi-temporal log — **source of truth** | `knowledge_relate` / `knowledge_neighbors`; never hand-edited |
| **episodic** (`transcripts/`) | time-series | `episodic_search` / `episodic_read`; appended by capture |
| **hot tier** (USER.md, PROJECT.md) | working context | `pin_to_*`; session-load injection |

## 9. Files touched (anticipated)

- `mcp/src/tools/knowledge-reindex.ts`, `mcp/src/tools/graph-project.ts` — MOC + two-tier index projection; `--check` drift mode.
- `mcp/src/tools/graph-cluster*.ts` — exclude hub/MOC nodes from clustering input.
- `mcp/src/tools/knowledge-validate.ts` — `projects` category; `graph: exclude`; project↔part_of coherence.
- `scripts/merge-edges.sh`, `scripts/merge-project-update.sh` — `project:` set + `part_of` promotion on write; closed-vocab filter.
- `agents/knowledge-maintainer.md` — project reconciliation phase (plurality-vote, staged).
- `agents/dream-runner.md`, `skills/dream/SKILL.md` — MOC prose authoring (hash-gated); project recompute on staging.
- `skills/lint/SKILL.md` — project↔part_of + MOC-drift checks.
- `scripts/session-load.sh` — consume the two-tier index; project-MOC neighbourhood injection.
- A project-registry helper (`scripts/lib.sh` or a small CLI) reading `projects.jsonl` + anchors.
- `mcp/src/server.ts` — version bump.
- Tests for every above (see §10).

## 10. Testing strategy (validate the real capability — memory `project_validate-real-capability`)

Gates must test the *real* thing, not a proxy:
- **Projection idempotency:** reindex twice ⇒ byte-identical MOC/index (golden-file).
- **MOC membership correctness:** a fixture with `project: kiri` pages across 3 type-folders ⇒ `projects/kiri.md` lists exactly them, grouped by type, with the `part_of` sub-tree; the ≥3 gate suppresses a 2-page project.
- **De-hub:** `index.md` carries `graph: exclude` and has no `[[wikilinks]]` rows; clustering input excludes it.
- **On-write preservation:** extractor creating a known-project page sets the `project:` facet (membership is the facet, not a flat `relates` edge) and promotes only real page→page hierarchy to `part_of`; RED against current.
- **Plurality-vote:** deterministic (stable tie-break) — same input ⇒ same proposal; no-op with no edges.
- **Closed-vocab filter:** a bogus project/type from a skill is dropped, not written.
- **Staging:** an identity change is staged, not auto-applied; reversible.
- **Knowledge-eval regression:** existing `test-knowledge-eval.sh` recall@2 + token budget must not regress (the overlay must help, not bloat, retrieval).
- **Per-group contract:** plugin search/read/write still works on each main group after the change (the heterogeneous invariant).

## 11. Rejected alternatives

- **(B) PARA folder re-home** (`wiki/projects/kiri/…`): all five research facets reject it — breaks the slug/type-folder invariant every skill assumes + the auto-restore log, churns 100+ files, and a single-home folder can't express a note that serves multiple projects/areas.
- **(C) Tags-only** (project tags + faceted index, no MOC, no `part_of` promotion): doesn't reduce the `relates` hairball, gives no navigable parent node, and leaves the index hub flat.
- **Johnny-Decimal / folgezettel numbering:** positional numbers are brittle in an append-only machine-grown corpus; the Zettelkasten literature shows numbering was an incidental paper artifact — links/registers were load-bearing.
- **Leiden / heavyweight community libs, A-MEM neighbor-rewriting:** fight the offline/deterministic constraint; the existing deterministic label-propagation is the validated choice.

## 12. Rollout & back-compat

- **Additive + flag-gated.** New behavior guarded by `SB_KB_MOC` (default on), `SB_MOC_MIN_MEMBERS` (3), and reuses `SB_DREAM_SUMMARIZE`. With no `project:` facets and no registry, output is the current flat index (back-compat).
- **No file moves, ever** → reversible by construction. MOC/`projects/` pages are generated; deleting them + reindex restores prior state. `project:`/`part_of` are append-only edges (invalidate to undo).
- **Migration:** one-shot, idempotent, opt-in: seed the registry, backfill `project:` for pages matching known anchors, promote shared-project `relates`→`part_of` (staged for review). Safe to skip — structure simply starts accruing from new edits.
- Ships through the deep-review release gate (memory `feedback_deep-review-release-gate`) + full suite.

## 13. Implementation phasing (single spec, staged plan)

Although specced as one system, the plan sequences it to ship value early and bound blast radius:
- **Phase 1 — visible wins (deterministic, low risk):** `project:` facet + registry seed + `part_of` promotion on write + reindex projects project-MOCs (≥3 gate) + de-hubbed two-tier index + `graph: exclude`. Tests for projection idempotency, MOC membership, de-hub.
- **Phase 2 — drift correction & emergence:** maintainer project-reconciliation (plurality-vote, staged) + dream MOC prose (hash-gated) + super-theme tier + clustering hub-exclusion. Tests for plurality determinism, staging, eval-regression.
- **Phase 3 — enforcement:** lint project↔part_of + MOC-drift gate + `reindex --check` drift detector + closed-vocab post-filter hardening. Tests for lint RED-on-violation, closed-vocab drop.

## 14. Open risks

- **MOC sprawl** if the ≥3 gate is too low / projects too granular → tune `SB_MOC_MIN_MEMBERS`; theme MOCs absorb the long tail.
- **Plurality mis-assignment** on sparse graphs → no-op with no edges; staged for human accept; reversible.
- **Two-tier index parsing** — `session-load.sh` and any `index.md` consumer must handle the new format (covered by tests; the format is additive — counts + MOC links).
- **Registry seed quality** — `projects.jsonl` holds work-dir projects, not topical ones; the seed must include topical anchors (kiri, cainish-bridge, wireguard, supplychain). One-time curation, then automatic.
