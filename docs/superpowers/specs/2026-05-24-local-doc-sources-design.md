# Local Doc-Source Awareness — Design

- **Status:** Draft for review
- **Date:** 2026-05-24
- **Scope:** A sibling/extension of the context-aware memory egress subsystem (`2026-05-24-context-aware-memory-egress-design.md`). Makes the persona aware of *local project documentation* outside the wiki, so it can POINT Claude to it. Architecture **B** (per-project registry) chosen during brainstorming.

---

## 1. Summary

Let the user **declare once** where a project's docs live (`docs/`, `.ai-docs/`, or a glob/format), and have the second brain **auto-track** them: a SessionStart scan reconciles a per-project registry of lightweight pointer-entries (gist + path + content-hash). Those entries are **merged into `knowledge_search` for the active project**, so when Claude looks for information that lives in local docs, the brain returns *where to find it* (path + gist) and Claude reads the file on demand. Lifecycle is kept honest every session: file **moved → path updated**, **removed → entry dropped**, so search never points at a dead/stale location.

This is the **POINT** principle applied to a new *source*: referenced (not owned), gist + pointer, full content stays in the file. Nothing is duplicated, so nothing can drift.

## 2. Goals / Non-goals

**Goals**
- One-time, explicit user declaration of doc locations (folder or glob); zero auto-guessing of folders.
- Automatic, deterministic (no-LLM) tracking with full add/update/**move**/**remove** reconciliation.
- Doc sources are **query-matchable** in `knowledge_search`, ranked alongside wiki, **scoped to the active project**.
- `knowledge_fetch` can serve a doc source's gist/skeleton and read its full body on demand.
- Never surface a path that no longer resolves.

**Non-goals**
- No proactive per-prompt POINT injection in this phase — that rides on the Phase-4 POINT rework for free once doc sources appear in `knowledge_search` results.
- No content duplication / no LLM summaries of docs (the file is the full tier).
- No cross-project bleed (a registry is per-project).
- No full `.gitignore` semantics in v1 (skip obvious junk; see §7).

## 3. Design

### 3a. Registration (declare once)
Per-project config: `~/.second-brain/projects/<slug>/doc-sources.config.json`
```json
{ "locations": ["docs/", ".ai-docs/", "notes/**/*.mdx"] }
```
Each entry is a **folder** (default glob `**/*.md` within) or an explicit **glob** (covers "by format"), relative to the project root. Managed via the existing `bin/sb` CLI:
- `sb track <path|glob>` — append a location to the active project's config
- `sb track --list` — show tracked locations + current entry count
- `sb untrack <path|glob>` — remove a location

The config is plain JSON the user may also edit directly.

### 3b. Registry (machine-managed)
`~/.second-brain/projects/<slug>/doc-sources.json` — never hand-edited:
```json
{ "generated_at": "<iso>", "project": "<slug>",
  "entries": [
    { "id": "<sha256[:12]>", "path": "/abs/.../docs/deploy.md", "rel": "docs/deploy.md",
      "gist": "How to deploy to the Pi", "headings": ["## Prereqs", "## Steps"],
      "hash": "<sha256>", "mtime": "<iso>", "size": 1843 } ] }
```
`id` is derived from the content hash so it's stable across moves. `gist` = first `#` heading / frontmatter `title` / first non-empty line (deterministic).

### 3c. Discovery scan + lifecycle (the core)
Implemented as a **TypeScript module** `mcp/src/tools/doc-sources.ts` (so the reconciliation logic is unit-testable) plus a bundled CLI `doc-sources-cli` invoked at SessionStart by a thin `scripts/discover-doc-sources.sh` (registered in `hooks.json` SessionStart, after `discover-installed.sh` — mirrors the existing `discover-*` precedent). Per run, for the active project (slug resolved from CWD):
1. Read config locations; enumerate matching files via `glob`; **skip `node_modules/`, `.git/`, `.venv/` and dotfile dirs**.
2. Per file: SHA-256 of content + `gist` + `##`/`###` `headings`. No LLM.
3. **Reconcile** scanned set against the existing registry:
   - path new → **add**
   - path present, hash changed → **update** gist/headings/hash/mtime
   - hash matches an entry whose old path no longer exists → **moved → update path/rel**
   - registry entry whose path is gone and whose hash isn't found elsewhere → **removed → drop**
4. Atomic write of `doc-sources.json`. **Fast-path:** skip the whole scan when nothing under the tracked locations is newer than the registry (`find -newer`, like `discover-installed.sh`).

