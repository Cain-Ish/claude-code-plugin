# Code-review runtime-premise lens — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Catch the wrong-runtime-premise bug class (that shipped 0.24.29) structurally, via a new read-only reviewer agent + a gated orchestrator real-env verify-step in `code-review-deep`.

**Architecture:** A new `code-review-premise-reviewer` agent (Pass 2d) enumerates load-bearing runtime premises in a diff and flags unproven ones; for bug-fix PRs the orchestrator (Pass 3.5, user-confirmed) probes each flagged premise in the real env + checks a failure-regime test exists. The agent ships in the plugin (enforcement); a lazy `review-fragile-premises.md` wiki note is support only.

**Tech Stack:** Markdown agent/skill prompts; bash static-guard tests; JSON version files. No MCP/TS change.

**Spec:** `docs/specs/2026-06-07-code-review-premise-lens-design.md`. **Branch:** `feat/code-review-premise-lens`.

---

### Task 1: The `code-review-premise-reviewer` agent

**Files:**
- Create: `tests/test-code-review-premise-agent.sh`
- Create: `agents/code-review-premise-reviewer.md`

- [ ] **Step 1: Write the failing guard test**

Create `tests/test-code-review-premise-agent.sh`:

```bash
#!/bin/bash
# Guard: the runtime-premise reviewer agent exists, is READ-ONLY (no exec over PR
# content — the trust boundary the whole lens depends on), and its prompt carries the
# premise taxonomy + the proof_probe/established output contract.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
F="$ROOT/agents/code-review-premise-reviewer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$F" ] || fail "agent file missing: $F"

# 1. read-only tools: Read + git diff/log + grep only; NO exec (node / bash script), no bare Bash
tools=$(grep -m1 '^tools:' "$F") || fail "no tools: line"
echo "$tools" | grep -qE 'Bash\((node|bash )' && fail "must be read-only — exec grant found: $tools"
echo "$tools" | grep -qE '(^|[:, ])Bash([, ]|$)' && fail "must not have unscoped Bash: $tools"
for g in 'Read' 'Bash(git diff' 'Bash(git log' 'Bash(grep'; do
  echo "$tools" | grep -qF "$g" || fail "tools: missing read-only grant '$g'"
done
pass "agent is read-only (Read + git diff/log + grep only)"

# 2. the 6-premise taxonomy
for t in 'nvironment variable' 'ilesystem' 'rocess' 'shared state' 'ervice' 'latform'; do
  grep -qi "$t" "$F" || fail "taxonomy item missing: '$t'"
done
pass "6-premise taxonomy present"

# 3. the asymmetric-fallback hunt (our exact bug)
grep -qi 'fallback' "$F" || fail "prompt must call out the asymmetric-fallback trap"
pass "asymmetric-fallback trap present"

# 4. output contract: category premise + proof_probe + established
for k in 'premise' 'proof_probe' 'established'; do
  grep -qF "$k" "$F" || fail "output contract missing field: '$k'"
done
pass "output contract present"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL (agent file absent)**

Run: `bash tests/test-code-review-premise-agent.sh`
Expected: `FAIL: agent file missing: .../agents/code-review-premise-reviewer.md` (exit 1)

- [ ] **Step 3: Create the agent**

Create `agents/code-review-premise-reviewer.md` (modeled on `code-review-history-reviewer.md`):

```markdown
---
name: code-review-premise-reviewer
description: |
  Reviews a change for unproven RUNTIME PREMISES — load-bearing assumptions about the
  environment (env vars, files, process state, shared state, services, platform) that
  the diff depends on but does not itself establish. The bug class diff-static review
  misses: code internally consistent with a false belief about the runtime. Runs once
  over the changed code files. Dispatched by the code-review-deep skill (Pass 2d).

  <example>
  Context: code-review-deep has decomposed a change and is fanning out reviewers.
  assistant: "Dispatching code-review-premise-reviewer to enumerate unproven runtime premises."
  </example>
color: yellow
effort: high
tools: Read, Bash(git diff *), Bash(git log *), Bash(grep *)
---

# Runtime-Premise Reviewer

