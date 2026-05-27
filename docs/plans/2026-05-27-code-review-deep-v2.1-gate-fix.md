# code-review-deep v2.1 (gate fix) Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Stop `code-review-deep` from silently discarding the critical bugs its Opus reviewers find — by matching the scorer to the reviewer, surfacing the previously-dropped 16–69 confidence band, and removing the false-positive auto-record ratchet.

**Architecture:** A prompt/skill change, not application code. Two agent frontmatter edits (`code-review-scorer.md` un-pins its model to inherit; `code-review-unit-reviewer.md` gains `effort: high`, gated on a capability check) and two skill-prose edits in `skills/code-review-deep/SKILL.md` (Pass 3 partition + Pass 4 output). Behavior is LLM-driven, so the test suite (`tests/test-code-review-deep.sh`) guards the structural contract, not the review output.

**Tech Stack:** Markdown + YAML frontmatter (Claude Code skills/agents); Bash structural tests run by `tests/run-all.sh` / `make test`; `scripts/validate-plugin.sh` for plugin validity; `jq` for plugin.json.

**Spec:** `docs/specs/2026-05-27-code-review-deep-v2.1-gate-fix-design.md`

**Branch:** `code-review-deep-v2.1-gate-fix` (spec already committed there).

---

## Verification Outcomes (filled in by Task 0 — gates Task 2)

