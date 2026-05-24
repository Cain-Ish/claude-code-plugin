# Dream Auto-Stage at Threshold — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Make `/second-brain:dream` fire semi-automatically when ≥N new transcripts accumulate since the last dream, plus fix the verify-gate firing on doc-only commits. Acceptance of staged diffs stays manual.

**Architecture:** A new SessionStart hook script `dream-autostage.sh` counts transcripts newer than the most-recent dream directory; at/above threshold it stages a pending dream via the existing `dream-snapshot.sh` and emits a banner instructing Claude to spawn the `second-brain:dream-runner` agent. The legacy session-count nag in `session-load.sh` is gated behind the kill switch so the two never double up. Separately, `stop-verify-gate.sh` learns to ignore doc-file edits.

**Tech Stack:** Bash hooks, `jq`, `find` (mtime watermark), the existing `tests/test-*.sh` harness (auto-discovered by `tests/run-all.sh`), `shellcheck`.

**Spec:** `docs/specs/2026-05-24-dream-auto-stage-design.md`

---

## File Structure

- **Create** `scripts/dream-autostage.sh` — the SessionStart auto-stage hook (one concern, like `discover-*.sh`).
- **Create** `tests/test-dream-autostage.sh` — sandboxed tests for the above.
- **Modify** `scripts/stop-verify-gate.sh:32-38` — file-type filter on `CODE_MODIFIED`.
- **Modify** `tests/test-stop-verify-gate.sh` — add doc-only / mixed cases.
- **Modify** `scripts/session-load.sh:86-89` — gate legacy nag behind `SB_DREAM_AUTOSTAGE=off`.
- **Modify** `hooks.json` — register `dream-autostage.sh` after `session-load.sh`.
- **Modify** `.claude-plugin/plugin.json` — version `0.11.1` → `0.12.0`.

---

## Task 1: Fix verify-gate file-type filter (independent, ship first)

**Files:**
- Modify: `scripts/stop-verify-gate.sh:32-38`
- Test: `tests/test-stop-verify-gate.sh`

- [ ] **Step 1: Add failing test fixtures + cases**

Add this helper after `add_write_turn` (around line 67) in `tests/test-stop-verify-gate.sh`:

```bash
add_md_write_turn() {
  local file="$1"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"docs/specs/foo.md","content":"# hi"}}]}}' >> "$file"
}
```

Add these cases just before the final `echo ""` / Results block (after Test 9):

```bash
# Test 10: Doc-only edit (.md) + no verification → approve (file-type filter)
T=$(mk_transcript)
add_qa_turn "$T"
add_md_write_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_approve "doc-only .md write, no verification" "$OUT"

# Test 11: Mixed .md + code (.ts) + no verification → block (code present)
T=$(mk_transcript)
add_md_write_turn "$T"
add_edit_turn "$T"
OUT=$(mk_input "$T" | bash "$GATE" 2>/dev/null || true)
assert_block "mixed md + code, no verification" "$OUT"
```

- [ ] **Step 2: Run tests to verify Test 10 fails**

Run: `bash tests/test-stop-verify-gate.sh`
Expected: FAIL on "doc-only .md write" — current gate blocks any Write (Test 11 already passes; Test 4 still passes).

- [ ] **Step 3: Apply the file-type filter**

In `scripts/stop-verify-gate.sh`, replace the `CODE_MODIFIED` jq (lines 32-38):

```bash
CODE_MODIFIED=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
  | .input.file_path // ""
  | select(. != "")
  | select((endswith(".md") or endswith(".markdown") or endswith(".txt") or test("(^|/)docs/")) | not)
' "$TRANSCRIPT" 2>/dev/null | head -1)
```

(Outputs the first *non-doc* file_path; `CODE_MODIFIED` stays empty when only docs were touched. Exclude-known-docs rather than allowlist-code, so a new code extension is never silently ungated — matches the script's fail-open philosophy.)

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash tests/test-stop-verify-gate.sh`
Expected: `Results: 11 passed, 0 failed`

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/stop-verify-gate.sh`
Expected: no errors (warnings acceptable if pre-existing; compare against `git stash` baseline if unsure).

- [ ] **Step 6: Commit**

```bash
git add scripts/stop-verify-gate.sh tests/test-stop-verify-gate.sh
git commit -m "fix(verify-gate): ignore doc-only edits (.md/.txt/docs) when gating

stop-verify-gate.sh flagged any Write/Edit as code-modified, blocking
completion on doc-only commits. Filter .input.file_path by doc patterns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Create `dream-autostage.sh` + tests

**Files:**
- Create: `scripts/dream-autostage.sh`
- Test: `tests/test-dream-autostage.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-dream-autostage.sh`:

```bash
#!/bin/bash
# Tests for dream-autostage.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
AUTOSTAGE="$SCRIPT_DIR/dream-autostage.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki"
echo "# seed" > "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki/seed.md"

PASS=0; FAIL=0

assert_empty() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then PASS=$((PASS+1)); echo "  PASS: $label (no banner)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — expected no banner, got: $out"; fi
}
assert_banner() {
  local label="$1" out="$2"
  if printf '%s' "$out" | grep -q 'dream auto-staged'; then PASS=$((PASS+1)); echo "  PASS: $label (banner)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — expected banner, got: $out"; fi
}
mk_transcripts() {  # $1 = count
  local n="$1" i
  for i in $(seq 1 "$n"); do
    echo "session $i" > "$BRAIN_DIR/transcripts/sess-$i-$RANDOM.txt"
  done
}
reset_brain() {
  rm -rf "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
  mkdir -p "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
}

