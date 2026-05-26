# Design: Maintainer ↔ forgetting coordination (tombstone + auto-restore)

**Date:** 2026-05-26
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Builds on:** `docs/specs/2026-05-26-memory-forgetting-and-eval-design.md` (forgetting shipped in 0.16.0)
**Target version:** 0.17.0

## Summary

Forgetting (0.16.0) added a cold-tier archive (dream Phase 6 → `~/.second-brain/wiki-archive/`)
but left the rest of the knowledge system unaware of it. A pre-release review surfaced
three coordination gaps; this spec closes them so the **knowledge-maintainer is the
structure-aware caretaker** and forgetting is **durable**:

1. **Field mismatch (0.16.0 latent bug).** The forget recall-probe derives its topic
   query from `keywords:`, but the wiki convention is `tags:` (112 live pages use
   `tags:`, 0 use `keywords:`). The probe always falls back to the noisy title on real
   data. → Probe reads `tags:` (then `description:`, then `title:`).
2. **No tombstone → resurrection.** Nothing stops the Stop-hook extractor
   (`merge-project-update.sh`) or LLM writes from re-creating a slug that forgetting
   archived (the archive-log is never consulted). A forgotten page silently returns, so
   forgetting doesn't durably bound growth. → **Auto-restore**: a re-creation attempt
   revives the archived original instead of spawning a duplicate.
3. **Maintainer unaware.** `agents/knowledge-maintainer.md` has zero reference to the
   archive/forget model. → It learns the model: honor the archive, surface forget
   candidates, never archive (the dream stays the sole gated executor).

## Goals

- The forget recall-probe works on real pages (queries from the maintained `tags:`).
- A forgotten page **stays forgotten** unless the topic genuinely resurges — and when it
  does, the **original is revived** (history preserved), not duplicated.
- The maintainer coordinates with forgetting instead of fighting it: it doesn't treat
  archived pages as "missing", it can flag forget candidates, and it never creates a
  second archive path.

## Non-goals (YAGNI)

- **No decaying/time-windowed tombstone.** Auto-restore on demand replaces it.
- **No second archive executor.** Only the dream archives (gated by `dream_accept`).
  The maintainer surfaces candidates; it does not move pages out.
- **No new MCP tool / no new external dep / no build surface.** Pure shell + agent prose.
- **No change to the forgetting scorer's signals** (access/recency/connectivity/category)
  — only the probe *query field* changes.
- **Un-archiving is intentionally NOT gated.** Archiving is destructive → gated by the
  dream review. Restoring is additive/safe → automatic. This asymmetry is by design.

## Architecture — components

### C1. `scripts/wiki-archived-slugs.sh` — net-archived source of truth (NEW)

- Reads `~/.second-brain/wiki-archive-log.jsonl` (append-only; events `archived` /
  `restored`). Computes the **net-archived** set: per slug, the latest event by `date`
  wins; emit those whose latest event is `archived`.
- Modes:
  - (default) print `slug<TAB>category` per net-archived page.
  - `--has <slug>` → exit 0 if net-archived, 1 otherwise (quiet).
  - `--path <slug>` → print the archive file path (`$ARC/<category>/<slug>.md`) or exit 1.
- `jq` over the JSONL: `jq -s 'group_by(.slug) | map(max_by(.date)) |
  map(select(.event=="archived"))'`. Offline; empty/absent log → empty set (exit 0).
- **Single source of truth**: C3, C4, C5 all consult this — no duplicated log parsing.

### C2. Probe field fix — `scripts/wiki-forget-candidates.sh`

- Topic-query derivation becomes: **`tags:`** (strip surrounding `[ ]` and commas) →
  if empty, `description:` → if empty, `title:` → if still empty, treat as archivable
  (the blank-query branch, unchanged). Tags are the field the maintainer optimises and
  the most distinctive per page.
- Update `tests/test-wiki-forget-probe.sh` and `tests/test-wiki-forget-score.sh` fixtures
  to use `tags:` (matching real pages) instead of `keywords:`.

### C3. Extraction auto-restore — `scripts/merge-project-update.sh`

- The script creates wiki pages at two sites: cross-ref stubs (`wiki/entities/<slug>.md`)
  and the `wiki_updates` create action (`<target_dir>/<slug>.md`).
- At **each** site, before creating `<slug>.md` (i.e. when no live page exists), call
  `wiki-archived-slugs.sh --path <slug>`. If it resolves (slug is net-archived):
  `mv` the archived file back to the live wiki path, append a `restored` event to the
  log, then **proceed with the normal merge** — the create becomes an update against the
  now-existing page (new info lands as content); a bare stub becomes a no-op.
- Net effect: the revived page keeps its original history and gains the new delta.

### C4. Write-guard restore+redirect — `scripts/wiki-write-guard.sh`

- Add one narrow check (after the existing frontmatter logic, gated by the same
  `SB_PERSONA_GATE=off` kill switch): when `tool_name=Write`, the path is a wiki page,
  the target file **does not currently exist**, AND the slug is net-archived
  (`wiki-archived-slugs.sh --has`): `mv` the archived file to the path (restore) + append
  `restored` to the log, then **deny** with:
  > `Auto-restored '<slug>' from the cold-tier archive (it had been forgotten). Re-open and Edit it — don't recreate it.`
- This restores the original (history preserved) and redirects the model to Edit the
  revived page. Edits to an existing (now-restored) page are unaffected. The
  frontmatter-enforcement behaviour is otherwise unchanged.