You are a senior reviewer hunting ONE specific bug class: a change that rests on an
unproven assumption about the RUNTIME ENVIRONMENT. The code can be internally perfect
yet wrong because a belief it depends on — "this env var is set", "this file exists",
"the cwd is the project root" — is false in the real runtime. The per-unit, history,
and architectural reviewers are all diff-static and cannot see this; you are the lens
that names the premises so the orchestrator can probe them.

Your task input provides: the changed code file list, the base ref (e.g.
`origin/main`), the change summary, the project conventions (CLAUDE.md + wiki), a
prior-review note, and the contents of `review-fragile-premises.md` (known-fragile
premises for this repo — may be empty).

## Instructions

1. For each file, run `git diff <base>...HEAD -- <file>` to see what changed.
2. Build the list of every EXTERNAL precondition the changed code depends on but does
   not itself establish, across this taxonomy:
   1. **Environment variables** — `process.env.X` / `${X:-}` / `$X`: does the code
      assume X is set / non-empty? (Use `grep` across the repo to see if X is set
      anywhere the code controls.)
   2. **Filesystem** — a path exists / is readable / writable / a symlink resolves.
   3. **Process & runtime state** — cwd is the project root; ordering or consistency
      across SEPARATE process spawns; singletons; one-writer assumptions.
   4. **Cross-process shared state another actor can mutate** — global files, pins,
      lockless shared markers.
   5. **External services / network reachability.**
   6. **Platform** — GNU vs BSD coreutils, bash version, OS.
3. Classify each premise: **established** (set / checked / defaulted within the
   change) or **assumed**. Emit a finding for each load-bearing ASSUMED premise (one
   whose false value changes behavior).
4. SPECIAL HUNT — the asymmetric-fallback trap: "the code has a fallback for when X is
   unset, but the fallback's own correctness rests on a DIFFERENT unproven premise"
   (e.g. falls back to a shared pin that a concurrent process can clobber). Flag it.
5. If a flagged premise matches an entry in `review-fragile-premises.md`, raise its
   severity and cite the note.
6. Scope strictly to lines changed since `<base>`.

## Output

