# SP-3 — Setup Deep-Scan — Design

**Status:** approved (2026-06-03)
**Vision:** consolidation roadmap — sub-project SP-3 of 6 (SP-0 Four Principles ✓, SP-1 project-scoped serving ✓, SP-2 raw inbox ✓).
**Scope chosen:** *Curated high-signal docs → raw inbox.* The deep-scan walks the repo, selects high-signal knowledge prose, and captures it into the project's raw inbox (`captured_by: setup-scan`) for the maintainer (SP-4) to refine into wiki nodes. Folded into the existing `setup` command (the vision keeps two commands: `setup` + `upgrade`).

---

## Problem

SP-2 built the raw inbox but it starts empty — material only arrives via the manual `/second-brain:capture`. A brand-new project has a wealth of already-written knowledge (README, `docs/`, ADRs, design notes) that should seed the KB. There is no automated producer that surfaces it. SP-3 is that producer: a one-shot, re-runnable deep-scan at setup time.

This must NOT duplicate the existing `track`/doc-sources system, which references existing local docs **in place** (read-only, searchable — SP-1 local-docs). SP-3 instead **captures** curated docs **into** the raw inbox (staging for refinement into wiki nodes). Different job, different destination.

## Goals

1. At setup, find the repo's high-signal knowledge docs and capture them into the active project's raw inbox.
2. Reuse the existing repo-walk + junk/git-ignore filtering (`doc-sources`) rather than re-implementing it.
3. Safe by default: preview before writing, a cap, content-hash dedup on re-run, and secret avoidance (the threat model is credentials-at-risk / supply-chain P0).
4. Stay under the `setup` command (no third command).

## Non-goals (deferred)

- **SP-4** maintainer drain (raw → wiki nodes).
- Non-markdown extraction (PDF/code). SP-3 is markdown-only.
- Auto-registering doc-sources / `track` (the user chose raw-only).
- URL/remote scanning. Local files only (offline-first).

---

## Architecture

```
setup skill ──(after hot-tier scaffold)──▶ raw-scan-cli --dry-run   ▶ preview list (count + paths)
                                              │ (user confirms)
                                              ▼
                                          raw-scan-cli            ▶ captureItem() per candidate
                                                                    ↳ ~/.second-brain/projects/<slug>/raw/
```

The walk + curation + capture live in a pure module (`raw-scan.ts`) behind a thin CLI (`raw-scan-cli.ts`), so the `setup` prompt carries no logic.

### Components (reuse-heavy)

| Unit | Responsibility | Action |
|---|---|---|
| `mcp/src/tools/doc-sources.ts` | export `filterIgnored` for reuse (junk + git-ignore drop) | Modify (1 line) |
| `mcp/src/tools/raw-scan.ts` | pure: `scanCandidates(projectRoot)` (glob → curate → filter → cap); `runScan(projectRoot, brainDir, slug, {dryRun})` (capture via `captureItem`) | Create |
| `mcp/src/tools/raw-scan.test.ts` | vitest | Create |
| `mcp/src/tools/raw-scan-cli.ts` | thin CLI: `--dry-run` (preview) / capture; resolves slug | Create |
| `mcp/package.json` | register the esbuild bundle | Modify |
| `skills/setup/SKILL.md` | new scan step (preview → confirm → capture) | Modify |
| `tests/test-setup-scan.sh` | CLI/skill end-to-end | Create |

---

## Curation heuristic

A repo file is a **candidate** iff it is markdown (`.md`/`.markdown`) AND matches a high-signal include rule:

1. **root-level** `*.md` (e.g. `README.md`, `ARCHITECTURE.md`, `DESIGN.md` at the repo root), OR
2. lives under a **doc directory** — a *directory* segment of its path (case-insensitive, excludes the filename itself) is one of: `docs` `doc` `adr` `adrs` `rfc` `rfcs` `spec` `specs` `decisions` `.ai-docs` `notes`. (So a `notes/` dir is included, but a *file* `src/components/notes.md` is not.) OR
3. **basename** matches (case-insensitive) `README` `ARCHITECTURE` `DESIGN` `CONTRIBUTING` `ROADMAP` anywhere in the tree.

Candidates are then filtered (in order):

- **junk + git-ignored** — `filterIgnored(projectRoot, paths)` (reused from `doc-sources`): drops `JUNK_DIRS` (`node_modules .git .venv venv .next dist build`) and any path `git check-ignore` reports. Degrades correctly outside a git repo (junk-skip only).
- **low-signal denylist** — basename matches (case-insensitive) `CHANGELOG` `LICENSE` `LICENCE` `CODE_OF_CONDUCT` or contains `template`.
- **secret denylist** — path matches (case-insensitive) `.env` `*.pem` `*.key` `id_rsa` `*secret*` `*credential*` (defense-in-depth; markdown secrets are rare but the cost of capturing one is high).

