# code-review-deep Bundle B + cost-router routing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four quality improvements to `code-review-deep` (prior-PR-comment mining, inline-comment compliance, an adversarial refuter panel, least-privilege hygiene) and teach `cost-router` to route deep-review requests to the self-tiering skill.

**Architecture:** Two plugins in one repo. `cost-router`'s `classify-prompt.sh` UserPromptSubmit hook gains a conservative REVIEW detector that emits a dedicated "use /second-brain:code-review-deep" nudge (detect-&-degrade) instead of a tier nudge — it never tiers or decomposes the skill. The `code-review-deep` skill keeps its own self-tiering (cost-router cannot reach inside a running skill); changes are prompt-content edits to the SKILL.md and reviewer agents, guarded by structural grep tests.

**Tech Stack:** Bash 3.2-safe shell (hooks/tests), `jq`, Markdown prompt files (SKILL.md + agent `.md`), GNU/BSD-portable. Tests: `tests/test-*.sh` run by `make test` (`tests/run-all.sh`). Validator: `scripts/validate-plugin.sh`.

## Global Constraints

- **Spec:** `docs/specs/2026-06-24-code-review-deep-bundle-b-design.md` (every task implements part of it).
- **Branch:** work on `code-review-deep-bundle-b` (already created; spec committed at `d4a6785`).
- **Ownership boundary:** cost-router RECOGNIZES + POINTS at the skill; it NEVER tiers (no THINK→Opus nudge for review prompts) or decomposes/delegates it. The skill stays self-tiering.
- **CR-006 rule (cost-router):** REVIEW detection must be word-bounded, multi-word phrases ONLY; **never match bare `review`**. Prefer false negatives over false positives.
- **Keep untouched (NOT cost-driven):** ≤5 wave cap + slot accounting; ≤15-files/~3000-lines/≤15-units bounds; lean structured-only returns; `effort: high` on the three bug reviewers; best-model-for-code + the code-as-prompt `.md` exception; scorer-inherits-the-reviewer (no `model:` pin); RAM/RSS triage note.
- **Bash portability:** no `mapfile`, no `declare -A`, no `grep -P`, no `date -d`. Unmatched globs may stay literal — guard with `[ -d "$x" ]`.
- **No emojis** in cost-router nudges or the SKILL.md orchestrator body (existing test bans them).
- **Run tests with:** `make test` (full) or `bash tests/test-<name>.sh` (single). Each task commits on the feature branch.
- **Release gate:** before the final commit, `make release-check` must pass AND the improved `code-review-deep` is dogfooded on this branch's own diff.

---

## File Structure

**cost-router (Group 1 — independently shippable):**
- Modify `cost-router/scripts/classify-prompt.sh` — add REVIEW detector + detect-&-degrade nudge (B1).
- Modify `cost-router/skills/orchestrate/SKILL.md` — advise-only bullet (B2).
- Modify `cost-router/commands/model-route.md` — advise-only line (B2).
- Modify `cost-router/.claude-plugin/plugin.json` — version 0.2.1 → 0.2.2.
- Create `cost-router/CHANGELOG.md` — first entry.
- Modify `tests/test-classify-prompt.sh` — REVIEW behavioral tests.

**code-review-deep (Group 2 — independently shippable):**
- Modify `agents/code-review-unit-reviewer.md` — C2 checklist item + C4 disallowedTools.
- Modify `agents/code-review-scorer.md` — C3 refute mode + prior-review verification + C4 disallowedTools.
- Modify `agents/code-review-history-reviewer.md` — C4 disallowedTools.
- Modify `agents/code-review-premise-reviewer.md` — C4 disallowedTools.
- Modify `agents/quality-reviewer.md` — C4 disallowedTools.
- Modify `skills/code-review-deep/SKILL.md` — C1 Pass 0 mining + `prior-review` category + `Bash(gh api *)`; C3 Pass 3 refuter panel; C5 Pass-3 wave cap; C6 cost-ownership note.
- Modify `tests/test-code-review-deep.sh` — C1–C6 structural assertions.
- Modify `.claude-plugin/plugin.json` + `CHANGELOG.md` — release.

---

# GROUP 1 — cost-router

### Task 1: B1 — REVIEW detector + detect-&-degrade nudge

