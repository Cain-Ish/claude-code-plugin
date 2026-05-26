# Design: Principled forgetting + memory-quality eval

**Date:** 2026-05-26
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session

## Summary

Two coupled memory-health features, grounded in 2026 SOTA (SCM/SAGE forgetting,
mem0 evaluation benchmarks), built to the plugin's constraints (offline-first, no
new external deps, supply-chain-cautious, Pi 5 host):

1. **Principled forgetting** — a new `FORGET` phase in the **dream** consolidation
   cycle that composite-scores each cold-tier wiki page on offline signals and
   **stages archive proposals** for the lowest-value pages, so the wiki *plateaus*
   instead of growing unbounded. Archiving is a reversible move applied only on
   `dream_accept` (the existing review gate = the user's "no destructive op without
   confirmation" rule).
2. **Memory-quality eval** — a deterministic recall@k + token-cost test over a
   committed fixture corpus (release gate in `tests/run-all.sh`), plus a **live
   recall-probe** the FORGET phase runs before archiving any page (the safety net
   that stops forgetting from silently degrading recall).

The two share one recall implementation (`scripts/wiki-recall-check.sh`), used as a
gate against fixtures and as the live probe against the real wiki.

## Why now / problem statement

The **hot tier** (`USER.md` + `PROJECT.md`) already has bounds (66-line cap, >30d
staleness flag, `[stale]`→archive). The **cold-tier wiki (`~/knowledge/wiki/`) has
none** — it grows without limit, and `knowledge_search` quality is never measured.
mem0's 2026 review names exactly these as production gaps: *memory staleness* and
*application-level evaluation*. SCM shows a principled forgetting cycle yields
**90.9% noise reduction with preserved recall** and a memory graph that *plateaus*.

## Goals

- Bound cold-tier wiki growth via a **reversible, reviewed** forgetting pass.
- Never archive a page that is the **unique answer** to a representative query
  (recall-protected).
- Make `knowledge_search` quality **measurable** (recall@k + token cost) and
  **gated** so ranking/forgetting changes can't silently regress it.
- Work **offline**: scoring uses filesystem signals only (no embeddings); the recall
  probe uses BM25 (text search works without vector deps).

## Non-goals (YAGNI)

- **No embedding-based novelty scoring.** SCM uses it; we deliberately omit it so
  forgetting never depends on the `@huggingface/transformers` dep that vanishes on
  every cache refresh. Robust filesystem signals only.
- **No auto-delete and no auto-archive-without-review.** Forgetting only ever
  *stages* proposals; `dream_accept` applies them; `dream_discard` keeps everything.
- **No hot-tier changes.** USER.md/PROJECT.md bounds already exist; out of scope.
- **No new runtime dependency, no new MCP tool, no node/TS build surface.** Pure
  shell + the existing `knowledge-search-cli`.
- **No live-wiki release gate.** The gate runs on a fixed fixture corpus (the live
  wiki is non-deterministic); the live measurement is the per-candidate probe only.

## Background (verified during design)

- `mcp/dist/tools/knowledge-search-cli.bundle.js` reads `process.argv[2]` as the
  query and honors `KNOWLEDGE_DIR` (corpus override) + `KNOWLEDGE_MIN_SCORE`. So both
  the fixture gate and the live probe use the same CLI, just different `KNOWLEDGE_DIR`.
- The **dream** has a staging→review lifecycle (`dream_accept` / `dream_discard`) and
  a 5-phase wiki consolidation (Step 2 of `skills/dream/SKILL.md`); FORGET becomes a
  6th phase whose changes land in the dream diff like any other.
- The **knowledge-maintainer** handles hot-tier staleness + wiki Relate/Enrich/Reindex
  but has **no cold-tier prune-to-size phase** — the gap this fills.
- `~/.second-brain/access-counts.json` exists but may be sparse/empty → scoring treats
  a missing count as 0 and leans on the other signals.

## Architecture — components & interfaces

### C1. `scripts/wiki-recall-check.sh` (shared recall implementation)

- **Purpose:** measure retrieval quality of `knowledge_search` over a corpus.
- **Usage:** `wiki-recall-check.sh --corpus <dir> --queries <file.jsonl> --k <N> [--gate]`
  - `--corpus`: directory passed as `KNOWLEDGE_DIR` to the search CLI.
  - `--queries`: JSONL, one `{"q": "...", "expect": ["slug", ...]}` per line.
  - `--k`: top-k cutoff for recall.
  - `--gate`: with `SB_EVAL_MIN_RECALL` (default `0.8`) and `SB_EVAL_MAX_TOKENS`
    (default `8000`), exit non-zero if `recall@k < min` OR `tokens > max`.
- **Output:** a summary line `recall@<k>=<r> tokens=<t> queries=<n>` + per-query
  miss list. Recall = (# queries whose `expect` slug appears in the top-k results) /
  (# queries). Token estimate = bytes of returned result text / 4 (rough token proxy;
  no tokenizer dep).
- **Depends on:** `knowledge-search-cli.bundle.js`, `jq`. Offline (BM25 path works
  without vector deps).
- **Failure mode:** if the CLI is missing or errors, exit 2 (distinct from a recall
  failure exit 1) so callers can fail-safe.

### C2. `scripts/wiki-forget-score.sh` (composite importance scorer)

- **Purpose:** rank cold-tier wiki pages by a composite importance score from
  **offline signals only**.
- **Usage:** `wiki-forget-score.sh [--wiki <dir>] [--json]` → ranked
  `{slug, path, category, score, reasons[]}` (ascending score = most forgettable first).
- **Signals & default weights** (each normalized 0–1, weighted sum; weights are
  env-overridable `SB_FORGET_W_*`):
  - `access` (0.30): `access-counts.json[slug]` (missing → 0), log-scaled.
  - `recency` (0.25): newer mtime → higher; age in days mapped through a decay so
    >180d ≈ 0.
  - `connectivity` (0.25): inbound `[[slug]]` count across wiki + `## Cross-references`
    in PROJECT.md files (same link-graph logic as `skills/lint`); 0 inbound = orphan.
  - `category` (0.20): protection floor — `learnings`/`decisions`/`concepts` get a high
    floor (never scored "forgettable"); `entities`/`sources`/`patterns`/`issues`
    neutral; auto-generated stubs (`evolve-01*`, session-narrative, body < 200 chars,
    `index`) get a low floor.
- **Protected (never emitted as a candidate regardless of score):** `index.md`,
  category-protected pages, pages newer than `SB_FORGET_MIN_AGE_DAYS` (default 30),
  pages with ≥1 inbound link from a non-archived page.
- **Depends on:** `jq`, `stat`, `grep`/`awk`. No embeddings. No network.

### C3. Dream `Phase 6: FORGET` (in `skills/dream/SKILL.md`, run by dream-runner)

Runs **on the staging copy** of the wiki, after the 5 existing consolidation phases:

1. Run `wiki-forget-score.sh` over the staging wiki.
2. Candidate set = pages with `score < SB_FORGET_FLOOR` (default `0.15`) AND not
   protected (C2), sorted ascending, capped at `SB_FORGET_MAX_PER_DREAM` (default 5).
   If `SB_WIKI_TARGET_PAGES` is set and the wiki exceeds it, the cap may rise to pull
   toward target (still bounded by the floor + protections).
3. **Live recall-probe guard** — for each candidate, derive a query from its
   `title` + `keywords` frontmatter and run `wiki-recall-check.sh` against the staging
   wiki **with the candidate removed**. If the candidate's own slug was the top-k
   answer to that query and no sibling page now answers it (recall for that probe
   drops to 0), the page is the **unique answer** → **PROTECT** (drop from candidates).
4. Survivors are **staged as archive moves** in the dream diff: `wiki/<cat>/<slug>.md`
   → `wiki/.archive/<cat>/<slug>.md`, with a staged append to
   `~/.second-brain/wiki-archive-log.jsonl` (`{slug, path, category, score, reasons,
   probe:"protected"|"safe", date}`).
5. **Fail-safe:** if `wiki-recall-check.sh` exits 2 (search unavailable / deps
   missing) for any candidate, **skip forgetting entirely this dream** and note it in
   the dream summary — never archive without a working recall guard.
- **Apply on `dream_accept`:** the staged moves + log append are applied; reindex
  drops `.archive/**` from the index. **`dream_discard`:** nothing archived.
- **Kill switch:** `SB_WIKI_FORGET=off` skips Phase 6 entirely.

### C4. `scripts/wiki-restore.sh` (reversibility)

- **Usage:** `wiki-restore.sh <slug>` → moves `wiki/.archive/<cat>/<slug>.md` back to
  `wiki/<cat>/<slug>.md`, appends a `restored` record to the archive log, triggers a
  reindex. `--list` shows archived pages from the log.

### C5. Eval gate — `tests/test-knowledge-eval.sh` + fixtures

- `tests/fixtures/eval-wiki/` — ~15–20 committed `.md` pages with proper frontmatter
  across categories (learnings, concepts, decisions, entities), authored so queries
  have unambiguous expected answers, including a couple of near-duplicate pairs to
  exercise ranking.
- `tests/fixtures/eval-queries.jsonl` — `{"q","expect":[slug...]}` lines (~15).
- `tests/test-knowledge-eval.sh` — calls `wiki-recall-check.sh --corpus
  tests/fixtures/eval-wiki --queries tests/fixtures/eval-queries.jsonl --k 3 --gate`.
  Asserts recall@3 ≥ `SB_EVAL_MIN_RECALL` (0.8) AND tokens ≤ `SB_EVAL_MAX_TOKENS`.
  Auto-discovered by `run-all.sh` (release gate).

## Data flow

- **Gate:** `run-all.sh` → `test-knowledge-eval.sh` → `wiki-recall-check`(fixtures) →
  pass/fail.
- **Forget:** `dream` → Phase 6 → `wiki-forget-score`(staging wiki) → candidates →
  `wiki-recall-check` live-probe per candidate → protect/stage → dream diff →
  `dream_accept` → archive move + log + reindex.

## Configuration (all env, conservative defaults)

| Var | Default | Meaning |
|-----|---------|---------|
| `SB_WIKI_FORGET` | `on` | kill switch for Phase 6 |
| `SB_FORGET_FLOOR` | `0.15` | composite score below which a page is a candidate |
| `SB_FORGET_MIN_AGE_DAYS` | `30` | never archive pages newer than this |
| `SB_FORGET_MAX_PER_DREAM` | `5` | cap archived per dream (gentle) |
| `SB_WIKI_TARGET_PAGES` | unset | optional prune-to-size target |
| `SB_FORGET_W_ACCESS / _RECENCY / _CONNECTIVITY / _CATEGORY` | 0.30/0.25/0.25/0.20 | scoring weights |
| `SB_EVAL_MIN_RECALL` | `0.8` | gate threshold |
| `SB_EVAL_MAX_TOKENS` | `8000` | gate token budget |

Out of the box: forgetting only touches clearly-dead pages (score <0.15, >30d old,
unprotected, recall-safe), ≤5 per dream, always staged for review.

## Error handling / safety

- Archive = reversible **move + JSONL log**, never delete. `dream_discard` = no-op.
- Confirmation gate = `dream_accept` (honors the user rule).
- **Fail-safe forgetting:** missing/broken recall probe → skip Phase 6, don't archive.
- Offline: scoring needs no network/embeddings; recall probe uses BM25 (text-only OK).
- `wiki-recall-check` distinguishes recall-failure (exit 1) from infra-failure
  (exit 2) so the dream guard fails safe rather than silently passing.

## Testing

- `tests/test-knowledge-eval.sh` — recall@3 + token budget on the fixture corpus (gate).
- `tests/test-wiki-forget-score.sh` — over a fixture wiki: a dead stub scores below
  floor; a linked `learnings` page is category-protected (never a candidate); an
  orphan old page scores low; weights/protections behave.
- `tests/test-wiki-forget-probe.sh` — a fixture where one page is the unique answer to
  its topic query → assert the FORGET candidate-selection PROTECTS it; and a
  redundant near-duplicate → assert it's archivable.
- All shell, auto-discovered by `run-all.sh`, deterministic, no network.

## New / changed files

| Path | Kind | Change |
|------|------|--------|
| `scripts/wiki-recall-check.sh` | new | shared recall@k + token measurement |
| `scripts/wiki-forget-score.sh` | new | offline composite importance scorer |
| `scripts/wiki-restore.sh` | new | un-archive a page + reindex |
| `skills/dream/SKILL.md` | edit | add Phase 6 FORGET to Step 2; stage archives; fail-safe |
| `agents/dream-runner.md` | edit | grant the scripts + describe Phase 6 (if it enumerates phases) |
| `tests/fixtures/eval-wiki/*.md` | new | committed eval corpus |
| `tests/fixtures/eval-queries.jsonl` | new | Q→slug fixtures |
| `tests/test-knowledge-eval.sh` | new | release-gate recall+token test |
| `tests/test-wiki-forget-score.sh` | new | scorer behavior test |
| `tests/test-wiki-forget-probe.sh` | new | recall-protect behavior test |
| `scripts/ensure-dirs.sh` | edit | create `~/knowledge/wiki/.archive/` lazily |
| `skills/upgrade/SKILL.md` | edit | migration row for the release version |

## Open risks / verify-first (for the plan)

- **Reindex must drop `.archive/**`** from the search index (and restore must re-add).
  Verify how the wiki index discovers pages; if it globs `wiki/**`, exclude `.archive/`.
  This is the plan's step-0 verification.
- **Token proxy** (bytes/4) is rough; acceptable for a relative gate. If a real
  tokenizer is ever wanted, that's a separate change (don't add a dep now).
- **Probe query derivation** from title+keywords is heuristic; the fail-safe (skip on
  infra error) and the conservative floor bound the blast radius.
- **Fixture corpus realism** — fixtures must be stable and unambiguous or the gate
  flakes; keep them small and hand-authored.

## Decision log

1. Forgetting rides the **dream's staged review** (`dream_accept` = confirmation),
   not maintainer auto-archive — chosen for the reversible, human-gated path.
2. Eval is **both**: a deterministic fixed-corpus release gate **and** a live
   per-candidate recall-probe inside FORGET (the safety net for forgetting).
3. **No embedding signals** in scoring or the probe — offline-first; survives the
   recurring vector-deps gap.
4. Archive = reversible move + JSONL log; never delete; fail-safe when the recall
   guard can't run.
5. Pure shell + existing `knowledge-search-cli` (`KNOWLEDGE_DIR` override) — no new
   deps, no build, no MCP tool.
