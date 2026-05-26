---
name: code-review-deep
description: In-depth multi-pass code review of a GitHub change (local checkout). Decomposes the diff into logical review units, deep-reviews each with a parallel Haiku agent (cross-file bug hunting), scores findings with an FP-aware scorer, consults the second-brain for conventions and prior reviews, and records false positives. Local output by default; --comment posts to the PR.
disable-model-invocation: false
argument-hint: "[<PR#>] [--comment] [--base <branch>]"
allowed-tools: Read Write Bash(gh pr view *) Bash(gh pr comment *) Bash(gh pr list *) Bash(gh pr diff *) Bash(gh repo view *) Bash(git diff *) Bash(git log *) Bash(git blame *) Bash(git rev-parse *) Bash(git merge-base *) Bash(git branch *) Bash(git status *) Bash(git remote *) Agent mcp__knowledge-base__knowledge_search mcp__knowledge-base__episodic_search
---

# Deep Code Review

Thorough, multi-pass review of a GitHub change using the LOCAL git checkout for
diffs and file contents, and `gh` only for PR metadata and posting. Make a todo
list first, then follow these passes precisely.

## Arguments

- `<PR#>` (optional): review that GitHub PR. Without it, review the current
  branch vs its base.
- `--comment`: post the result as a PR comment (requires a PR context). Without
  it, output to the terminal only.
- `--base <branch>`: override the auto-detected base branch.

## Pass 0 — Eligibility + context load

Use an agent (Haiku model) for the mechanical parts where noted.

1. **Resolve scope & base.**
   - Determine `owner/repo` from `git remote get-url origin` (or `gh repo view --json nameWithOwner`).
   - Base branch: `--base` if given; else the PR's base (`gh pr view <#> --json baseRefName`); else `git merge-base HEAD origin/main` (fall back to `origin/master`). Record the base ref to use in diffs as `origin/<base>`.
   - Head SHA: full local `git rev-parse HEAD`. Use this SHA LITERALLY in output links — never compute it inside a URL.
2. **Eligibility (only if a PR is in scope).** `gh pr view <#> --json state,isDraft,headRefName,headRefOid,baseRefName,title,body,author`. Stop (do not review) if: closed; draft / WIP; obviously automated or trivial; or we already posted a review (scan `gh pr view <#> --comments` for our "### Deep code review" + "Generated with [Claude Code]"). **Sync guard:** if local branch != `headRefName` → stop: "Local branch `<cur>` != PR source `<headRefName>`. Run: git checkout <headRefName>". If local HEAD != `headRefOid` → stop: "Local HEAD `<local[:8]>` != PR head `<headRefOid[:8]>`. Run: git pull".
3. **CLAUDE.md discovery.** `git diff --name-only origin/<base>...HEAD`; Read the root CLAUDE.md (if any) and any CLAUDE.md in directories of changed files.
4. **Change summary.** From the PR title/body (or `git log origin/<base>..HEAD --oneline` when no PR), produce a concise summary.
5. **Second-brain reads.**
   - `knowledge_search` with 3–5 keywords drawn from the changed paths/stack → collect convention/decision pages. Pass their text as "project conventions" alongside CLAUDE.md.
   - `episodic_search` for prior reviews touching these files/this repo → distill a short "previously flagged / previously dismissed here" note.
   - Read `~/.second-brain/review-false-positives.md` if it exists (else treat as empty). Hold its contents for Pass 3.

## Pass 1 — Review-unit decomposition (Haiku agent)

`git diff --stat origin/<base>...HEAD`. Group changed files into logical review
units (implementation + its tests; module/package cohesion; cross-layer feature
slices; config/infra serving one purpose). Skip 100%-deleted files and
trivial-only changes (whitespace, import reorder, version bump). Split any unit
> 15 files or ~3000 lines. Cap at 15 units (merge smallest if over). Tag each
unit priority: critical (auth/security/data/access) | high (core logic,
user-facing) | medium (utilities/internal) | low (config). Set `docs_only: true`
when every file in the unit is documentation (`*.md`, `*.mdx`, `*.txt`, `*.rst`,
`docs/**`, or a comment-only diff); config files (`*.json`, `*.yaml`, `*.toml`,
dotfiles) are code-side, NOT docs. There is no early-exit — docs units are
reviewed, just on Haiku. Emit JSON:

    [{"name":"...","files":["..."],"priority":"critical","skip":false,"docs_only":false}, ...]

Filter `skip:true`; sort critical-first; record the skipped count.