**Files:**
- Modify: `cost-router/scripts/classify-prompt.sh` (insert after line 72 `TIER="DO"` block, and after the route-log emit at line 87)
- Test: `tests/test-classify-prompt.sh` (append new helpers + cases before the final `PASS:/FAIL:` summary)

**Interfaces:**
- Consumes: existing `P_PAD` (line 52, punctuation-normalized padded lowercase copy), `EVENTS_FILE`, `REPO_ROOT`, `SCRIPT`, `TMP`, `PASS`/`FAIL` counters from the test.
- Produces: a `REVIEW` flag and a JSON `additionalContext` nudge containing `/second-brain:code-review-deep` (skill present) or `/cost-router:orchestrate` (absent). No new env vars; reuses `COST_ROUTER_AUTOROUTE`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-classify-prompt.sh`, immediately before the final `echo "-----------------------"` summary block:

```bash
# ── Bundle B: REVIEW routing (point at the self-tiering skill; never a tier) ──
# detect-&-degrade is controlled deterministically via a sandbox HOME so the test
# does not depend on what is installed on the runner.
assert_review_skill() {            # second-brain present → points at the skill
  local label="$1" prompt="$2"
  local fh="$TMP/home-present"
  mkdir -p "$fh/.claude/plugins/cache/second-brain/second-brain/9.9.9/skills/code-review-deep"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" \
          CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" HOME="$fh" \
        bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -q '/second-brain:code-review-deep'; then
    PASS=$((PASS+1)); echo "  PASS  $label → points at code-review-deep"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label → expected /second-brain:code-review-deep"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}
assert_review_degraded() {         # second-brain absent → orchestrate fallback
  local label="$1" prompt="$2"
  local fh="$TMP/home-absent"; mkdir -p "$fh"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" \
          CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" HOME="$fh" \
        bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -q '/cost-router:orchestrate' \
     && ! printf '%s' "$out" | grep -q '/second-brain:'; then
    PASS=$((PASS+1)); echo "  PASS  $label → degraded to /cost-router:orchestrate"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label → expected orchestrate fallback, no /second-brain:"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}
assert_no_review() {               # over-routing guard: review skill NOT mentioned
  local label="$1" prompt="$2"
  local out
  out=$(printf '%s' '{"prompt":"'"$prompt"'"}' \
    | env COST_ROUTER_AUTOROUTE=on COST_ROUTER_EVENTS="$EVENTS_FILE" \
          CLAUDE_PLUGIN_ROOT="$REPO_ROOT/cost-router" \
        bash "$SCRIPT" 2>/dev/null)
  if ! printf '%s' "$out" | grep -q 'code-review-deep'; then
    PASS=$((PASS+1)); echo "  PASS  $label → no review nudge"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  $label → unexpected review nudge"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

assert_review_skill   "code review fires"        "please do a code review of this pr"
assert_review_skill   "deep code review fires"   "deep code review of the auth module please"
assert_review_skill   "review the diff fires"    "can you review the diff for me here"
assert_review_skill   "short review-this-pr"     "review this pr"
assert_review_skill   "review wins over THINK"   "how should I review this pr"
assert_review_degraded "degraded fallback"       "please review the changes in this pr"
assert_no_review      "review the logs is not a code review"  "review the logs from yesterday for errors"
assert_no_review      "review meeting notes is not a code review"  "review the meeting notes for action items"
assert_no_output      "kill switch off (review)" "please do a code review of this pr"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-classify-prompt.sh`
Expected: FAIL on the new `assert_review_*` lines (the hook emits the generic tier nudge or nothing, never `/second-brain:code-review-deep`). The pre-existing assertions still PASS.

- [ ] **Step 3: Add the REVIEW detector**

In `cost-router/scripts/classify-prompt.sh`, immediately after the `DO: default` block (after line 72, before the `# ── Map tier to model name ──` comment at line 74), insert:

```bash
# ── REVIEW: a deep code review is NOT a tier ────────────────────────────────────
# code-review-deep is itself a multi-pass cost-router; recognize the request and
# point at that skill rather than tiering it. CR-006: word-bounded, multi-word
# phrases ONLY — never bare "review" (it fires on "review the logs/plan/notes").
REVIEW=""
case "$P_PAD" in
  *"code review"*|*"code-review"*|*"deep review"*|*"deep code review"*|\
  *"review this pr"*|*"review the pr"*|*"review my pr"*|\
  *"review this mr"*|*"review the mr"*|\
  *"review the diff"*|*"review my changes"*|*"review the changes"*|\
  *"thorough review"*)
    REVIEW="1" ;;
esac
```

- [ ] **Step 4: Add the REVIEW emit (precedence over the generic nudge)**

In the same file, immediately after the route-log emit line (`bash "$ROUTE_LOG" emit ...` at line 87) and before the `# ── Emit nudge as additionalContext ──` comment at line 89, insert:

```bash
# ── REVIEW nudge: point at the self-tiering skill; runs BEFORE the tier nudge so a
# review prompt never also gets a THINK/SCOUT nudge. Exempt from the >=25-char floor
# (the multi-word phrase is itself the signal). Detect-&-degrade on skill presence.
if [ -n "$REVIEW" ]; then
  SB_REVIEW_SKILL=""
  for d in "$HOME/.claude/plugins/cache/second-brain/second-brain/"*/skills/code-review-deep \
           "$HOME/.claude/plugins/marketplaces/second-brain/skills/code-review-deep"; do
    [ -d "$d" ] && { SB_REVIEW_SKILL="1"; break; }
  done
  if [ -n "$SB_REVIEW_SKILL" ]; then
    RNUDGE="cost-router: this looks like a deep code review. Run /second-brain:code-review-deep — it multi-passes the diff and self-routes mechanical/doc work to the cheap tier and code+architectural passes to the best model. (cost-router does not tier it; the skill routes itself.)"
  else
    RNUDGE="cost-router: this looks like a code review. For tiered help run /cost-router:orchestrate. (Install the second-brain plugin for the dedicated /second-brain:code-review-deep multi-pass reviewer.)"
  fi
  jq -nc --arg ctx "$RNUDGE" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}' 2>/dev/null
  exit 0
fi
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-classify-prompt.sh`
Expected: `PASS: <n>, FAIL: 0` — all new `assert_review_*` cases pass AND every pre-existing case still passes (the generic THINK/SCOUT/DO behavior is unchanged for non-review prompts).

- [ ] **Step 6: Commit**

```bash
git add cost-router/scripts/classify-prompt.sh tests/test-classify-prompt.sh
git commit -m "cost-router: route deep-review prompts to /second-brain:code-review-deep (B1)

Conservative word-bounded REVIEW detector + detect-&-degrade nudge that points
at the self-tiering skill (never tiers/decomposes it). Runs before the generic
THINK/SCOUT nudge; exempt from the 25-char floor. Behavioral tests cover firing,
over-routing guards, precedence, degraded fallback, and the kill switch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: B2 — advise-only bullets on the on-demand surfaces

**Files:**
- Modify: `cost-router/skills/orchestrate/SKILL.md` (Step 1 region, ~lines 32–34)
- Modify: `cost-router/commands/model-route.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: human-read advice text (no runtime behavior). Must not make orchestrate invoke the skill (advice only).

- [ ] **Step 1: Read the two target files to find the exact insertion anchors**

Run: `sed -n '1,60p' cost-router/skills/orchestrate/SKILL.md` and `sed -n '1,60p' cost-router/commands/model-route.md`
Expected: locate the Step-1 task-classification bullets in `orchestrate/SKILL.md` and the tier-recommendation rules in `model-route.md`.

- [ ] **Step 2: Add the orchestrate bullet**

In `cost-router/skills/orchestrate/SKILL.md`, in the Step-1 classification list, add a bullet:

```markdown
- If the task is a deep code review (e.g. "review this PR / the diff / my changes"), do NOT decompose it — invoke `/second-brain:code-review-deep` directly (if second-brain is installed). It is a self-tiering multi-pass reviewer; routing it through orchestrate would double-route and bypass its per-pass model choices.
```

- [ ] **Step 3: Add the model-route line**

In `cost-router/commands/model-route.md`, in the recommendation rules, add:

```markdown
- A code-review / "review this PR" request → recommend `/second-brain:code-review-deep` (self-tiering; do not assign a single tier) rather than a raw Haiku/Sonnet/Opus pick. If second-brain is not installed, fall back to the normal tiering.
```

- [ ] **Step 4: Validate the plugin still parses**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid` (these are content-only edits to existing files).

- [ ] **Step 5: Commit**

```bash
git add cost-router/skills/orchestrate/SKILL.md cost-router/commands/model-route.md
git commit -m "cost-router: advise (not delegate) code-review-deep on orchestrate/model-route (B2)

Advise-only bullets so the on-demand surfaces point at /second-brain:code-review-deep
and explicitly do not decompose it. Pure advice — orchestrate never invokes the
skill, preserving the standalone boundary.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: cost-router release (version + CHANGELOG)

**Files:**
- Modify: `cost-router/.claude-plugin/plugin.json` (version)
- Create: `cost-router/CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 1–2 landed.
- Produces: cost-router 0.2.2.

- [ ] **Step 1: Bump the version**

Run to confirm current value: `jq -r '.version' cost-router/.claude-plugin/plugin.json` → `0.2.1`.
Edit `cost-router/.claude-plugin/plugin.json`: change `"version": "0.2.1"` to `"version": "0.2.2"`.

- [ ] **Step 2: Create the CHANGELOG**

Create `cost-router/CHANGELOG.md`:

```markdown
# cost-router changelog

## 0.2.2 — 2026-06-24

- Route deep-review prompts to `/second-brain:code-review-deep` (the self-tiering
  multi-pass reviewer) instead of emitting a tier nudge. Conservative word-bounded
  REVIEW detector in `classify-prompt.sh` (never matches bare "review"); detect-&-
  degrade to `/cost-router:orchestrate` when second-brain is absent; exempt from the
  25-char nudge floor. cost-router recognizes + points at the skill, never tiers or
  decomposes it.
- Advise-only pointers added to `/cost-router:orchestrate` and `/cost-router:model-route`.
```

- [ ] **Step 3: Verify version bumped**

Run: `jq -r '.version' cost-router/.claude-plugin/plugin.json`
Expected: `0.2.2`

- [ ] **Step 4: Commit**

```bash
git add cost-router/.claude-plugin/plugin.json cost-router/CHANGELOG.md
git commit -m "cost-router: release 0.2.2 — deep-review routing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# GROUP 2 — code-review-deep

### Task 4: C4 — disallowedTools hygiene on the 5 read-only review agents

**Files:**
- Modify: `agents/code-review-unit-reviewer.md`, `agents/code-review-scorer.md`, `agents/code-review-history-reviewer.md`, `agents/code-review-premise-reviewer.md`, `agents/quality-reviewer.md` (add one frontmatter line each)
- Test: `tests/test-code-review-deep.sh`

**Interfaces:**
- Consumes: existing `frontmatter()` helper + `ok`/`bad`/`ROOT` in the test.
- Produces: each agent declares `disallowedTools: Write, Edit, NotebookEdit, WebFetch, WebSearch`.

- [ ] **Step 1: Write the failing test**

In `tests/test-code-review-deep.sh`, after the history-reviewer agent block (after the closing `fi` at line ~92, before the `# --- Skill ---` section), insert:

```bash
# C4: read-only review agents must declare disallowedTools (least privilege).
for agent in code-review-unit-reviewer code-review-scorer code-review-history-reviewer code-review-premise-reviewer quality-reviewer; do
  af="$ROOT/agents/$agent.md"
  if [ ! -f "$af" ]; then bad "agent file missing for disallowedTools check: $agent"; continue; fi
  afm="$(frontmatter "$af")"
  dline="$(printf '%s\n' "$afm" | grep '^disallowedTools:' || true)"
  if [ -z "$dline" ]; then
    bad "$agent missing disallowedTools (least privilege)"
  else
    for deny in Write Edit; do
      case "$dline" in *"$deny"*) ok "$agent disallows $deny" ;; *) bad "$agent disallowedTools missing $deny" ;; esac
    done
  fi
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `<agent> missing disallowedTools` for all five.

- [ ] **Step 3: Add the frontmatter line to each agent**

In each of the five agent files, add this line inside the YAML frontmatter (after the existing `tools:` line):

```yaml
disallowedTools: Write, Edit, NotebookEdit, WebFetch, WebSearch
```

(For `code-review-unit-reviewer.md` the `tools:` line is line 17; for `code-review-scorer.md` line 14; `code-review-history-reviewer.md` line 16; `code-review-premise-reviewer.md` line 16; `quality-reviewer.md` the `tools:` line — confirm with `grep -n '^tools:' agents/quality-reviewer.md`.)

- [ ] **Step 4: Run test + validator to verify pass**

Run: `bash tests/test-code-review-deep.sh && bash scripts/validate-plugin.sh`
Expected: test PASS for all five `disallows Write`/`disallows Edit`; validator `OK: all plugin files valid`.

- [ ] **Step 5: Commit**

```bash
git add agents/code-review-unit-reviewer.md agents/code-review-scorer.md agents/code-review-history-reviewer.md agents/code-review-premise-reviewer.md agents/quality-reviewer.md tests/test-code-review-deep.sh
git commit -m "code-review-deep: least-privilege disallowedTools on read-only reviewers (C4)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: C2 — inline-comment-compliance checklist item

**Files:**
- Modify: `agents/code-review-unit-reviewer.md` (add checklist section 9, before the `## Output` section at line 81)
- Test: `tests/test-code-review-deep.sh`

**Interfaces:**
- Consumes: `ROOT`, `ok`/`bad` in the test.
- Produces: a new "Inline-contract compliance" checklist item; reuses the existing `convention` category (no enum change).

- [ ] **Step 1: Write the failing test**

In `tests/test-code-review-deep.sh`, after the existing unit-reviewer lean-return assertion (after line ~62 `unit-reviewer has lean-return instruction`), insert:

```bash
# C2: unit-reviewer hunts inline-contract (code-comment) violations.
grep -qi "inline-contract" "$ROOT/agents/code-review-unit-reviewer.md" \
  && ok "unit-reviewer has inline-comment-compliance item" \
  || bad "unit-reviewer missing inline-comment-compliance (inline-contract) item"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `unit-reviewer missing inline-comment-compliance`.

- [ ] **Step 3: Add the checklist section**

In `agents/code-review-unit-reviewer.md`, between section `### 8. Infrastructure/config (if applicable)` (ends line 79) and `## Output` (line 81), insert:

```markdown
### 9. Inline-contract compliance
- Does the diff violate guidance in nearby code comments? (`// keep sorted`,
  `// do not call before init`, `NOTE`/`INVARIANT`/`WARNING`/`HACK` notes,
  docstring contracts). Flag only when the change contradicts a still-valid
  in-code instruction. Report under the `convention` category.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS — `unit-reviewer has inline-comment-compliance item`.

- [ ] **Step 5: Commit**

```bash
git add agents/code-review-unit-reviewer.md tests/test-code-review-deep.sh
git commit -m "code-review-deep: inline-comment-compliance checklist item in unit reviewer (C2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: C1 — prior-PR-comment mining (Pass 0, finding-generating)

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` — `allowed-tools` (line 7), Pass 0 step 5 (lines 39–42), Pass 3 dedup/scoring (lines 137–158), category list referenced in Pass 4 output
- Test: `tests/test-code-review-deep.sh`

**Interfaces:**
- Consumes: `at` (the `allowed-tools` line) and `ORCH` in the test.
- Produces: `Bash(gh api *)` grant; a Pass 0 sub-step emitting `prior-review` candidate findings; the `prior-review` category documented. Later consumed by Task 7's scorer note.

- [ ] **Step 1: Write the failing tests**

In `tests/test-code-review-deep.sh`, inside the `allowed-tools` `for need in ...` loop (line ~140), add `"Bash(gh api"` to the list of needs:

```bash
  for need in "Agent" "Bash(gh pr" "Bash(gh api" "Bash(gh repo" "Bash(git diff" "Bash(git remote" "knowledge_search" "episodic_search"; do
```

Then after that loop, add:

```bash
# C1: Pass 0 mines prior-PR review comments and emits prior-review findings.
grep -qi "prior-PR" "$ORCH" && ok "skill mines prior-PR review comments (Pass 0)" \
  || bad "skill missing prior-PR comment mining in Pass 0"
grep -qi "prior-review" "$ORCH" && ok "skill defines the prior-review finding category" \
  || bad "skill missing the prior-review finding category"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `allowed-tools missing Bash(gh api`, `skill missing prior-PR comment mining`, `skill missing the prior-review finding category`.

- [ ] **Step 3: Add `gh api` to allowed-tools**

In `skills/code-review-deep/SKILL.md` line 7, add `Bash(gh api *)` to the `allowed-tools` list (e.g. right after `Bash(gh pr diff *)`).

- [ ] **Step 4: Extend Pass 0 step 5 with prior-PR mining**

In `skills/code-review-deep/SKILL.md`, replace the `episodic_search` bullet of Pass 0 step 5 (line 41) with:

```markdown
   - `episodic_search` for prior reviews touching these files/this repo → distill a short "previously flagged / previously dismissed here" note.
   - **Prior-PR review-comment mining (Haiku step, finding-generating).** Discover prior PRs touching the changed files: `git log origin/<base> -n 200 -- <changed files>`, parse PR numbers from merge/squash subjects (`Merge pull request #N`, `(#N)`), cap at the ~10 most-recent distinct PRs. For each, `gh api repos/<owner>/<repo>/pulls/<N>/comments` for inline review comments; keep only comments whose path is among the currently changed files (or same directory). Produce TWO outputs: (a) fold durable observations into the prior-review note above; (b) for each comment that STILL APPLIES (the change re-introduces/retains the concern), emit a `prior-review` candidate finding {file, lines, category: `prior-review`, severity, title, explanation citing PR #N + the comment, is_migrated_code}. These findings flow into Pass 3 dedup + scoring exactly like the per-unit findings. Best-effort: no remote / no `gh` / no PR history → skip silently and note "no prior-PR signal".
```

- [ ] **Step 5: Wire prior-review findings into Pass 3 + document the category**

In `skills/code-review-deep/SKILL.md` Pass 3 step 1 (dedup, line 139), add a sentence: `prior-review findings (Pass 0) participate in dedup and scoring like any other finding.` In the Pass 4 numbered-output category vocabulary (the `(category: severity)` format around line 191), ensure `prior-review` is listed among valid categories (add a one-line note: `Categories include: logic-error, type-safety, cross-file, edge-case, test-gap, convention, security, infrastructure, regression, premise, prior-review.`).

- [ ] **Step 6: Run test + validator to verify pass**

Run: `bash tests/test-code-review-deep.sh && bash scripts/validate-plugin.sh`
Expected: test PASS for `Bash(gh api`, `prior-PR comment mining`, `prior-review category`; validator OK.

- [ ] **Step 7: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "code-review-deep: prior-PR comment mining (finding-generating, Pass 0) (C1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: C3 — adversarial refuter panel on critical/high findings

**Files:**
- Modify: `agents/code-review-scorer.md` — add a refute-mode branch + prior-review verification note
- Modify: `skills/code-review-deep/SKILL.md` — Pass 3 step 2 (scoring, lines 144–150) panel logic
- Test: `tests/test-code-review-deep.sh`

**Interfaces:**
- Consumes: `prior-review` category (Task 6); `ORCH`, `ROOT`, `ok`/`bad` in the test.
- Produces: Pass 3 dispatches 1 normal + 2 refute-mode scorers for critical/high findings; `final = median(A,B,C)`. Refuters inherit the session/best model (no `model:` pin — preserved). Scorer verifies `prior-review` findings.

- [ ] **Step 1: Write the failing tests**

In `tests/test-code-review-deep.sh`, after the Pass 2c assertion (line ~213), add:

```bash
# C3: adversarial refuter panel on critical/high findings.
grep -qi "refuter panel" "$ORCH" && ok "Pass 3 has a refuter panel" \
  || bad "Pass 3 missing the refuter panel"
grep -qi "median" "$ORCH" && ok "refuter panel uses median-of-3" \
  || bad "refuter panel missing the median-of-3 rule"
grep -qiE "refute mode|skeptic mode" "$ROOT/agents/code-review-scorer.md" \
  && ok "scorer has a refute mode" \
  || bad "scorer missing refute mode"
grep -qi "prior-review" "$ROOT/agents/code-review-scorer.md" \
  && ok "scorer verifies prior-review findings" \
  || bad "scorer missing prior-review verification note"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL on all four new assertions.

- [ ] **Step 3: Add the refute-mode branch + prior-review note to the scorer**

In `agents/code-review-scorer.md`, after the `## Verifying history findings` section (line 55), insert:

```markdown
## Refute mode (skeptic votes)

If your task says **REFUTE MODE**, invert your stance: assume this finding is a
false positive and actively try to prove it wrong — pre-existing, intentional,
linter-caught, or simply not a real runtime issue. Read the file and history to
build the refutation. Only score >= 70 if, after a genuine attempt, you CANNOT
refute it. (The orchestrator runs one normal scorer + two refute-mode scorers on
critical/high findings and takes the median; your job is to be the skeptic.)

## Verifying prior-review findings

For `prior-review` findings, confirm the cited prior PR comment exists and that the
current change actually re-triggers the concern. If the comment was resolved/addressed,
targets lines this change did not touch, or no longer applies, score it low (<= 25).
```

- [ ] **Step 4: Add the panel logic to Pass 3 step 2**

In `skills/code-review-deep/SKILL.md` Pass 3 step 2 (after the existing scorer dispatch sentence, line ~144), insert:

```markdown
   For findings of severity **critical** or **high**, run a 3-vote **refuter panel**
   instead of a single scorer: one normal `code-review-scorer` plus two dispatched
   with **REFUTE MODE** in their task. The final score is the **median** of the three
   (mathematically identical to "confirmed iff >= 2 of 3 score >= 70"), so it drops into
   the >= 70 / 16-69 / <= 15 partition with no rule change. The panel scorers inherit the
   session/best model (a quality floor — a refuter must out-reason the finder); do NOT
   pin them to a cheaper model. Medium/low findings keep the single scorer.
```

- [ ] **Step 5: Run test + validator to verify pass**

Run: `bash tests/test-code-review-deep.sh && bash scripts/validate-plugin.sh`
Expected: test PASS for refuter panel, median-of-3, refute mode, prior-review verification; validator OK; the existing `code-review-scorer must NOT pin 'model:'` assertion still PASSES (we added no `model:` pin).

- [ ] **Step 6: Commit**

```bash
git add agents/code-review-scorer.md skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "code-review-deep: adversarial refuter panel on critical/high findings (C3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: C5 + C6 — Pass-3 wave cap + cost-ownership note

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` — Pass 3 (wave cap) + Notes/model section (cost-ownership)
- Test: `tests/test-code-review-deep.sh`

**Interfaces:**
- Consumes: `ORCH`, `ok`/`bad` in the test.
- Produces: documented Pass-3 ≤5 wave cap shared by scorers + refuters; a cost-ownership/self-tiering note cross-referencing cost-router.

- [ ] **Step 1: Write the failing tests**

In `tests/test-code-review-deep.sh`, after the C3 assertions, add:

```bash
# C5: Pass 3 scoring obeys the same <=5 wave cap (refuters multiply Pass-3 agents).
grep -qi "scoring shares the .*wave cap" "$ORCH" \
  && ok "Pass 3 scoring shares the <=5 wave cap" \
  || bad "Pass 3 missing the shared <=5 wave-cap note"
# C6: the skill documents the cost-router ownership boundary (self-tiering).
grep -qi "cost-router does not override" "$ORCH" \
  && ok "skill documents the cost-ownership boundary" \
  || bad "skill missing the cost-ownership / self-tiering note"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `Pass 3 missing the shared <=5 wave-cap note`, `skill missing the cost-ownership note`.

- [ ] **Step 3: Add the Pass-3 wave-cap sentence (C5)**

In `skills/code-review-deep/SKILL.md`, at the end of Pass 3 step 2 (after the Task-7 panel paragraph), add:

```markdown
   Dispatch scorers and refuter-panel votes in the same **waves of at most 5
   concurrent agents** as Pass 2 — Pass 3 scoring shares the ≤5 wave cap (the
   refuter panel multiplies Pass-3 agents ×3 for each critical/high finding, so this
   bounds peak agent count and RAM on a constrained host, exactly as in Pass 2).
```

- [ ] **Step 4: Add the cost-ownership note (C6)**

In `skills/code-review-deep/SKILL.md`, in the `## Notes` section near the model-vs-agent-names note (line ~293), add:

```markdown
- **Cost ownership.** Model tiering here is the skill's OWN (self-routing). cost-router
  does not override it — cost-router only routes a review request *to* this skill (see
  `cost-router` setup), because it cannot tier a running skill's internal dispatches.
  The per-pass model choices in this skill are correctness/resource decisions, not price
  decisions: best-model-for-code and the code-as-prompt `.md` exception are accuracy
  floors; the wave caps and unit-size bounds are RAM/peak-agent ceilings.
```

- [ ] **Step 5: Run test + validator to verify pass**

Run: `bash tests/test-code-review-deep.sh && bash scripts/validate-plugin.sh`
Expected: test PASS for the Pass-3 wave-cap note and the cost-ownership note; validator OK.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "code-review-deep: Pass-3 wave cap for the refuter panel + cost-ownership note (C5,C6)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: second-brain release (full suite + dogfood gate + version)

**Files:**
- Modify: `.claude-plugin/plugin.json` (version), `CHANGELOG.md` (entry)

**Interfaces:**
- Consumes: Tasks 4–8 landed.
- Produces: a second-brain patch release with a clean test suite and a dogfood pass.

- [ ] **Step 1: Run the full test suite**

Run: `make test`
Expected: all `tests/test-*.sh` pass (especially `test-classify-prompt.sh` and `test-code-review-deep.sh`) and the `mcp/` Vitest suite passes. Zero failures.

- [ ] **Step 2: Run the release gate**

Run: `make release-check`
Expected: tests pass + vector-deps smoke-import OK.

- [ ] **Step 3: Dogfood the improved skill on this branch**

Invoke `/second-brain:code-review-deep` against this branch's diff vs `main` (no `--comment`; terminal output). Confirm: the new prior-review lens, the inline-comment checklist, and the refuter panel all run without error, and the review of this very change surfaces no confirmed (≥70) bug findings (architectural/lower-confidence notes are acceptable). This is the independent-oracle gate from the spec §7; record the result.

- [ ] **Step 4: Bump version + CHANGELOG**

Confirm current: `jq -r '.version' .claude-plugin/plugin.json` → `0.33.15`. Edit `.claude-plugin/plugin.json` to `0.33.16`. Prepend to `CHANGELOG.md`:

```markdown
## 0.33.16 — 2026-06-24

- code-review-deep Bundle B: prior-PR-comment mining (finding-generating, Pass 0,
  +`Bash(gh api *)`), inline-comment-compliance checklist item, adversarial refuter
  panel (median-of-3) on critical/high findings, least-privilege `disallowedTools` on
  the five read-only review agents, Pass-3 wave cap for the panel, and a cost-ownership
  note documenting that the skill self-tiers (cost-router routes to it, never tiers it).
```

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -m "release: 0.33.16 — code-review-deep Bundle B (C1-C6)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §2 ownership boundary → Task 8 (C6 note) + Task 1/2 (route-not-tier behavior). ✓
- §3 B1 (REVIEW detector + detect-&-degrade) → Task 1. ✓
- §3 B2 (advise-only bullets) → Task 2. ✓
- §4 C1 (prior-PR mining + gh api + prior-review category) → Task 6. ✓
- §4 C2 (inline-comment checklist) → Task 5. ✓
- §4 C3 (refuter panel + refute mode + prior-review verification) → Task 7. ✓
- §4 C4 (disallowedTools ×5) → Task 4. ✓
- §4 C5 (Pass-3 wave cap) → Task 8. ✓
- §4 C6 (cost-ownership note) → Task 8. ✓
- §7 testing (independent-oracle hook tests + dogfood gate) → Tasks 1/4–8 (grep/JSON oracle) + Task 9 step 3 (dogfood). ✓
- §8 rollout (cost-router 0.2.2 + second-brain 0.33.16) → Tasks 3, 9. ✓
- §6 deferred (#3, #4b) → intentionally absent. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows literal content. ✓

**3. Type/name consistency:** `prior-review` category defined in Task 6, consumed by Task 7's scorer note and the Pass 4 category list — consistent spelling throughout. `REVIEW` flag / `SB_REVIEW_SKILL` / `RNUDGE` introduced and used only within Task 1. Test helpers (`assert_review_skill`/`assert_review_degraded`/`assert_no_review`) defined and called in Task 1. The "no `model:` pin" invariant is preserved (Task 7 adds prompt text, not frontmatter), so the existing scorer/unit-reviewer model-pin guards keep passing. ✓