### 3d. Retrieval integration (scoped to active project)
- **`knowledge_search`** (server resolves the active project slug from `process.cwd()` and `BRAIN_DIR`): load that project's `doc-sources.json`, score each entry with the **same BM25** over `gist + headings`, and merge into the candidate list tagged `source: "local-doc"`, carrying the real `path`, a `tokens` estimate (from `size`), and `description` = `gist`. Result: a query like "deploy" returns `docs/deploy.md` ranked with wiki hits. Wiki candidates are unchanged (`source` defaults to `"wiki"`).
- **`knowledge_fetch`**: when a slug/path resolves to a registry entry (checked when the wiki glob misses, or via a `source` hint): `gist`/`skeleton` from registry fields; `summary` falls back to skeleton (or the file's own `## Summary` if present); `full` = **read the actual file**, GUARD-capped (`capText`), with a `Read <path>` pointer. If the file vanished since the scan → return a "source moved/removed — re-scan" message (defensive; the next SessionStart scan reconciles).
- **POINT**: deferred. Once doc sources are in `knowledge_search` results, the Phase-4 POINT rework injects relevant ones per-prompt with no extra work here.

## 4. Decisions
- **D-1 — Architecture B (per-project registry), not global wiki nodes.** Docs are project-scoped; a per-project registry avoids cross-project search bleed and keeps the curated wiki (and the maintainer) untouched.
- **D-2 — Explicit one-time declaration**, no auto-discovered default folders. Zero surprise; nothing scanned until the user `sb track`s it.
- **D-3 — Content-hash drives move detection.** Same hash at a new path = moved (preserve the entry/id); reused from the egress spec's content-addressing idea.
- **D-4 — Deterministic gist, no LLM.** Keeps the scan cheap and offline; matches "serving is deterministic."
- **D-5 — Reconciliation logic in a testable TS module**, invoked by a thin SessionStart shell hook (mirrors `episodic-index-cli` invoked from the Stop hook).

## 5. Components / file structure
- `mcp/src/tools/doc-sources.ts` — config read, scan, gist/headings extraction, **reconcile**, registry read/score helpers. One responsibility: the doc-source registry.
- `mcp/src/tools/doc-sources-cli.ts` — CLI entry (scan + write), added to the esbuild bundle list in `mcp/package.json`.
- `scripts/discover-doc-sources.sh` — SessionStart hook: resolve slug, fast-path check, invoke the CLI. Registered in `hooks.json`.
- `mcp/src/tools/knowledge-search.ts` — merge active-project registry entries into candidates.
- `mcp/src/tools/knowledge-fetch.ts` — resolve doc-source entries (registry) in addition to wiki pages.
- `bin/sb` (+ `sb-entry.ts`) — `track` / `track --list` / `untrack` verbs.

## 6. Out of scope / boundaries
- Maintainer agent: **no change** — the registry lives outside `~/knowledge/wiki/`.
- Proactive POINT injection of doc sources → Phase 4.
- LLM summaries of docs; full `.gitignore` parsing (v1 skips obvious junk only).

## 7. Risks & trust
- **Local-only reads** of *user-declared* locations; no network. Content is trusted-by-declaration (the user chose the folder).
- v1 skips `node_modules/.git/.venv/` + dotfile dirs but does **not** parse `.gitignore` fully — so a tracked folder containing a git-ignored secret file matching the glob *could* be indexed (gist only, not content). Mitigation: declare narrow locations; honoring `.gitignore` is a noted enhancement. Flagged because the threat model is credential-sensitive.
- Stale-path safety is structural: every SessionStart reconciles, and `knowledge_fetch full` re-checks file existence at read time.

## 8. Testing
- **`doc-sources.ts` (vitest):** config parse; scan over a temp tree (gist/headings/hash extraction); reconcile — add, update-on-hash-change, **move (same hash, new path)**, remove (path gone); junk-dir skipping; fast-path no-op.
- **`knowledge_search` (vitest):** active-project registry entries surface as `local-doc` candidates, scored/ranked with wiki; another project's registry does **not** leak in.
- **`knowledge_fetch` (vitest):** registry resolution for gist/skeleton/full; vanished-file defensive path.
- **`sb track` (shell):** add/list/untrack mutate the config correctly.

## 9. Phasing (for the plan)
1. `doc-sources.ts` module — config + scan + gist/headings + **reconcile** + registry read/score (TDD, the testable core).
2. `doc-sources-cli` + `discover-doc-sources.sh` SessionStart hook + bundle wiring + fast-path.
3. `knowledge_search` merge (project-scoped) + `knowledge_fetch` registry resolution.
4. `sb track`/`--list`/`untrack` CLI verbs.

## Open items for reviewer
- `sb track` UX: is a CLI verb the right registration surface, or do you prefer a `/second-brain:track` skill (or both)?
- v1 `.gitignore` handling: accept "skip obvious junk only" for now, or require full `.gitignore` honoring given the threat model?
- Should `knowledge_fetch full` for a doc source be capped by the egress budget (consistent with wiki) or returned whole (it's a file the user explicitly tracks)?