echo "=== dream-autostage.sh tests ==="

# Test 1: kill switch → no banner
reset_brain; mk_transcripts 20
OUT=$(SB_DREAM_AUTOSTAGE=off bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "kill switch off" "$OUT"

# Test 2: no dream yet, >= threshold → banner
reset_brain; mk_transcripts 12
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_banner "no dream + 12 transcripts" "$OUT"

# Test 3: below threshold → no banner
reset_brain; mk_transcripts 3
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "below threshold" "$OUT"

# Test 4: in-flight dream (running) → no banner
reset_brain; mk_transcripts 20
mkdir -p "$BRAIN_DIR/dreams/drm_inflight"
echo '{"id":"drm_inflight","status":"running"}' > "$BRAIN_DIR/dreams/drm_inflight/status.json"
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "in-flight dream" "$OUT"

# Test 5: completed dream + enough NEW transcripts after it → banner
reset_brain
mkdir -p "$BRAIN_DIR/dreams/drm_old"
echo '{"id":"drm_old","status":"completed"}' > "$BRAIN_DIR/dreams/drm_old/status.json"
sleep 1                      # ensure transcripts mtime > dream dir
mk_transcripts 12
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_banner "completed dream + 12 new transcripts" "$OUT"

# Test 6: completed dream NEWER than all transcripts → no banner
reset_brain
mk_transcripts 12
sleep 1
mkdir -p "$BRAIN_DIR/dreams/drm_recent"
echo '{"id":"drm_recent","status":"completed"}' > "$BRAIN_DIR/dreams/drm_recent/status.json"
touch "$BRAIN_DIR/dreams/drm_recent"   # make dream dir the newest
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "transcripts older than dream" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-dream-autostage.sh`
Expected: FAIL — `dream-autostage.sh` does not exist yet (`bash: ... No such file`); Test 1 onward error out.

- [ ] **Step 3: Implement `scripts/dream-autostage.sh`**

```bash
#!/bin/bash
# dream-autostage.sh — SessionStart hook. When >= SB_DREAM_NEW_THRESHOLD new
# transcripts have landed since the most recent dream, stage a pending dream
# via dream-snapshot.sh and instruct Claude to spawn the background runner.
# Acceptance of the staged diff stays manual.
#
# Kill switch: SB_DREAM_AUTOSTAGE=off   Threshold: SB_DREAM_NEW_THRESHOLD (default 10)
# Always fails open — any error → exit 0, no banner.
set -u
source "$(dirname "$0")/lib.sh"

[ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && exit 0

THRESHOLD="${SB_DREAM_NEW_THRESHOLD:-10}"
DREAMS_DIR="$BRAIN_DIR/dreams"
TX_DIR="$BRAIN_DIR/transcripts"

[ -d "$TX_DIR" ] || exit 0

NEWEST_DREAM=$(ls -1dt "$DREAMS_DIR"/drm_*/ 2>/dev/null | head -1)
NEWEST_DREAM="${NEWEST_DREAM%/}"

if [ -n "$NEWEST_DREAM" ] && [ -f "$NEWEST_DREAM/status.json" ]; then
  s=$(jq -r '.status // ""' "$NEWEST_DREAM/status.json" 2>/dev/null)
  if [ "$s" = "pending" ] || [ "$s" = "running" ]; then
    exit 0   # don't stack on an in-flight dream
  fi
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' -newer "$NEWEST_DREAM" 2>/dev/null | wc -l | tr -d ' ')
else
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
fi

[ "${NEW:-0}" -ge "$THRESHOLD" ] || exit 0

DID=$(bash "$(dirname "$0")/dream-snapshot.sh" --max-count 100 2>/dev/null)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$DID" ]; then
  sb_log_error "dream-autostage.sh" "stage failed rc=$RC new=$NEW" 0
  exit 0
fi

printf '## ⓘ second-brain — dream auto-staged\n%s new transcripts since last dream. Dream %s staged (pending).\n**Spawn the `second-brain:dream-runner` agent now (run_in_background: true, dream_id=%s) before responding to the user.** Acceptance of its diff stays manual.\n\n' \
  "$NEW" "$DID" "$DID"
exit 0
```

- [ ] **Step 4: Make executable and run tests to verify pass**

Run: `chmod +x scripts/dream-autostage.sh && bash tests/test-dream-autostage.sh`
Expected: `Results: 6 passed, 0 failed`

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/dream-autostage.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/dream-autostage.sh tests/test-dream-autostage.sh
git commit -m "feat(dream): dream-autostage.sh — stage a dream at new-transcript threshold

Counts transcripts newer than the most-recent dream dir; at >= threshold
stages via dream-snapshot.sh and emits a banner telling Claude to spawn the
background runner. Kill switch SB_DREAM_AUTOSTAGE, threshold SB_DREAM_NEW_THRESHOLD.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire into hooks + gate the legacy nag

**Files:**
- Modify: `hooks.json` (SessionStart `startup|resume|clear` block)
- Modify: `scripts/session-load.sh:86-89`

- [ ] **Step 1: Register the hook**

In `hooks.json`, in the SessionStart hooks array (matcher `startup|resume|clear`), add a new entry immediately after the `session-load.sh` command:

```json
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/dream-autostage.sh", "timeout": 20 }
```

(Timeout 20s: `dream-snapshot.sh` copies the wiki tree; generous headroom over its typical sub-second run.)

- [ ] **Step 2: Validate hooks.json parses**

Run: `jq empty hooks.json && echo OK`
Expected: `OK`

- [ ] **Step 3: Gate the legacy nag in session-load.sh**

Replace lines 86-89 of `scripts/session-load.sh`:

```bash
if [ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && [ "$SESSION_COUNT" -ge "$DREAM_THRESHOLD" ]; then
  sb_append "$(printf '## ⓘ second-brain — dream consolidation suggested\n%s sessions since last dream (threshold: %s).\nRun: `/second-brain:dream --background` — mines transcripts for missed learnings, stages changes for review.\n\n' \
    "$SESSION_COUNT" "$DREAM_THRESHOLD")" "dream-cadence-banner" 300
fi
```

(Only the `if` condition gains the `SB_DREAM_AUTOSTAGE = off` guard; banner body unchanged. When autostage is on — the default — `dream-autostage.sh` owns the nudge, so this suppresses the double banner.)

- [ ] **Step 4: Check no existing test asserts the cadence banner under default env**

Run: `grep -rl 'dream-cadence-banner\|dream consolidation suggested' tests/`
Expected: if any session-load test asserts this banner *appears* with autostage unset, update it to set `SB_DREAM_AUTOSTAGE=off` (the banner is now off-by-default). If grep returns nothing, no action.

- [ ] **Step 5: Run the hooks regression + session-load tests**

Run: `bash tests/test-hooks-regression.sh && bash tests/test-session-load-compact.sh && bash tests/test-session-load-auth-banner.sh`
Expected: all pass. If a session-load test fails on the missing nag, apply Step 4's fix and rerun.

- [ ] **Step 6: Commit**

```bash
git add hooks.json scripts/session-load.sh
git commit -m "feat(dream): register dream-autostage hook; gate legacy nag behind kill switch

dream-autostage.sh runs on startup|resume|clear after session-load.sh. The
session-count 'suggested' nag now only shows when SB_DREAM_AUTOSTAGE=off, so
the two paths never double-banner.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Version bump + full suite

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version**

In `.claude-plugin/plugin.json`, change `"version": "0.11.1"` → `"version": "0.12.0"`.

- [ ] **Step 2: Run the full test suite**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN` — includes the new `test-dream-autostage` and updated `test-stop-verify-gate`, plus the mcp/ vitest suite.

- [ ] **Step 3: Code review + security review**

Invoke `/review` and `/security-review` on the branch diff. Focus: the `dream-autostage.sh` → `dream-snapshot.sh` shell-out (arg construction, no untrusted input in the command) and the verify-gate jq change (no regression in the block path). Address any findings.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "chore: bump to 0.12.0 — dream auto-stage + verify-gate doc filter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** §3 watermark → Task 2 Step 3 `find -newer`. §4 hook script → Task 2 + Task 3 Step 1. §5 spawn seam → banner text in Task 2 Step 3. §7 config (`SB_DREAM_AUTOSTAGE`, `SB_DREAM_NEW_THRESHOLD`, nag suppression) → Task 2 + Task 3 Step 3. §8 edge cases → Task 2 tests (in-flight, no-dream, below-threshold, older-transcripts) + fail-open in script. §9 verify-gate fix → Task 1. §11 testing → Tasks 1-2 tests + Task 4 full suite. No gaps.
- **Placeholder scan:** none — every code/test step shows full content; commands have expected output.
- **Type/name consistency:** `SB_DREAM_AUTOSTAGE`, `SB_DREAM_NEW_THRESHOLD`, `NEWEST_DREAM`, `dream auto-staged` banner marker used identically across script, tests, and session-load guard.

## Out of scope (per spec §10)
Auto-triggering improve/reindex/lint; auto-accept of diffs; per-project dream cadence. This task is the template for the first of those later.
