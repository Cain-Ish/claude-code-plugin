# code-review-deep Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Add `/second-brain:code-review-deep` — a multi-pass GitHub code-review skill that decomposes a change into logical review units, deep-reviews each with a parallel Haiku agent (cross-file bug hunting), scores findings with an FP-aware Haiku scorer, consults the second-brain (wiki + episodic) for context, and records false positives so future reviews get quieter.

**Architecture:** One orchestrator skill (`skills/code-review-deep/SKILL.md`) drives four passes and dispatches two new Haiku subagents (`agents/code-review-unit-reviewer.md`, `agents/code-review-scorer.md`) via `Agent(subagent_type: "second-brain:…")`. The skill reviews from the local git checkout (full-file context), uses `gh` only for PR metadata/posting, and read-modify-writes a home-dir false-positive store (`~/.second-brain/review-false-positives.md`, lazily created — never in the repo). Behavior is LLM-driven, so automated tests cover structure + wiring (frontmatter, model, subagent_type reference integrity); behavior is verified by a manual smoke run.

**Tech Stack:** Markdown skill/agent definitions; `bash` test harness (`tests/test-*.sh` aggregated by `tests/run-all.sh`); `scripts/validate-plugin.sh` for frontmatter validation; `gh` CLI; `git`; second-brain MCP tools (`knowledge_search`, `episodic_search`).

**Spec:** `docs/specs/2026-05-25-code-review-deep-design.md`

---

## File Structure

| Path | Responsibility | Create/Modify |
|------|----------------|---------------|
| `agents/code-review-unit-reviewer.md` | Haiku worker: deep-review one logical unit, follow imports, apply diff-scoped bug taxonomy | Create |
| `agents/code-review-scorer.md` | Haiku scorer: 0–100 confidence per finding, FP-aware suppression | Create |
| `skills/code-review-deep/SKILL.md` | Orchestrator: 4 passes, second-brain reads, FP write-back, output | Create |
| `tests/test-code-review-deep.sh` | Structural + wiring test (frontmatter, model, subagent_type reference integrity, allowed-tools) | Create |
| `README.md` | Add skill to the `## Skills` catalog table | Modify (`README.md:88` area) |

Runtime-only (NOT in repo, created lazily by the skill): `~/.second-brain/review-false-positives.md`.

---

## Task 1: The two Haiku worker agents + their structural test

**Files:**
- Create: `tests/test-code-review-deep.sh`
- Create: `agents/code-review-unit-reviewer.md`
- Create: `agents/code-review-scorer.md`

- [ ] **Step 1: Write the failing test (agent assertions only)**

Create `tests/test-code-review-deep.sh`:

```bash
#!/usr/bin/env bash
# Structural + wiring test for the code-review-deep skill and its agents.
# Behavior is LLM-driven and not unit-testable here; this guards the contract
# the orchestrator depends on: agent files exist, are Haiku, declare a name,
# and every subagent_type the skill dispatches resolves to a real agent file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# Extract the YAML frontmatter block (between the first two '---' lines).
frontmatter() { sed -n '/^---$/,/^---$/p' "$1" | sed '1d;$d'; }

echo "test-code-review-deep.sh"
echo "------------------------"

# --- Agents -------------------------------------------------------------
for agent in code-review-unit-reviewer code-review-scorer; do
  f="$ROOT/agents/$agent.md"
  if [ ! -f "$f" ]; then bad "agent file missing: agents/$agent.md"; continue; fi
  fm="$(frontmatter "$f")"
  echo "$fm" | grep -q "^name: *$agent$" && ok "agents/$agent.md name: $agent" \
    || bad "agents/$agent.md missing or wrong 'name:' (want '$agent')"
  echo "$fm" | grep -qi "^model: *haiku$" && ok "agents/$agent.md model: haiku" \
    || bad "agents/$agent.md not 'model: haiku'"
  echo "$fm" | grep -q "^description:" && ok "agents/$agent.md has description" \
    || bad "agents/$agent.md missing 'description:'"
done

echo "------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Set the exec bit (git stores it; required by the runner and test-exec-bits convention)**

Run:
```bash
chmod +x tests/test-code-review-deep.sh
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL lines — `agent file missing: agents/code-review-unit-reviewer.md` and `…scorer.md`; exit code 1.

- [ ] **Step 4: Create `agents/code-review-unit-reviewer.md`**