- `EFFORT_ON_DISPATCH` = **yes** — `effort:` is a supported agent frontmatter key and
  "Overrides the session effort level" for dispatched subagents; valid values include
  `high` (Source: code.claude.com/docs/en/sub-agents.md, "Supported frontmatter
  fields", lines 261–283). → **Task 2 lands** `effort: high` on the unit-reviewer.

---

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `agents/code-review-scorer.md` | Confidence scorer. v2.1: **un-pin `model:`** → inherits session model (matches the reviewer) | 1 |
| `agents/code-review-unit-reviewer.md` | Per-unit bug reviewer. v2.1: **+ `effort: high`** (conditional on Task 0) | 2 |
| `skills/code-review-deep/SKILL.md` | Orchestration prose. v2.1: Pass 3 partition (surface 16–69) + Pass 4 output (lower-confidence section; drop FP auto-record) | 3, 4 |
| `tests/test-code-review-deep.sh` | Structural/wiring guard | 1, 2, 3, 4 |
| `.claude-plugin/plugin.json` | Version → 0.18.0 | 5 |
| `skills/upgrade/SKILL.md` | Migration row for 0.18.0 | 5 |

---

## Task 0: Verify whether `effort:` is honored on a dispatched agent

**Files:** none (decision spike). Record the result in this plan's "Verification Outcomes" section.

- [ ] **Step 1: Ask claude-code-guide**

Dispatch the `claude-code-guide` agent with this question:

> In the current Claude Code release (2.1.x), when an orchestrator dispatches a sub-agent via the Task/Agent tool, does an `effort:` frontmatter key on that sub-agent (e.g. `effort: high`) take effect — i.e. does the sub-agent reason at that effort level? Or is `effort:` ignored for dispatched sub-agents? Cite the docs.

- [ ] **Step 2: Record the verdict**

Edit this file's "Verification Outcomes" section, setting `EFFORT_ON_DISPATCH` to `yes` or `no` with a one-line citation.

- [ ] **Step 3: Commit the decision record**

```bash
git add docs/plans/2026-05-27-code-review-deep-v2.1-gate-fix.md
git commit -m "chore(code-review-deep): record v2.1 effort-on-dispatch verification"
```

---

## Task 1: Scorer inherits the session model (primary fix)

**Files:**
- Modify: `agents/code-review-scorer.md` (frontmatter `model:` line)
- Test: `tests/test-code-review-deep.sh:35-38`

- [ ] **Step 1: Replace the "scorer is Haiku" assertion in the test**

In `tests/test-code-review-deep.sh`, replace the block at lines 35–38:

```bash
# Scorer stays Haiku (mechanical verify-against-rubric).
scorer_fm="$(frontmatter "$ROOT/agents/code-review-scorer.md")"
echo "$scorer_fm" | grep -qi "^model: *haiku$" && ok "code-review-scorer is Haiku" \
  || bad "code-review-scorer must be 'model: haiku'"
```

with (mirrors the unit-reviewer top-level-key check so a `description:` body line can't false-trip it):

```bash
# Scorer must NOT pin a model — v2.1 un-pins it so it inherits the session/best
# model, matching the reviewer it gates (removes the capability inversion).
scorer_fm="$(frontmatter "$ROOT/agents/code-review-scorer.md")"
scorer_keys="$(printf '%s\n' "$scorer_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
if printf '%s\n' "$scorer_keys" | grep -qi '^model:'; then
  bad "code-review-scorer must NOT pin 'model:' (v2.1: inherits to match the reviewer)"
else
  ok "code-review-scorer inherits model (no model: pin)"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `code-review-scorer must NOT pin 'model:'` (the agent still has `model: haiku`).

- [ ] **Step 3: Remove the model pin from the scorer**

In `agents/code-review-scorer.md`, delete the frontmatter line `model: haiku`. The surrounding lines become:

```
  </example>
color: green
tools: Read, Bash(git diff *)
---
```

(Leave `name`, `description`, `color`, `tools` intact. No body change — the rubric is model-agnostic.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS line `code-review-scorer inherits model (no model: pin)`. (Skill-section assertions added in Tasks 3–4 are not present yet, so those new checks don't exist — the suite should otherwise be green.)

- [ ] **Step 5: Commit**

```bash
git add agents/code-review-scorer.md tests/test-code-review-deep.sh
git commit -m "fix(code-review-deep): scorer inherits session model (match the reviewer)"
```

---

## Task 2: Unit-reviewer reasons harder (`effort: high`) — CONDITIONAL on `EFFORT_ON_DISPATCH = yes`

> **If Task 0 set `EFFORT_ON_DISPATCH = no`, skip this entire task.** The unit-reviewer stays as-is; the other three changes ship without it.

**Files:**
- Modify: `agents/code-review-unit-reviewer.md` (frontmatter)
- Test: `tests/test-code-review-deep.sh` (after the lean-return check, ~line 56)

- [ ] **Step 1: Add the effort assertion to the test**

In `tests/test-code-review-deep.sh`, immediately after the lean-return check (the block ending at line 56), insert:

```bash
# v2.1: unit-reviewer reasons harder (effort: high). Asserted only because Task 0
# confirmed dispatched agents honor effort:. ur_fm is the frontmatter from above.
ur_effort_keys="$(printf '%s\n' "$ur_fm" | grep -oE '^[A-Za-z_-]+:' || true)"
printf '%s\n' "$ur_effort_keys" | grep -qi '^effort:' \
  && ok "unit-reviewer sets effort (deeper reasoning)" \
  || bad "unit-reviewer missing 'effort: high'"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `unit-reviewer missing 'effort: high'`.

- [ ] **Step 3: Add `effort: high` to the unit-reviewer frontmatter**

In `agents/code-review-unit-reviewer.md`, change the frontmatter tail from:

```
color: cyan
tools: Read, Bash(git diff *)
---
```

to:

```
color: cyan
effort: high
tools: Read, Bash(git diff *)
---
```

(Leave `name`, `description`, `color`, `tools` intact. Do NOT add a `model:` line — it must still inherit.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `unit-reviewer sets effort (deeper reasoning)` AND still PASS `code-review-unit-reviewer inherits model (no model: pin)` (the no-model-pin guard ignores `effort:`).

- [ ] **Step 5: Commit**

```bash
git add agents/code-review-unit-reviewer.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): unit-reviewer reasons at effort: high"
```

---

## Task 3: Surface the 16–69 "lower-confidence" band

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (Pass 3 partition; Pass 4 output)
- Test: `tests/test-code-review-deep.sh` (after the arch-notes exclusion check, ~line 156)

- [ ] **Step 1: Add the lower-confidence assertion to the test**

In `tests/test-code-review-deep.sh`, immediately after the arch-notes exclusion check (the block ending at line 156), insert:

```bash
  # v2.1: the 16–69 band is surfaced, not dropped — the orchestrator must render a
  # distinct lower-confidence section.
  grep -qi "Lower-confidence findings" "$ORCH" \
    && ok "orchestrator surfaces the lower-confidence (16–69) band" \
    || bad "orchestrator missing the 'Lower-confidence findings' section"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `orchestrator missing the 'Lower-confidence findings' section`.

- [ ] **Step 3: Rewrite the Pass 3 partition**

In `skills/code-review-deep/SKILL.md`, replace the Pass 3 partition block (lines 108–112):

```
3. **Partition** the scored findings into three buckets (keep all three until Pass 4):
   - **report** (score **≥ 70**): the review output, sorted by severity then score.
   - **killed-hard** (score **≤ 15**): NOT shown in the review, but retained to feed
     Pass 4's false-positive auto-record. Do not discard these before Pass 4.
   - **uncertain** (score **16–69**): dropped entirely — neither reported nor recorded.
```

with:

```
3. **Partition** the scored findings into three buckets (keep all until Pass 4):
   - **confirmed** (score **≥ 70**): the numbered review output, sorted by severity then score.
   - **low-confidence** (score **16–69**): NOT confirmed, but surfaced in Pass 4 as a
     separate, clearly-labeled "Lower-confidence findings" section so a real but
     hard-to-verify bug is never silently dropped. Retain until Pass 4.
   - **killed-hard** (score **≤ 15**): dropped — neither shown nor recorded. The scorer
     now inherits the session model (matches the reviewer it gates), so a ≤15 kill is
     trustworthy enough to drop without recording.
```

- [ ] **Step 4: Add the lower-confidence section to the Pass 4 output**

In `skills/code-review-deep/SKILL.md` Pass 4, insert a new bullet immediately BEFORE the `- **Architectural notes (advisory).**` bullet (currently line 135). The new bullet:

```
   - **Lower-confidence findings (unverified).** If the low-confidence bucket
     (score 16–69) is non-empty, append — after the numbered confirmed findings and
     before the architectural notes — a section titled `Lower-confidence findings
     (unverified — may be false positives)`. Lead with one line noting these were
     found but not confirmed at high confidence and may include false positives, then
     list each as `- **<brief>** (category: severity)` followed by its `<link>`. Keep
     it visually distinct from the numbered confirmed list and from the architectural
     notes so the three are never conflated. For `--comment`, post it under that same
     subhead. If the bucket is empty, omit the section.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `orchestrator surfaces the lower-confidence (16–69) band`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "feat(code-review-deep): surface the 16-69 lower-confidence band"
```

---

## Task 4: Remove the false-positive auto-record ratchet

**Files:**
- Modify: `skills/code-review-deep/SKILL.md` (Pass 4 false-positive write-back; per-entry `source:` field)
- Test: `tests/test-code-review-deep.sh` (after the lower-confidence check from Task 3)

- [ ] **Step 1: Add the no-auto-record assertion to the test**

In `tests/test-code-review-deep.sh`, immediately after the lower-confidence check from Task 3, insert:

```bash
  # v2.1: the FP auto-record ratchet is removed — the store grows ONLY from user
  # dismissals. The write-back heading carries that contract sentinel.
  grep -qi "user dismissals only" "$ORCH" \
    && ok "FP write-back is user-dismissals-only (no auto-record ratchet)" \
    || bad "orchestrator must record FPs from user dismissals only (v2.1)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `orchestrator must record FPs from user dismissals only (v2.1)`.

- [ ] **Step 3: Rewrite the Pass 4 false-positive write-back**

In `skills/code-review-deep/SKILL.md`, replace the write-back block (lines 145–155):

```
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
```

with:

```
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
```

- [ ] **Step 4: Simplify the per-entry `source:` field**

In `skills/code-review-deep/SKILL.md`, the per-entry template (line 167) reads:

```
         - source: <auto-killed score=<n> | user-dismissed>
```

Replace it with (auto-killed is gone):

```
         - source: user-dismissed
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS `FP write-back is user-dismissals-only (no auto-record ratchet)`, and the final line `PASS: <n>, FAIL: 0`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "fix(code-review-deep): drop FP auto-record ratchet (user dismissals only)"
```

---

## Task 5: Release plumbing — version, migration row, full gate

**Files:**
- Modify: `.claude-plugin/plugin.json` (version)
- Modify: `skills/upgrade/SKILL.md` (migration table)

- [ ] **Step 1: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.17.0"` to `"version": "0.18.0"`.

- [ ] **Step 2: Add the migration row**

In `skills/upgrade/SKILL.md`, add a row immediately after the `| **0.17.0** | …` row, matching the existing 3-column format:

```
| **0.18.0** | code-review-deep v2.1 — fix the gate, not the finder. (a) `code-review-scorer` un-pins `model: haiku` → inherits the session/best model, so the scorer matches the Opus reviewer it gates (removes the capability inversion that scored subtle finds "unverified" and dropped them). (b) The 16–69 confidence band is no longer dropped — it is surfaced in Pass 4 as a separate "Lower-confidence findings (unverified)" section, distinct from the numbered confirmed list and the architectural notes. (c) The false-positive auto-record ratchet is removed: the store grows ONLY from explicit user dismissals (a wrong auto-suppression would hide a real bug indefinitely). (d) Unit-reviewer reasons at `effort: high` IFF dispatched agents honor it (verify-first). Prompt/agent/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
```

> If Task 0 set `EFFORT_ON_DISPATCH = no`, drop clause "(d)" from the row text above.

- [ ] **Step 3: Verify the migration-row gate passes**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.18.0`.

- [ ] **Step 4: Validate plugin structure**

Run: `bash scripts/validate-plugin.sh`
Expected: `OK: all plugin files valid` (or the script's success line).

- [ ] **Step 5: Run the full suite**

Run: `make test`
Expected: `ALL GREEN` (pass > 0, fail: 0). If the MCP vitest step is slow/unavailable, scope to shell tests with `SB_RUN_ALL_VITEST=0 make test`, then run vitest separately.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md
git commit -m "chore(release): code-review-deep v2.1 — bump 0.18.0 + migration row"
```

- [ ] **Step 7: Deep-review release gate (standing release rule)**

Run `/second-brain:code-review-deep` on this branch (no `--comment`) and read the output. This dogfoods v2.1 on its own change — confirm the new "Lower-confidence findings" section renders (or is correctly omitted when empty) and that no real findings are outstanding. (Verification step — report the output; not a commit gate.)

---

## Self-Review (completed by plan author)

- **Spec coverage:** Change 1 (scorer inherits) → Task 1; Change 2 (`effort: high`, verify-first) → Tasks 0 + 2; Change 3 (surface 16–69) → Task 3; Change 4 (drop FP ratchet) → Task 4; verify-first gate → Task 0; testing requirements → assertions in Tasks 1–4; release plumbing → Task 5; deferred fork → spec only (no task, by design). No uncovered spec section.
- **Placeholder scan:** the sole `TBD` is `EFFORT_ON_DISPATCH` in Verification Outcomes (filled by Task 0, by design). Every edit step shows literal old/new content.
- **Type/name consistency:** the contract sentinels used in skill edits and asserted in the test match exactly — `Lower-confidence findings` (Task 3 Step 4 ↔ Task 3 Step 1) and `user dismissals only` (Task 4 Step 3 ↔ Task 4 Step 1). The scorer no-model-pin and unit-reviewer effort checks both reuse the existing top-level-key extraction idiom. Agent type strings are unchanged from v2.