For each finding, return:
- **file**: path
- **lines**: range (e.g. "42-45")
- **premise**: the assumption, one sentence
- **reliance**: where/how the code depends on it
- **breaks_if_false**: what misbehaves at runtime if the premise is false
- **proof_probe**: a CONCRETE, runnable way to test the premise in the real env (the
  exact command/condition the orchestrator's Pass 3.5 would run)
- **category**: premise
- **severity**: critical | high | medium | low
- **established**: true | false  (false = flagged)

If you find no unproven load-bearing premises, say "No issues found."

## Rules

- Report only load-bearing premises (a wrong value changes behavior). Skip cosmetic or
  always-true assumptions.
- Do NOT re-report diff-local logic/type/edge bugs — that is the per-unit reviewer's
  lane. Stay in the runtime-premise lane.
- Every `proof_probe` must be concrete and runnable, not "verify it works".
- Return only the structured findings — never paste file contents back; cite
  `file:line`. This keeps the orchestrator's context bounded.
```

- [ ] **Step 4: Run the guard test — expect PASS**

Run: `bash tests/test-code-review-premise-agent.sh`
Expected: 4 `PASS:` lines then `ALL PASS` (exit 0)

- [ ] **Step 5: Confirm the agent auto-passes the existing tools guard**

Run: `bash tests/test-agent-allowed-tools.sh`
Expected: `ALL PASS` — the loop auto-discovers the new agent; its body invokes no
`node`/bash-script, so it needs no extra grant. (No edit to that test required.)

- [ ] **Step 6: Commit**

```bash
git add agents/code-review-premise-reviewer.md tests/test-code-review-premise-agent.sh
git commit -m "feat(review): add read-only code-review-premise-reviewer agent (Pass 2d lens)"
```

---

### Task 2: Wire the lens into the `code-review-deep` skill

**Files:**
- Create: `tests/test-code-review-deep-premise-wiring.sh`
- Modify: `skills/code-review-deep/SKILL.md` (Pass 0, Pass 2d, wave-cap note, Pass 3, Pass 3.5, Pass 4, Notes)

- [ ] **Step 1: Write the failing wiring test**

Create `tests/test-code-review-deep-premise-wiring.sh`:

```bash
#!/bin/bash
# Guard: code-review-deep SKILL.md wires the runtime-premise lens end to end.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/code-review-deep/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$S" ] || fail "SKILL.md missing"

grep -q 'code-review-premise-reviewer' "$S" || fail "Pass 2d must dispatch the premise reviewer"
grep -qE '## Pass 2d' "$S" || fail "missing '## Pass 2d' heading"
grep -qE '## Pass 3\.5' "$S" || fail "missing '## Pass 3.5' heading"
pass "Pass 2d + Pass 3.5 headings + dispatch present"

grep -qi 'is_bugfix' "$S" || fail "Pass 0 must classify is_bugfix"
pass "is_bugfix classification present"

grep -qi 'real env\|real runtime' "$S" || fail "Pass 3.5 must probe in the real env"
grep -qi 'failure.regime\|failure case\|false regime\|UNSET' "$S" || fail "Pass 3.5 must check a failure-regime test"
pass "Pass 3.5 real-env probe + failure-regime test check present"

grep -q 'review-fragile-premises' "$S" || fail "Pass 0 must read review-fragile-premises.md"
pass "fragile-premises support note wired"

# the carve-out: the don't-run-the-app note acknowledges Pass 3.5
awk '/Do not build/,/Pass 3\.5|premise/' "$S" | grep -qi '3\.5\|premise' \
  || fail "the 'don't run the app' note must carve out Pass 3.5"
pass "don't-run-the-app carve-out for Pass 3.5 present"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL (none of the wiring exists yet)**

Run: `bash tests/test-code-review-deep-premise-wiring.sh`
Expected: `FAIL: Pass 2d must dispatch the premise reviewer` (exit 1)

- [ ] **Step 3: Pass 0 — add change-intent classification + fragile-premises load**

In `skills/code-review-deep/SKILL.md`, inside `## Pass 0`, after step 5 (Second-brain reads), append:

```markdown
6. **Change-intent classification** (Haiku step). From the PR title/body (or
   `git log origin/<base>..HEAD --oneline` when no PR), set `is_bugfix` = does this
   change CLAIM TO FIX a reported runtime behavior (vs. a feature / refactor /
   docs / test-only change)? Record it — it gates Pass 3.5.
7. **Fragile-premises note.** Read `~/.second-brain/review-fragile-premises.md` if it
   exists (else treat as empty). Hold its contents for Pass 2d.
```

- [ ] **Step 4: Add Pass 2d after the Pass 2c section**

Insert a new section after `## Pass 2c …`:

```markdown
## Pass 2d — Runtime-premise pass (scored, parallel)

If at least one non-skipped **code** unit exists (`docs_only:false`), dispatch exactly
ONE `Agent(subagent_type:"second-brain:code-review-premise-reviewer")` over the deduped
union of all non-skipped code-unit files. It **occupies one slot in wave 1** alongside
the architectural (2b) and history (2c) reviewers. It depends only on Pass 1's unit
list, not Pass 2's findings, so it runs concurrently. Pass it `origin/<base>`, the
change summary, the combined project conventions (CLAUDE.md + wiki), the prior-review
note, and the `review-fragile-premises.md` contents from Pass 0. Its findings (category
`premise`) flow into Pass 3 dedup + scoring exactly like the per-unit findings. If every
unit is docs-only, skip this pass.
```

- [ ] **Step 5: Update the wave-cap accounting (in Pass 2b)**

In `## Pass 2b`, replace the wave-cap sentence ("so wave 1 holds at most 3
unit-reviewers + the architectural reviewer + the history reviewer …") with:

```markdown
It **occupies one slot in wave 1** (as do the Pass 2c history reviewer and the Pass 2d
premise reviewer when they run) — so wave 1 holds at most 2 unit-reviewers + the
architectural + history + premise reviewers (≤5 concurrent total). Each skipped
advisory/lens pass returns its slot to unit-reviewers (all three run → ≤2
unit-reviewers; two run → ≤3; one runs → ≤4; none → ≤5) — the ≤5 cap holds in every
combination.
```

- [ ] **Step 6: Pass 3 — scoring guidance for `premise` findings**

In `## Pass 3`, after the Dedup item, add to the Score item:

```markdown
   A `premise` finding (Pass 2d) scores HIGH when the premise is load-bearing AND
   unproven AND — if Pass 3.5 ran — shown BROKEN; LOW when Pass 3.5 confirmed it holds
   or it is established/defended. A premise Pass 3.5 marked BROKEN is force-promoted to
   confirmed (≥70) regardless of the scorer's number.
```

- [ ] **Step 7: Add Pass 3.5 after Pass 3**

Insert after `## Pass 3 …`:

```markdown
## Pass 3.5 — Bug-fix real-env verification (orchestrator, gated)

Runs ONLY when `is_bugfix` (Pass 0) AND Pass 2d flagged ≥1 load-bearing premise.
This is the ONE step that executes code — run by the orchestrator (this trusted
session), NEVER by a sandboxed PR-influenced agent.

1. **Confirm with the user.** Print exactly what each `proof_probe` will run; it
   executes code. On decline: skip, mark the premise findings "unverified (user
   declined)", continue to Pass 4. Never blocks the review.
2. **Probe each flagged premise** via its `proof_probe`, exercising the changed code
   path in the **real env** — the actual environment state, NOT a sandbox that sets
   convenient values. Record `holds` / `BROKEN`. A BROKEN premise elevates its finding
   to confirmed critical ("fix does not hold in the real runtime").
3. **Failure-regime test check.** Confirm the change adds/modifies a test that
   exercises the premise's FALSE regime (e.g. the env var UNSET). Missing → a
   `test-gap` finding ("no test covers the regime where the bug occurs").

Best-effort: any probe error is reported, never fails the review.
```

- [ ] **Step 8: Pass 4 — verification subsection + fragile-premises write-back**

In `## Pass 4`, after the "Architectural notes (advisory)" bullet, add:

```markdown
   - **Runtime-premise verification.** If Pass 3.5 ran, append a section titled
     `Runtime-premise verification` listing each probed premise with `holds` / `BROKEN`
     and a one-line real-env evidence note. A confirmed BROKEN premise may be appended
     (user-confirmed) to `~/.second-brain/review-fragile-premises.md` using the entry
     format below — same best-effort, never-fail discipline as the false-positive store.
```

And after the false-positive file header block, add the fragile-premises format:

```markdown
   Fragile-premises file (`~/.second-brain/review-fragile-premises.md`), header on create:

         # Review fragile-premise patterns
         <!-- Read by code-review-premise-reviewer to raise severity on known-fragile runtime premises. Append-only. -->

   Per entry:

         ## <short premise title>
         - repo: <owner/repo>
         - premise: <the assumption that proved fragile>
         - why fragile: <one-line: how it fails in the real runtime>
         - source: pass-3.5-confirmed | user
         - date: <YYYY-MM-DD>
```

- [ ] **Step 9: Notes — carve out the "don't run the app" rule**

In `## Notes`, replace the line "Do not build, typecheck, or run the app — CI handles that." with:

```markdown
- Do not build, typecheck, or run the app — CI handles that. The ONE exception is
  **Pass 3.5**: a narrow, orchestrator-run, user-confirmed, bug-fix-only premise probe
  (a specific `proof_probe`, not a general build/typecheck/test run).
```

- [ ] **Step 10: Run the wiring test — expect PASS**

Run: `bash tests/test-code-review-deep-premise-wiring.sh`
Expected: 6 `PASS:` lines then `ALL PASS` (exit 0)

- [ ] **Step 11: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep-premise-wiring.sh
git commit -m "feat(review): wire premise lens into code-review-deep (Pass 0/2d/3.5/4 + carve-out)"
```

---

### Task 3: Release — version bump + migration row (+ optional self-seed)

**Files:**
- Modify: `.claude-plugin/plugin.json` (version `0.24.30` → `0.24.31`)
- Modify: `.claude-plugin/marketplace.json` (version `0.24.30` → `0.24.31`)
- Modify: `skills/upgrade/SKILL.md` (add the `0.24.31` migration row)

- [ ] **Step 1: Bump `plugin.json`**

Change line `"version": "0.24.30",` → `"version": "0.24.31",`.

- [ ] **Step 2: Bump `marketplace.json`**

Change `"version": "0.24.30"` → `"version": "0.24.31"`.

- [ ] **Step 3: Run the lockstep guard — expect PASS**

Run: `bash tests/test-validate-plugin.sh`
Expected: `ALL PASS` (no plugin.json↔marketplace.json drift).

- [ ] **Step 4: Add the migration row**

In `skills/upgrade/SKILL.md`, insert above the `0.24.30` row:

```markdown
| **0.24.31** | **code-review-deep runtime-premise lens** — closes the bug class that shipped 0.24.29 (a false belief about the runtime env — `CLAUDE_PROJECT_DIR` reliably set — passed all three diff-static review lenses). New read-only `code-review-premise-reviewer` agent (Pass 2d) enumerates every load-bearing runtime premise in a diff (env vars / filesystem / process state / cross-process shared state / services / platform) and flags unproven ones, with a special hunt for the asymmetric-fallback trap (fallback whose own correctness rests on a different unproven premise — the pin). A gated **Pass 3.5** (orchestrator-run, user-confirmed, bug-fix-only) probes each flagged premise in the REAL env + checks a failure-regime test exists. Fix lives in the shipped skill+agents (cross-plugin enforcement); the lazy `~/.second-brain/review-fragile-premises.md` note is support only. **No MCP change** (server stays 2.6.7). New tests: `test-code-review-premise-agent.sh`, `test-code-review-deep-premise-wiring.sh`. Additive — the review skill gains a lens; nothing else changes. | No precondition — bumping the marker is sufficient. **Optional self-seed:** create `~/.second-brain/review-fragile-premises.md` with the `CLAUDE_PROJECT_DIR is inconsistently set across MCP-server spawns` entry if absent, so this repo's reviews start premise-aware. |
```

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json skills/upgrade/SKILL.md
git commit -m "release: 0.24.31 — code-review runtime-premise lens (additive, no MCP change)"
```

---

### Task 4: Full verification + dogfood gate

**Files:** none (verification only)

- [ ] **Step 1: Run the two new guard tests**

Run: `bash tests/test-code-review-premise-agent.sh && bash tests/test-code-review-deep-premise-wiring.sh`
Expected: both end `ALL PASS`.

- [ ] **Step 2: Run the full bash suite (no regressions)**

Run: `for t in tests/test-*.sh; do bash "$t" >/tmp/t.out 2>&1 || { echo "FAIL $(basename "$t")"; tail -3 /tmp/t.out; }; done; echo done`
Expected: no `FAIL` lines (`test-lib-extractor-backend.sh` may transiently fail on API auth — re-run it alone to confirm environmental).

- [ ] **Step 3: Run the MCP typecheck guard (unchanged TS must still pass)**

Run: `bash tests/test-mcp-typecheck.sh`
Expected: `ALL PASS` (we made no TS change; this confirms it).

- [ ] **Step 4: Validate the plugin**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid`.

- [ ] **Step 5: Dogfood — deep-review this branch through the IMPROVED skill**

Invoke `code-review-deep` on `feat/code-review-premise-lens` (base `main`). The new
`code-review-premise-reviewer` reviews its own introduction. Triage findings via
`second-brain:receiving-code-review`; fix any real ones (new commit), re-verify.
Expected: clean (or fixed-then-clean) before opening the PR.

- [ ] **Step 6: Push + open PR (do NOT merge without explicit user go-ahead)**

```bash
git push -u origin feat/code-review-premise-lens
gh pr create --base main --head feat/code-review-premise-lens --title "feat(review): code-review-deep runtime-premise lens (0.24.31)" --body "<summary per the spec>"
```
Then stop and report — the user authorizes the merge.