```markdown
---
name: code-review-unit-reviewer
description: |
  Deep-reviews a single review unit (a group of related changed files) within a
  GitHub change. Reads every file in the unit, diffs each against the base,
  follows cross-file imports, and applies a diff-scoped bug taxonomy focused on
  runtime-affecting bugs — especially cross-file interaction bugs that
  breadth-only review misses. Dispatched in parallel (one per unit) by the
  code-review-deep skill.

  <example>
  Context: code-review-deep has decomposed a PR into review units and is fanning out.
  assistant: "Dispatching code-review-unit-reviewer per unit to hunt cross-file bugs in parallel."
  </example>
model: haiku
color: cyan
tools: Read, Bash(git diff *)
---

# Per-Unit Deep Reviewer

You are a senior code reviewer doing a deep review of ONE review unit (a set of
related files) within a larger change. Your task input provides: the unit name
and file list, the base branch ref (e.g. `origin/main`), the change summary, the
project conventions (CLAUDE.md text + any wiki convention pages), and prior-review
notes from episodic memory ("previously flagged / previously dismissed here").

## Instructions

1. Read ALL files in your unit with the Read tool.
2. Run `git diff <base>...HEAD -- <file>` for each file to see what changed.
3. If a file imports a symbol from a file NOT in your unit, Read that imported
   file too (up to 5 extra) for cross-reference context.
4. For files shown as deleted in the diff, do NOT attempt to Read them.
5. Apply the checklist. Report only real, runtime-affecting bugs. Skip nitpicks
   and style unless they violate the provided conventions.
6. Treat the prior-review notes as advisory context, not authoritative — they
   reflect past sessions and may be stale.

## Review Checklist

### 1. Logic & correctness
- Off-by-one, wrong comparator, inverted boolean
- State bugs: races, stale data, uninitialized state
- Null/nil/None/undefined unhandled where data can be absent
- Wrong signatures, argument order, or return values
- Dead paths signalling an incomplete refactor

### 2. Type & value safety
- Unsafe casts/conversions masking runtime failures
- Type mismatch between signature and call site
- Missing validation at trust boundaries

### 3. Cross-file interactions (highest value)
- References to symbols renamed/removed elsewhere in this change
- Caller/callee contract mismatches introduced by this change
- Config values inconsistent with the code that reads them
- Shared state changed in one file, consumers elsewhere not updated

### 4. Edge cases
- Empty collections / missing inputs
- Off-by-one in loops, ranges, pagination
- Zero-value vs absent-value confusion (`0` vs null, "" vs None, false vs unset)
- Integer overflow, float precision, encoding

### 5. Test coverage
- Do tests exist for the changed behavior and its error/edge paths?
- Behavior changed but tests didn't? Flag it.

### 6. Convention compliance
- Does the code follow the CLAUDE.md + wiki conventions provided?

### 7. Security (if applicable)
- Unsanitized user input; injection (SQL/XSS/command/template)
- Secrets in code; overly permissive access controls

### 8. Infrastructure/config (if applicable)
- Missing required fields, unsafe defaults
- Hardcoded env-specific values; breaking API/schema/deploy changes

## Output

For each issue, return:
- **file**: path
- **lines**: range (e.g. "42-45")
- **category**: logic-error | type-safety | cross-file | edge-case | test-gap | convention | security | infrastructure
- **severity**: critical | high | medium | low
- **title**: one sentence
- **explanation**: what's wrong, why it matters, what breaks at runtime
- **is_migrated_code**: true if this code was copied/moved within this change (not freshly written)

If you find no issues, say "No issues found."

## Rules

- Report only issues you are confident about. Do not speculate.
- Migrated/copied code is in scope: the change ships it, so its bugs count.
- Do NOT report what a linter, typechecker, or compiler would catch.
- Focus on what breaks at runtime or is user-visible.
```

- [ ] **Step 5: Create `agents/code-review-scorer.md`**