## Pass 2 — Per-unit review (parallel agents, model by code-vs-docs)

Dispatch one `Agent(subagent_type: "second-brain:code-review-unit-reviewer")` per
non-skipped unit, choosing the model by unit kind:

- **code units** (`docs_only: false`): dispatch with NO model override — the agent
  inherits the session model, i.e. the best model available (the v2 directive).
- **doc units** (`docs_only: true`): dispatch with `model: "haiku"` — docs don't
  need deep reasoning.

Dispatch in **waves of at most 5 concurrent agents** (not all 15 at once): run
critical/high code units first, then medium/low code units, then doc units. The
wave cap bounds peak agent count and RAM. Pass each agent: unit name + file list,
`origin/<base>` as the base ref, the change summary, the combined project
conventions (CLAUDE.md + wiki pages), and the episodic prior-review note. Each
agent returns structured findings only (no file bodies). Collect them.

## Pass 3 — Dedup + scoring + filter

1. **Dedup**: if a shared file produced the same finding in two units, keep the
   better-explained one.
2. **Score**: for each unique finding dispatch
   `Agent(subagent_type: "second-brain:code-review-scorer")`, passing the finding,
   its file paths, the project conventions, and the false-positive store contents
   from Pass 0.
3. **Partition** the scored findings into three buckets (keep all three until Pass 4):
   - **report** (score **≥ 70**): the review output, sorted by severity then score.
   - **killed-hard** (score **≤ 15**): NOT shown in the review, but retained to feed
     Pass 4's false-positive auto-record. Do not discard these before Pass 4.
   - **uncertain** (score **16–69**): dropped entirely — neither reported nor recorded.

## Pass 4 — Output + false-positive write-back

1. **Output.**
   - Default (no `--comment`): print the formatted review to the terminal.
   - `--comment`: re-run the eligibility check (still open, no competing deep
     review posted since we started), then `gh pr comment <#> --body "..."`.
   - Comment format (no emojis):

         ### Deep code review

         Analyzed X review units (Y files, Z skipped as trivial). Found N issues:

         1. **<brief description>** (category: severity)

         <link>

         ...

         🤖 Generated with [Claude Code](https://claude.ai/code) using second-brain:code-review-deep

     Or, if none: `Analyzed X review units (Y files, Z skipped). No issues found.`
   - **Link format** (literal full SHA, renders in Markdown):
     `https://github.com/<owner>/<repo>/blob/<FULL-SHA>/<path>#L<start>-L<end>`
     — full SHA written literally (NOT `$(git rev-parse …)`), `#` after the path,
     range `L<start>-L<end>`, ≥1 line of context each side.

2. **False-positive write-back** (trigger = high-confidence kills + user dismissals).
   - **Auto-record** the **killed-hard** bucket retained from Pass 3 (score ≤ 15).
     The uncertain 16–69 findings were already dropped in Pass 3 and are never
     recorded. (The killed-hard findings are recorded here even though they were
     not shown in the review output above.)
   - After a terminal review, offer: "Mark any shown finding as a false positive
     to remember it?" Record each one the user dismisses.
   - For each recorded pattern, append an entry to
     `~/.second-brain/review-false-positives.md` (read current contents with Read,
     append, Write back; if the file is absent create it with the header below).
     Recording is best-effort — a write failure must NOT fail the review.

   File header (only when creating it):

         # Review false-positive patterns
         <!-- Read by code-review-scorer to suppress known non-issues. Append-only. -->

   Per entry:

         ## <short pattern title>
         - repo: <owner/repo>
         - where: <path or glob> (<category>)
         - why not a bug: <one-line reason>
         - source: <auto-killed score=<n> | user-dismissed>
         - date: <YYYY-MM-DD>

## Degradation

If parallel subagent dispatch is unavailable, fall back to a single-context
review over the full `git diff origin/<base>...HEAD` (no unit fan-out, no parallel
scoring) and say so in the output. Second-brain reads and FP write-back still apply.

## False positives to avoid (carried from the standard reviewer)

Pre-existing issues; not-actually-a-bug; senior-engineer nitpicks; anything a
linter/typechecker/compiler catches; general quality gripes unless a convention
requires them; convention issues explicitly silenced in code; intentional
functional changes; real issues on lines this change did not modify.

## Notes

- Do not build, typecheck, or run the app — CI handles that.
- Use `gh` for PR metadata/posting; use local `git diff` + Read for code.
- Small changes (< 20 files) may yield only 1–3 units. That's fine.