### C5. Maintainer awareness — `agents/knowledge-maintainer.md` (new section)

A new "Cold-tier archive awareness" section so the caretaker knows the 0.16.0+ structure:

- **Archive exists and is intentional.** `~/.second-brain/wiki-archive/<category>/<slug>.md`
  + `wiki-archive-log.jsonl` hold pages forgetting deliberately removed. Archived pages
  are *forgotten, not missing* — never flag them as broken/absent, never resurrect them
  blindly.
- **Before creating a page**, check `wiki-archived-slugs.sh --has <slug>`. If archived,
  `wiki-restore.sh <slug>` (revive the original) and **Edit** it rather than creating a
  duplicate.
- **Surface forget candidates** (read-only): the maintainer MAY run
  `wiki-forget-score.sh` and report the lowest-scoring pages in its summary as "forget
  candidates for the next dream." It **never archives** — archiving is the dream's sole,
  gated job (`dream_accept`).
- Cross-references the forgetting design so the model has the full picture.

### C6. Tests

- `tests/test-wiki-archived-slugs.sh` — log with archived+restored events → correct net
  set; `--has` / `--path` exit codes; empty/absent log → empty.
- `tests/test-merge-auto-restore.sh` — a fixture wiki + archive + log; run
  `merge-project-update.sh` with a delta that would create an archived slug → assert the
  archived file is moved back (revived, no duplicate) and a `restored` event logged.
- `tests/test-wiki-write-guard.sh` (extend existing if present, else new) — a Write to an
  archived slug's absent path → assert restore happened + decision is `deny` with the
  redirect message; a Write to a non-archived new page → unaffected (frontmatter rule
  only).
- Probe-tags assertions folded into the updated `test-wiki-forget-probe.sh` /
  `test-wiki-forget-score.sh`.
- `tests/test-maintainer-archive-aware.sh` — structural: the maintainer agent references
  the archive, `wiki-archived-slugs.sh`/`wiki-restore.sh`, "surface … candidates", and
  "never archive".

## Data flow

- **Forget (unchanged):** dream Phase 6 → `wiki-forget-candidates.sh` → manifest →
  `dream_accept` archives + appends `archived` to the log.
- **Resurrection attempt → auto-restore:**
  - extraction: `merge-project-update.sh` create site → `wiki-archived-slugs.sh --path`
    → `mv` back + `restored` log → normal merge.
  - LLM Write: `wiki-write-guard.sh` → `wiki-archived-slugs.sh --has` → `mv` back +
    `restored` log → deny+redirect to Edit.
- **Probe:** `wiki-forget-candidates.sh` query now from `tags:`.

## Error handling / safety

- Archiving stays gated (dream review); restoring is automatic and non-destructive.
- `wiki-archived-slugs.sh` on a missing/empty/corrupt log → empty set (fail-open: never
  blocks a create spuriously). A create is only ever *redirected/skipped* when a slug is
  confidently net-archived AND its archive file exists.
- If the archive file is missing for a net-archived slug (manual deletion), treat as
  not-archived (allow the create) — never error the extraction/write path.
- All moves are `mv` (reversible) + logged. Kill switches: `SB_WIKI_FORGET=off`
  (forgetting), `SB_PERSONA_GATE=off` (write-guard).

## New / changed files

| Path | Kind | Change |
|------|------|--------|
| `scripts/wiki-archived-slugs.sh` | new | net-archived source of truth |
| `scripts/wiki-forget-candidates.sh` | edit | probe query: `tags:`→`description:`→`title:` |
| `scripts/merge-project-update.sh` | edit | auto-restore at both create sites |
| `scripts/wiki-write-guard.sh` | edit | restore+deny on Write to an archived slug |
| `agents/knowledge-maintainer.md` | edit | "Cold-tier archive awareness" section |
| `tests/test-wiki-archived-slugs.sh` | new | helper behaviour |
| `tests/test-merge-auto-restore.sh` | new | extraction revive path |
| `tests/test-wiki-write-guard.sh` | new/edit | tombstone restore+deny |
| `tests/test-wiki-forget-{probe,score}.sh` | edit | `tags:` fixtures |
| `tests/test-maintainer-archive-aware.sh` | new | structural guard |
| `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md` | edit | 0.17.0 + migration row |

## Open risks / verify-first (for the plan)

- **`merge-project-update.sh` is hot-path + already complex.** The auto-restore insertion
  must be minimal and not change behaviour when the log is empty/absent (the common
  case). Verify with the existing `test-merge-project-update.sh` staying green.
- **Write-guard side-effect in a PreToolUse hook.** Performing a `mv` inside the hook
  before denying is unusual but sound (the hook is a script). Verify the hook still
  exits 0 and emits valid decision JSON, and that the `mv`-then-deny leaves a consistent
  state (page present, write rejected, Claude edits next).
- **Tag parsing.** `tags: [a, b, c]` vs `tags: a, b` — the probe must strip brackets and
  commas robustly; verify against real frontmatter.

## Decision log

1. Tombstone policy = **auto-restore on re-creation** (revive the original, no duplicate),
   not a hard block or a decaying window.
2. Write-tool path = **restore + redirect to Edit** (a deny/allow hook can't merge).
3. One archive executor (the dream); the maintainer only **surfaces** candidates.
4. Un-archiving is **un-gated** (additive/safe); archiving stays gated.
5. Probe query field = `tags:` (the maintained field) → description → title.
6. Single net-archived helper (`wiki-archived-slugs.sh`) consumed by all chokepoints;
   fail-open on a missing/corrupt log.