```markdown
---
name: code-review-scorer
description: |
  Scores a single code-review finding on a 0–100 confidence scale by verifying
  it against the actual files, and suppresses findings that match a known
  false-positive pattern. Dispatched (one per unique finding) by the
  code-review-deep skill to filter false positives before posting.

  <example>
  Context: code-review-deep collected findings from per-unit reviewers and needs to filter noise.
  assistant: "Scoring each finding with code-review-scorer, suppressing any that match a recorded false positive."
  </example>
model: haiku
color: green
tools: Read, Bash(git diff *)
---

# Code-Review Confidence Scorer

You score one code-review finding on a 0–100 confidence scale. Your task input
provides: the finding (file, lines, category, severity, title, explanation,
is_migrated_code), the relevant file paths, the project conventions (CLAUDE.md +
wiki), and the contents of the false-positive store
(`~/.second-brain/review-false-positives.md`, may be empty/absent). You MUST
verify the finding by reading the relevant file(s).

## Scoring rubric

- **0**: Not confident at all. False positive under light scrutiny, or a
  pre-existing issue on lines this change did not touch.
- **25**: Somewhat confident. Might be real, might not; unverified. If stylistic,
  not explicitly called out in the conventions.
- **50**: Moderately confident. Verified real, but a nitpick or rare in practice;
  not important relative to the rest of the change.
- **75**: Highly confident. Double-checked; very likely hit in practice; directly
  impacts functionality or is directly named in the conventions.
- **100**: Absolutely certain. Confirmed; will happen frequently; evidence
  directly confirms it.

## Adjustments (apply after the base score)

- Cross-file (needs reading 2+ files together to see): **+10** — high-value finds.
- Migrated/copied within this change (`is_migrated_code: true`): do NOT auto-zero;
  subtract at most 10.
- Developer-experience-only, not user-facing: **−15**.
- **Matches a known false-positive pattern** in the store (same repo + path/category
  + the recorded reason fits this finding): force the score to **≤10** and name the
  matched pattern in your justification.

## Output

Return only the numeric score (0–100) and a one-sentence justification. If you
suppressed via a false-positive pattern, say which one.
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: all `PASS` for both agents (name, model haiku, description); exit 0.

- [ ] **Step 7: Run the plugin validator (agents must pass frontmatter checks)**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid` (the validator requires `name:` in each `agents/*.md`; both have it).

- [ ] **Step 8: Commit**

```bash
git add tests/test-code-review-deep.sh agents/code-review-unit-reviewer.md agents/code-review-scorer.md
git commit -m "feat(code-review-deep): add Haiku per-unit reviewer and FP-aware scorer agents

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The orchestrator skill + wiring test

**Files:**
- Create: `skills/code-review-deep/SKILL.md`
- Modify: `tests/test-code-review-deep.sh` (add skill + subagent_type reference-integrity assertions)

- [ ] **Step 1: Extend the test with skill + wiring assertions (failing — skill not created yet)**

Append the following block to `tests/test-code-review-deep.sh`, immediately BEFORE the final `echo "------------------------"` summary lines:

```bash
# --- Skill --------------------------------------------------------------
skill="$ROOT/skills/code-review-deep/SKILL.md"
if [ ! -f "$skill" ]; then
  bad "skill file missing: skills/code-review-deep/SKILL.md"
else
  sfm="$(frontmatter "$skill")"
  for field in name description allowed-tools; do
    echo "$sfm" | grep -q "^$field:" && ok "SKILL.md has $field" \
      || bad "SKILL.md missing '$field' in frontmatter"
  done
  echo "$sfm" | grep -q "^name: *code-review-deep$" && ok "SKILL.md name: code-review-deep" \
    || bad "SKILL.md name is not 'code-review-deep'"

  # allowed-tools must grant the orchestrator what the design needs.
  at="$(echo "$sfm" | grep '^allowed-tools:')"
  for need in "Agent" "Bash(gh pr" "Bash(git diff" "knowledge_search" "episodic_search"; do
    case "$at" in
      *"$need"*) ok "allowed-tools grants $need" ;;
      *) bad "allowed-tools missing $need" ;;
    esac
  done

  # Reference integrity: every dispatched subagent must resolve to an agent file.
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "$ROOT/agents/$ref.md" ]; then
      ok "subagent_type second-brain:$ref resolves to agents/$ref.md"
    else
      bad "subagent_type second-brain:$ref has no agents/$ref.md"
    fi
  done < <(grep -oE 'second-brain:[a-z-]+' "$skill" | sed 's/^second-brain://' | sort -u)
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: `FAIL  skill file missing: skills/code-review-deep/SKILL.md`; exit 1. (Task 1's agent assertions still PASS.)

- [ ] **Step 3: Create `skills/code-review-deep/SKILL.md`**

```markdown
---
name: code-review-deep
description: In-depth multi-pass code review of a GitHub change (local checkout). Decomposes the diff into logical review units, deep-reviews each with a parallel Haiku agent (cross-file bug hunting), scores findings with an FP-aware scorer, consults the second-brain for conventions and prior reviews, and records false positives. Local output by default; --comment posts to the PR.
disable-model-invocation: false
argument-hint: "[<PR#>] [--comment] [--base <branch>]"
allowed-tools: Read Write Bash(gh pr view *) Bash(gh pr comment *) Bash(gh pr list *) Bash(gh pr diff *) Bash(git diff *) Bash(git log *) Bash(git blame *) Bash(git rev-parse *) Bash(git merge-base *) Bash(git branch *) Bash(git status *) Agent mcp__knowledge-base__knowledge_search mcp__knowledge-base__episodic_search
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
user-facing) | medium (utilities/internal) | low (config/docs). Emit JSON:

    [{"name":"...","files":["..."],"priority":"critical","skip":false}, ...]

Filter `skip:true`; sort critical-first; record the skipped count.

## Pass 2 — Per-unit deep review (parallel Haiku agents)

Dispatch one `Agent(subagent_type: "second-brain:code-review-unit-reviewer")` per
non-skipped unit, all in parallel (up to 15). Pass each: unit name + file list,
`origin/<base>` as the base ref, the change summary, the combined project
conventions (CLAUDE.md + wiki pages), and the episodic prior-review note. Collect
each agent's structured findings.

## Pass 3 — Dedup + scoring + filter

1. **Dedup**: if a shared file produced the same finding in two units, keep the
   better-explained one.
2. **Score**: for each unique finding dispatch
   `Agent(subagent_type: "second-brain:code-review-scorer")`, passing the finding,
   its file paths, the project conventions, and the false-positive store contents
   from Pass 0.
3. **Filter** findings scoring **< 70**. Keep the rest, sorted by severity then score.

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
   - **Auto-record** ONLY findings the scorer killed hard (score ≤ 15).
     Findings scored 16–69 are uncertain — do NOT record them.
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: all PASS — skill frontmatter fields, name, the five `allowed-tools` grants, and both `subagent_type second-brain:code-review-{unit-reviewer,scorer} resolves…` lines; exit 0.

- [ ] **Step 5: Run the plugin validator**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid` (SKILL.md has name/description/allowed-tools).

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): add orchestrator skill (4-pass review + FP loop)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Document the skill + full-suite verification + smoke run

