# Design: `/second-brain:code-review-deep`

**Date:** 2026-05-25
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session

## Summary

A new second-brain skill that performs a thorough, multi-pass code review of a
GitHub change. It adopts the **review-unit decomposition + per-unit deep-agent**
architecture from the Anthropic GitLab `code-reviewer-anthropic-local-deep` skill
(the variant that demonstrably found more cross-file bugs), ports it to GitHub
(`gh` + local `git`), and wires in two capabilities the upstream skills cannot
have: it **consults the second-brain** (wiki conventions + episodic memory of past
reviews) as review input, and it **records false-positive patterns** so future
reviews get quieter and sharper over time.

This is the differentiated path chosen over (a) porting the GitLab pair as-is and
(b) editing the vendored official `/code-review` command in place.

## Goals

- Surface real, runtime-affecting bugs — especially **cross-file interaction
  bugs** that breadth-only review structurally misses.
- Beat the baseline `/code-review` (5 generalist agents) on the same change by
  reading whole files per logical unit and following imports.
- Make review N smarter than review 1 via a high-signal false-positive memory.
- Stay cheap and fast via Haiku fan-out; orchestrate from the session model.

## Non-goals (v1 — YAGNI)

- **No GitLab/`glab` support.** GitHub only. The upstream `glab` variants remain
  available if GitLab is ever needed.
- **No separate "light" skill.** This skill scales down naturally — a small diff
  yields 1–3 review units. One skill covers both small and large changes.
- **No Sonnet "hybrid" pass** (Haiku-everywhere + quality-reviewer on critical
  units). Deferred to a possible v2.
- **No full review journal.** Only false-positive patterns are written back, not a
  per-review summary of findings/accepted bugs.
- **Not an offline feature.** Subagent fan-out requires Claude. If dispatch is
  unavailable the skill degrades to a single-context review (documented), but it
  cannot run against a local-only LLM in v1.

## Relationship to existing capability

| Existing | Disposition |
|----------|-------------|
| Official `/code-review` (vendored, GitHub, 5 generalist agents) | Left untouched. New skill is the deep counterpart, not a replacement. |
| `agents/quality-reviewer.md` (Sonnet deep critic, role-scoped) | Left untouched in its `/improve` + manual-second-opinion role. Deliberately **not** reused as the per-unit worker (Sonnet fan-out is costlier/slower; its checklist is architecture-heavy rather than diff-scoped). |
| `~/.second-brain/quality-rules.md` (learned-patterns file quality-reviewer reads) | Pattern reused: the new FP store mirrors it (home-dir markdown, append-only, read by the scorer). |
| `/security-review`, `/review` | Orthogonal. No overlap. |

## Inputs / invocation

```
/second-brain:code-review-deep [<PR#>] [--comment] [--base <branch>]
```

- **No arg** → review the current branch vs an auto-detected base
  (`git merge-base HEAD origin/main` or `origin/master`). Terminal output only.
- **`<PR#>`** → review that GitHub PR. Metadata via `gh pr view`. A **sync guard**
  refuses to run if local HEAD ≠ the PR head SHA, or local branch ≠ PR source
  branch, with an actionable `git checkout`/`git pull` message.
- **`--comment`** → after review, post the result as a PR comment. Requires a PR
  context (a `<PR#>` arg, or a branch with an open PR). Without it, output is
  local-only.
- **`--base <branch>`** → override the auto-detected base branch.

Diffs and file contents come from local `git diff` + `Read` (full-file context,
import-following). `gh` is used only for PR metadata and posting.

## Architecture — 4 passes

### Pass 0 — Eligibility + context load (Haiku + MCP)

1. **Eligibility** (only when a PR is in scope): `gh pr view <#> --json
   state,isDraft,headRefName,headRefOid,baseRefName,title,body`. Skip if closed,
   draft, automated/trivial, or already reviewed by us (scan existing PR
   comments). Run the sync guard.
2. **Resolve** base branch + full local HEAD SHA (the SHA is used literally in
   output links — never computed inline in a URL).
3. **CLAUDE.md discovery**: root + any CLAUDE.md in directories of changed files.
4. **PR summary**: Haiku summarizes title + body.
5. **Second-brain reads (new):**
   - `knowledge_search` the wiki for convention/decision pages matching the
     changed stack and paths → passed to workers as *project conventions*
     alongside CLAUDE.md.
   - `episodic_search` past session transcripts for prior reviews touching these
     files/this repo → a "previously flagged / previously dismissed" note passed
     to workers.
   - Read `~/.second-brain/review-false-positives.md` → passed to the scorer.

### Pass 1 — Review-unit decomposition (Haiku)

`git diff --stat <base>...HEAD`. Group changed files into logical review units:
implementation + its tests; module/package cohesion; cross-layer feature slices;
config/infra serving one purpose. Skip 100%-deleted files and trivial-only changes
(whitespace, import reorder, version bumps). Split any unit >15 files / ~3000
lines. Cap at 15 units (merge smallest if over). Priority-tag each unit
(critical / high / medium / low). Emit a JSON array; filter `skip:true`; sort
critical-first; record skipped count.

### Pass 2 — Per-unit deep review (N parallel Haiku workers)

New agent `code-review-unit-reviewer` (Haiku), one per non-skipped unit (≤15
parallel). Each receives: unit name + file list, base branch, PR summary,
CLAUDE.md text, **wiki conventions**, **episodic prior-review notes**. It:

1. Reads ALL files in the unit (`Read`).
2. `git diff <base>...HEAD -- <file>` for each.
3. Follows imports to files outside the unit (≤5 extra) for cross-reference.
4. Skips files shown as deleted.
5. Applies the bug taxonomy: logic errors, type/value safety, **cross-file
   interactions**, edge/boundary values, test-gap, convention (incl. wiki +
   CLAUDE.md), security, infra/config.

