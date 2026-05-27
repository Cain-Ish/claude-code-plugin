---
name: code-review-deep
description: In-depth multi-pass code review of a GitHub change (local checkout). Decomposes the diff into logical review units, reviews each on the best available model (docs on the Haiku model), runs an advisory architectural pass on the highest-risk units, scores findings with an FP-aware scorer, consults the second-brain for conventions and prior reviews, and records false positives. Local output by default; --comment posts to the PR.
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

Dispatch an agent **on the Haiku model** (pass `model: "haiku"`) for each mechanical
sub-step below — eligibility (step 2), CLAUDE.md discovery (step 3), and the change
summary (step 4) — so the expensive orchestrator model is not spent on, and its
context not bloated by, mechanical work. The decomposition (Pass 1) and the Pass 4
re-check likewise run on the Haiku model.

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

## Pass 1 — Review-unit decomposition (Haiku model)

`git diff --stat origin/<base>...HEAD`. Group changed files into logical review
units (implementation + its tests; module/package cohesion; cross-layer feature
slices; config/infra serving one purpose). Skip 100%-deleted files and
trivial-only changes (whitespace, import reorder, version bump). Split any unit
> 15 files or ~3000 lines. Cap at 15 units (merge smallest if over). Tag each
unit priority: critical (auth/security/data/access) | high (core logic,
user-facing) | medium (utilities/internal) | low (config). Set `docs_only: true`
ONLY when every file is *prose* documentation — matches `*.md`/`*.mdx`/`*.txt`/`*.rst`
or lives under `docs/**` — AND none lives under `skills/**`, `agents/**`, `tests/**`,
or any other executable/prompt tree. Those files ARE the product (a `SKILL.md` or
agent `.md` is code-as-prompt) and must be reviewed on the best model, not the Haiku model.
Config files (`*.json`, `*.yaml`, `*.toml`, dotfiles) are code-side, NOT docs. Any
unit tagged `critical` or `high` is `docs_only: false` regardless of extension.
There is no early-exit — true docs units are still reviewed, just on the Haiku model. Emit JSON:

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
critical/high code units first, then medium/low code units, then doc units. Pack
each wave to the cap from the priority-sorted list — backfill spare slots from the
next tier; don't leave slots idle. The wave cap bounds peak agent count and RAM.
Pass each agent: unit name + file list,
`origin/<base>` as the base ref, the change summary, the combined project
conventions (CLAUDE.md + wiki pages), and the episodic prior-review note. Each
agent returns structured findings only (no file bodies). Collect them.

## Pass 2b — Architectural pass (advisory, parallel)

If at least one `critical` or `high` unit exists, dispatch exactly ONE
`Agent(subagent_type: "second-brain:quality-reviewer")` over the deduped union of
all critical+high unit files. It **occupies one slot in wave 1** (as does the Pass
2c history reviewer when it runs) — so wave 1 holds at most 3 unit-reviewers + the
architectural reviewer + the history reviewer (≤5 concurrent total), keeping the cap
intact. When either advisory/history pass is skipped, its slot returns to
unit-reviewers. It depends only on Pass 1's unit list, not Pass 2's
findings. Pass it `origin/<base>` (the SAME base-ref form Pass 2 uses), the change
summary, and the file set, and instruct it to scope findings to lines changed since
that ref — ignore pre-existing issues on untouched lines. If there are no
critical/high units, skip this pass.

Its `CRITICAL`/`WARNING`/`INFO` output is collected verbatim for a separate
"Architectural notes (advisory)" section in Pass 4. These notes are advisory only:
they are never scored or recorded as false positives, and are kept distinct from
the numbered bug findings.

## Pass 2c — History / regression pass (scored, parallel)

If at least one non-skipped **code** unit exists (`docs_only: false`), dispatch
exactly ONE `Agent(subagent_type: "second-brain:code-review-history-reviewer")` over
the deduped union of all non-skipped code-unit files. It **occupies one slot in wave
1** alongside the architectural reviewer (see the Pass 2b wave-1 note). It depends
only on Pass 1's unit list, not Pass 2's findings, so it runs concurrently. Pass it
`origin/<base>` (the SAME base-ref form Pass 2 uses), the change summary, the combined
project conventions (CLAUDE.md + wiki), and the episodic prior-review note. Unlike the
architectural pass, its findings ARE bugs (category `regression`): they flow into
Pass 3 dedup + scoring exactly like the per-unit findings. If every unit is docs-only,
skip this pass.