**Files:**
- Modify: `README.md` (the `## Skills` table)

- [ ] **Step 1: Add the catalog row**

In `README.md`, in the `## Skills` table, immediately after the `/second-brain:review` row (currently `README.md:88`), add:

```markdown
| `/second-brain:code-review-deep [<PR#>]` | Multi-pass deep code review: review-unit decomposition + parallel Haiku per-unit reviewers, FP-aware scoring, wiki/episodic context, false-positive memory. `--comment` posts to the PR |
```

- [ ] **Step 2: Run the focused test**

Run: `bash tests/test-code-review-deep.sh`
Expected: exit 0, all PASS (unchanged by the README edit — confirms no regression).

- [ ] **Step 3: Run the full suite**

Run: `make test`
Expected: `ALL GREEN` — `test-code-review-deep` PASS, `test-validate-plugin` PASS, `test-validate-plugin-allowed-tools` PASS, `test-exec-bits` PASS, vitest PASS. If any fail, fix before continuing (do not claim done on red).

- [ ] **Step 4: Manual smoke run (behavior verification — the part tests can't cover)**

Run the skill against a small real change to confirm end-to-end behavior:
```
/second-brain:code-review-deep
```
(on a branch with a few changed files, no `--comment`).
Verify by observation: it resolves a base, decomposes into ≥1 unit, dispatches the unit reviewer(s) + scorer, prints findings (or "No issues found") in the documented format, and does NOT post to any PR. Then confirm `~/.second-brain/review-false-positives.md` is created only if a hard-killed/dismissed finding occurred.
Record the observed output in the completion claim (per `second-brain:verification-before-completion`).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(code-review-deep): add skill to README catalog

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed by author)

- **Spec coverage:** invocation/args → Pass 0 + frontmatter `argument-hint`; local-checkout review → Pass 0–2 use `git diff`+Read; sync guard → Pass 0.2; second-brain reads → Pass 0.5; review-unit decomposition → Pass 1; per-unit Haiku worker → Task 1 agent + Pass 2; FP-aware scorer + adjustments + <70 filter → Task 1 agent + Pass 3; output local/`--comment` + link format → Pass 4.1; FP write-back (≤15 + dismissals) → Pass 4.2; new files → Tasks 1–2; degradation → skill "Degradation"; non-goals → not implemented (correct). All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; every file's full content is inline; test code is complete and runnable.
- **Type/name consistency:** agent names `code-review-unit-reviewer` / `code-review-scorer` and `subagent_type: "second-brain:<name>"` match across the skill, agents, and the reference-integrity test; skill name `code-review-deep` consistent; base ref always referenced as `origin/<base>`.