Returns structured findings: `file`, `lines`, `category`, `severity`, `title`,
`explanation`, `is_migrated_code`. Migrated/copied code is still in scope ("the
change ships it, so its bugs are the change's bugs").

### Pass 3 — Dedup + confidence scoring + filter (Haiku)

1. **Dedup**: when a shared file produced the same finding in two units, keep the
   better-explained one.
2. **Score** via new agent `code-review-scorer` (Haiku), one per unique finding,
   verifying against the actual files. Rubric is the 0–100 scale from the baseline
   skills, plus adjustments:
   - cross-file (needs 2+ files to see): **+10**
   - migrated/copied in this change: do **not** auto-zero; subtract ≤10
   - developer-experience-only, not user-facing: **−15**
   - **matches a known FP pattern** from `review-false-positives.md`: force to a
     suppressed score (≤10) with the matched pattern cited.
3. **Filter** findings scoring **<70** (lower than the baseline's 80, because the
   depth pass yields higher-quality candidates).

### Pass 4 — Output + false-positive write-back

1. **Output**:
   - Terminal (default): formatted findings — numbered, each with a
     `file:line` reference, taxonomy + severity, and explanation.
   - `--comment`: re-check eligibility (still open, no competing review posted
     since start), then `gh pr comment <#>` using the **exact GitHub blob-link
     format**: `https://github.com/<owner>/<repo>/blob/<FULL-SHA>/<path>#L<a>-L<b>`
     with the full SHA written literally (never `$(git rev-parse …)` inside the
     URL), ≥1 line of context each side. No emojis. Footer:
     `🤖 Generated with [Claude Code]` + skill attribution.
2. **FP write-back (the learning loop — trigger = "high-confidence kills + user
   dismissals"):**
   - **Auto-record** only findings the scorer killed **hard** (score **≤15** —
     "doesn't survive light scrutiny"). Findings scored 16–69 are *uncertain*, not
     confirmed FPs, and are NOT logged (avoids over-suppression / permanent blind
     spots).
   - **User dismissals**: after a terminal review, offer to mark any shown finding
     as a false positive; each dismissal is recorded.
   - Each record appends to `~/.second-brain/review-false-positives.md`: a short
     pattern description, the repo, the file/category, the reason, and a date.
   - Recording is **append-only and best-effort** — a write failure never fails
     the review.

## New files

| Path | Kind | Notes |
|------|------|-------|
| `skills/code-review-deep/SKILL.md` | orchestrator skill | `allowed-tools`: `Bash(gh …)`, `Bash(git …)`, `Read`, `Agent`, `mcp__knowledge-base__knowledge_search`, `mcp__knowledge-base__episodic_search`. |
| `agents/code-review-unit-reviewer.md` | Haiku worker | tools: `Read, Bash(git diff *)`. Diff-scoped taxonomy. |
| `agents/code-review-scorer.md` | Haiku scorer | tools: `Read, Bash(git diff *)`. FP-aware rubric. |
| `~/.second-brain/review-false-positives.md` | runtime state | Home dir, not repo. Created lazily on first write (or seeded by `scripts/ensure-dirs.sh`). Format documented in-file header. |

Agents dispatched as `Agent(subagent_type: "second-brain:code-review-unit-reviewer")`
and `…:code-review-scorer`, matching the existing `second-brain:quality-reviewer`
convention.

## Model strategy

- Orchestration (the skill): the session model (Sonnet/Opus).
- Eligibility, summary, decomposition, per-unit workers, scorer: **Haiku** —
  cheap, fast fan-out.

## Degradation

If subagent dispatch is unavailable, fall back to a single-context review over the
full diff (no unit fan-out, no parallel scoring) and say so in the output. The
second-brain reads and FP write-back still apply. Documented as a known limitation;
true offline/local-LLM operation is out of scope for v1.

## False-positive store format

`~/.second-brain/review-false-positives.md` — append-only markdown, mirroring the
`quality-rules.md` convention:

```markdown
# Review false-positive patterns
<!-- Read by code-review-scorer to suppress known non-issues.
     Append-only. Each entry = one confirmed-or-hard-killed pattern. -->

## <short pattern title>
- repo: <owner/repo>
- where: <path or glob> (<category>)
- why not a bug: <one-line reason>
- source: <auto-killed score=<n> | user-dismissed>
- date: <YYYY-MM-DD>
```

The scorer matches a finding against entries by repo + path/category + semantic
similarity of the reason; on a confident match it suppresses (score ≤10) and cites
the entry.

## Open risks

- **Over-suppression**: a too-broad FP pattern silences a future real bug. Mitigated
  by the conservative trigger (≤15 / user-confirmed only) and by recording specific
  path/category/reason rather than vague patterns. Future: a `--show-suppressed`
  flag to audit what the FP memory hid.
- **Episodic noise**: prior-review search may surface irrelevant sessions. Mitigated
  by passing it as advisory context, not authoritative.
- **Link-format fragility**: the full-SHA blob link must be literal. Carried over
  verbatim from the baseline skill, which stresses this repeatedly.

## Decision log

1. Target = new second-brain skill (not port-as-is, not edit vendored command).
2. Output local-by-default; `--comment` posts to PR.
3. Learning loop = read (wiki + episodic) + record FP patterns.
4. Worker = new Haiku per-unit agent (not reuse Sonnet quality-reviewer, not hybrid).
5. FP trigger = high-confidence kills (score ≤15) + user dismissals.