Survivors are sorted byte-stably by path (same as `scanLocations`) and **capped at `SB_SCAN_MAX` (default 50)**. If more than the cap survive, the first `cap` are taken and the remainder count is reported — never silently dropped.

A stray `src/components/notes.md` matches none of the include rules → not a candidate. `CHANGELOG.md` is included by rule 1 (root) then dropped by the low-signal denylist.

---

## Capture flow

`runScan(projectRoot, brainDir, slug, { dryRun })`:

1. `assertSafeSlug(slug)` (reused).
2. `candidates = scanCandidates(projectRoot)` (the heuristic above).
3. If `dryRun` → return `{ candidates, captured: 0, skipped: 0, truncated }` and write **nothing**.
4. Else, for each candidate, `captureItem({ brainDir, slug, kind: 'file', source: <abs path>, capturedBy: 'setup-scan' })`. SP-2's content-hash **dedup** makes a re-scan skip any doc whose content is unchanged and already has an unprocessed raw item (counted as `skipped`). New/changed docs are captured (`captured`).
5. Return `{ candidates, captured, skipped, truncated }`.

`captured_by: 'setup-scan'` is already a valid `CapturedBy` value in SP-2 — no schema change. Items carry no `target_node` (pre-node material; the maintainer creates nodes).

---

## Surface — folded into `setup`

`skills/setup/SKILL.md` gains a step (after the hot-tier scaffold + `projects.jsonl`):

1. Run `raw-scan-cli --dry-run` for the active slug → show the candidate count + paths (and the truncated remainder, if any).
2. Ask the user to confirm capturing them (impactful action → explicit confirm; matches the step-by-step preference for writes).
3. On confirm, run `raw-scan-cli` (capture) → report `captured` / `skipped (already in inbox)` and point to `/second-brain:capture --list`.
4. If zero candidates, say so and skip.

Re-runnable: re-running `setup` re-scans; dedup means only new/changed docs are captured. `SB_SCAN_SKIP=1` (or the user declining at the prompt) skips the scan entirely.

---

## CLI

`raw-scan-cli.ts` (thin, mirrors `raw-capture-cli`):

```
node raw-scan-cli.bundle.js --dry-run   # preview: print "N candidate(s):" + paths (+ truncated note)
node raw-scan-cli.bundle.js             # capture: print "Captured X, skipped Y (already in inbox)."
```

- `projectRoot` = `$SCAN_ROOT` env or `process.cwd()` (setup passes the git root).
- `brainDir` = `BRAIN_DIR` env or `~/.second-brain`.
- slug = resolved like `raw-capture-cli` (`SB_ACTIVE_SLUG` > pin-file + `PROJECT.md` > basename(cwd), rejecting `..`).
- No active slug → print the "cd into a project" message and exit (no capture).

## Error handling

- Unreadable file → `captureItem` throws on read → caught per-file, counted as skipped, scan continues (never aborts).
- Not a git repo → `filterIgnored` junk-skips only (no `git check-ignore`).
- Empty repo / zero candidates → `{ candidates: [], captured: 0 }`; setup reports "nothing to seed".
- No active project → refuse (no global inbox), same contract as capture.
- Cap exceeded → capture the first `cap`, report the remainder (the `track` system can index the rest in place if the user wants them searchable).

## Cross-platform

Glob via the existing `glob` dep (handles separators). Paths via `path`. `filterIgnored` already spawns `git` portably. No bash-only constructs in the module; the `setup` skill's bash stays mawk-safe/portable. Offline (local reads only).

## Testing (TDD)

| Test | Covers |
|---|---|
| `raw-scan.test.ts` (vitest) | curation: includes root `README.md` (rule 1), `docs/guide.md` (rule 2 dir), `docs/adr/ADR-001.md` (rule 2 dir), `src/DESIGN.md` (rule 3 basename); excludes `src/components/notes.md` (file named notes, not a `notes/` dir → no rule matches), `CHANGELOG.md` (root rule 1 but low-signal denylist), a git-ignored `docs/ignored.md`, and `docs/secrets.env` (secret denylist + non-md). Cap at `SB_SCAN_MAX`. `dryRun` writes nothing. capture stamps `captured_by: setup-scan`. re-run dedups an unchanged doc (skipped++). |
| `test-setup-scan.sh` (bash) | CLI `--dry-run` lists candidates without writing; capture writes raw items (grep `captured_by: setup-scan`); re-run is idempotent (count unchanged); `setup/SKILL.md` invokes `raw-scan-cli`. |

## Versioning

Plugin patch bump + migration row (additive; the scan is opt-in via the setup confirm). MCP server stays unchanged (capture/scan ride standalone CLI bundles — no new server tool). Back-compat: existing `setup` runs gain a scan step that previews and only writes on confirm; declining leaves behaviour unchanged.