## Pass 3 — Dedup + scoring + filter

1. **Dedup**: if a shared file produced the same finding in two units, keep the
   better-explained one.
2. **Score**: for each unique finding dispatch
   `Agent(subagent_type: "second-brain:code-review-scorer")`, passing the finding,
   its file paths, the project conventions, and the false-positive store contents
   from Pass 0.
3. **Partition** the scored findings into three buckets (keep all until Pass 4):
   - **confirmed** (score **≥ 70**): the numbered review output, sorted by severity then score.
   - **low-confidence** (score **16–69**): NOT confirmed, but surfaced in Pass 4 as a
     separate, clearly-labeled "Lower-confidence findings" section so a real but
     hard-to-verify bug is never silently dropped. Retain until Pass 4.
   - **killed-hard** (score **≤ 15**): dropped — neither shown nor recorded. The scorer
     now inherits the session model (matches the reviewer it gates), so a ≤15 kill is
     trustworthy enough to drop without recording.

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

         Generated with [Claude Code](https://claude.ai/code) using second-brain:code-review-deep

     Or, if none: `Analyzed X review units (Y files, Z skipped as trivial). No issues found.`
   - **Lower-confidence findings (unverified).** If the low-confidence bucket
     (score 16–69) is non-empty, append — after the numbered confirmed findings and
     before the architectural notes — a section titled `Lower-confidence findings
     (unverified — may be false positives)`. Lead with one line noting these were
     found but not confirmed at high confidence and may include false positives, then
     list each as `- **<brief>** (category: severity)` followed by its `<link>`. Keep
     it visually distinct from the numbered confirmed list and from the architectural
     notes so the three are never conflated. For `--comment`, post it under that same
     subhead. If the bucket is empty, omit the section.
   - **Architectural notes (advisory).** If Pass 2b ran, append after the numbered
     findings a section titled `Architectural notes (advisory — not blocking)`
     containing the quality-reviewer output. For `--comment`, post it under that
     same labelled subhead, visually separated from the numbered bug list so a
     reader never mistakes an architectural opinion for a confirmed bug.
   - **Link format** (literal full SHA, renders in Markdown):
     `https://github.com/<owner>/<repo>/blob/<FULL-SHA>/<path>#L<start>-L<end>`
     — full SHA written literally (NOT `$(git rev-parse …)`), `#` after the path,
     range `L<start>-L<end>`, ≥1 line of context each side.

2. **False-positive write-back** (user dismissals only — no auto-record).
   - **Do NOT auto-record** killed-hard or low-confidence findings. v2.1 removes the
     auto-record ratchet: a wrong auto-suppression hides a real bug indefinitely,
     whereas a missing entry just means the finding is re-judged next run (cheap, now
     that the scorer matches the reviewer). The store grows ONLY from explicit user
     action.
   - After a terminal review, offer: "Mark any shown finding (confirmed or
     lower-confidence) as a false positive to remember it?" Record only the findings
     the user dismisses.
   - For each user-dismissed pattern, append an entry to
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
         - source: user-dismissed
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
- If repeated runs leave "ghost" agents / RAM growth, triage on the affected box:
  (a) `ps -eo pid,etimes,args | grep -E 'claude --bare|claude -p'` — recursive
  extractors (fires only in API-key mode; OAuth queues them) → fix at the Stop-hook
  extractor; (b) `ps -eo pid,ppid,args | grep server.bundle` — orphaned MCP servers
  whose parent `claude` exited → reap them; (c) the session `claude` RSS climbing
  run-over-run is parent-context bloat, inherent to inline fan-out — the wave cap +
  lean sub-agent returns above are the mitigation (bounded, not a true leak).
- **Model vs. agent names:** whenever a pass names a model (Haiku / Sonnet / Opus) it
  means the dispatch `model` parameter (e.g. `model: "haiku"`) — NEVER an agent name.
  Subagents are always named via `subagent_type: "second-brain:<agent>"`. Don't go
  looking for an agent called "Haiku".
