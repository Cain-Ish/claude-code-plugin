# Ruflo-derived hardening — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock in three S-effort improvements derived from `ruvnet/ruflo` research — a SessionStart-on-compact regression test, an `allowed-tools` validator rule, and a `scripts/verify.sh` runtime smoke check surfaced via `/second-brain:status`.

**Architecture:** All work additive. No changes to hooks behavior, no new MCP tools, no migrations. Each item ships with its own regression test. Tests sandbox under `mktemp` with `HOME=$tmpdir` per existing convention.

**Tech Stack:** bash, jq, existing `lib.sh` helpers (`sb_log_error`, `sb_require_jq`, `BRAIN_DIR`), existing `validate-plugin.sh` frontmatter parser.

**Spec:** `docs/specs/2026-05-02-ruflo-derived-hardening-design.md`

---

## File structure

| Path | Action | Responsibility |
|---|---|---|
| `tests/test-session-load-compact.sh` | create | Assert `session-load.sh` re-emits hot tier on `source: "compact"` SessionStart payload |
| `hooks/hooks.json` | modify | Add `_comment` key near `SessionStart` matcher documenting why PreCompact reload is unnecessary |
| `tests/test-validate-plugin-allowed-tools.sh` | create | Sandboxed skills tree, mutate one SKILL.md to drop `allowed-tools:`, assert `validate-plugin.sh` exits non-zero |
| `scripts/validate-plugin.sh` | modify line 92 | Add `allowed-tools` to required-fields for-loop |
| `tests/test-verify.sh` | create | Cover 5 failure modes + clean state of `verify.sh` |
| `scripts/verify.sh` | create | Runtime smoke check: USER.md, hot-tier line cap, MCP dist, error-log freshness, active PROJECT.md |
| `skills/status/SKILL.md` | modify | New Step 6 invokes `verify.sh`; renumber existing Step 6 → Step 7; update bottom note |

Recommended task order is by dependency: Task 1 (no deps) → Task 2 (no deps) → Task 3 (creates `verify.sh`) → Task 4 (consumes `verify.sh`).

---

## Task 1: SessionStart-on-compact regression test

**Files:**
- Create: `tests/test-session-load-compact.sh`
- Modify: `hooks/hooks.json` (add `_comment` key)

This is a *characterization test* — it locks in existing behavior of `scripts/session-load.sh` so future contributors don't propose a redundant PreCompact reload. The test should pass on first run; if it fails, `session-load.sh` has a real bug that must be fixed before this commit.

- [ ] **Step 1: Write the test**

Create `tests/test-session-load-compact.sh`:

```bash
#!/bin/bash
# Tests for scripts/session-load.sh — verifies hot-tier re-emit on
# SessionStart "compact" source-event. Locks in existing behavior so the
# redundant-PreCompact-reload pattern from ruvnet/ruflo stays rejected.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
mkdir -p "$HOME/.second-brain/projects/test-slug"

printf '%s\n' "SENTINEL_USER_LINE_42" > "$HOME/.second-brain/USER.md"
printf '%s\n' "SENTINEL_PROJECT_LINE_99" > "$HOME/.second-brain/projects/test-slug/PROJECT.md"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# session-load.sh derives slug from `git rev-parse --show-toplevel || pwd`.
# Run from a non-git directory whose basename matches the seeded slug.
mkdir -p "$TMP/test-slug"
cd "$TMP/test-slug" || fail "cd to test-slug failed"

PAYLOAD='{"source":"compact","session_id":"abc123","transcript_path":"/dev/null"}'
OUTPUT=$(printf '%s' "$PAYLOAD" | "$SCRIPT" 2>&1) || fail "session-load.sh exited non-zero on compact payload"

echo "$OUTPUT" | grep -q "SENTINEL_USER_LINE_42" || fail "USER.md sentinel not in output"
pass "USER.md re-emitted on compact"

echo "$OUTPUT" | grep -q "SENTINEL_PROJECT_LINE_99" || fail "PROJECT.md sentinel not in output"
pass "PROJECT.md re-emitted on compact"

[ -f "$HOME/.second-brain/.session-baseline-test-slug.md" ] || fail "baseline not captured"
pass "baseline captured for Stop predicate"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test-session-load-compact.sh`

Expected output:
```
PASS: USER.md re-emitted on compact
PASS: PROJECT.md re-emitted on compact
PASS: baseline captured for Stop predicate
ALL PASS
```

If any assertion fails, do NOT proceed. Investigate `scripts/session-load.sh` (specifically slug derivation on line 11 and the baseline-capture on line 14) before continuing.

- [ ] **Step 3: Add documenting `_comment` to hooks/hooks.json**

JSON does not support comments natively, but Claude Code's hook loader inspects only known keys (`matcher`, `hooks`, `command`). Add a `_comment` sibling to `matcher`.

In `hooks/hooks.json`, replace:

```json
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
```

With:

```json
    "SessionStart": [
      {
        "_comment": "matcher includes 'compact' so session-load.sh re-emits hot tier after compaction; PreCompact reload is therefore unnecessary — see tests/test-session-load-compact.sh",
        "matcher": "startup|resume|clear|compact",
```

- [ ] **Step 4: Run validate-plugin.sh to ensure hooks.json still parses**

Run: `bash scripts/validate-plugin.sh`

Expected: exits 0 with `OK: all plugin files valid`. The `_comment` key is ignored by Claude Code's hook runtime and by `validate-plugin.sh` (which checks only `matcher`, `hooks`, `command`).

- [ ] **Step 5: Commit**

```bash
git add tests/test-session-load-compact.sh hooks/hooks.json
git commit -m "test: lock in sessionstart-compact hot-tier re-emit"
```

---

## Task 2: validate-plugin.sh requires `allowed-tools`

**Files:**
- Create: `tests/test-validate-plugin-allowed-tools.sh`
- Modify: `scripts/validate-plugin.sh` line 92

- [ ] **Step 1: Write the failing test**

Create `tests/test-validate-plugin-allowed-tools.sh`:

```bash
#!/bin/bash
# Tests that validate-plugin.sh fails when a SKILL.md is missing
# 'allowed-tools' in its YAML frontmatter.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-plugin.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Mirror the repo into TMP. Use cp -r; symlinks would let the script find the
# real skills/ tree and miss our mutation.
cp -r "$REPO_ROOT"/. "$TMP/" || fail "repo mirror failed"
export CLAUDE_PLUGIN_ROOT="$TMP"

# Sanity: validator passes on an unmutated mirror
"$SCRIPT" >/dev/null || fail "validator failed on unmutated mirror"
pass "baseline mirror validates"

# Mutation: drop the allowed-tools line from one skill's frontmatter
TARGET="$TMP/skills/setup/SKILL.md"
[ -f "$TARGET" ] || fail "target skill missing in mirror: $TARGET"
grep -q '^allowed-tools:' "$TARGET" || fail "target skill has no allowed-tools to drop"
sed -i.bak '/^allowed-tools:/d' "$TARGET" && rm -f "$TARGET.bak"

# Validator must now fail
OUTPUT=$("$SCRIPT" 2>&1) && fail "validator should have failed but exited 0"
echo "$OUTPUT" | grep -q "setup/SKILL.md missing 'allowed-tools'" || {
  echo "--- validator output ---"
  echo "$OUTPUT"
  fail "expected error message not found"
}
pass "validator rejects skill missing allowed-tools"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-validate-plugin-allowed-tools.sh`

Expected: a `FAIL: validator should have failed but exited 0` (the validator currently checks only `name` and `description`, so it accepts the mutated skill).

- [ ] **Step 3: Modify validate-plugin.sh line 92**

In `scripts/validate-plugin.sh`, change:

```bash
    for field in name description; do
```

To:

```bash
    for field in name description allowed-tools; do
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-validate-plugin-allowed-tools.sh`

Expected output:
```
PASS: baseline mirror validates
PASS: validator rejects skill missing allowed-tools
ALL PASS
```

- [ ] **Step 5: Run validator on real repo to confirm no regression**

Run: `bash scripts/validate-plugin.sh`

Expected: `OK: all plugin files valid`. All 8 SKILL.md files already declare `allowed-tools:` (audited 2026-05-02), so adding the rule should not flag any of them.

- [ ] **Step 6: Commit**

```bash
git add tests/test-validate-plugin-allowed-tools.sh scripts/validate-plugin.sh
git commit -m "validator: require allowed-tools in skill frontmatter"
```

---

## Task 3: scripts/verify.sh runtime smoke check

**Files:**
- Create: `tests/test-verify.sh`
- Create: `scripts/verify.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-verify.sh`:

```bash
#!/bin/bash
# Tests for scripts/verify.sh — runtime smoke check.
# Each subtest seeds a sandboxed $HOME, exercises one failure mode (or the
# clean path), and asserts verify.sh exit code + key output substring.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/verify.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Reset a fresh sandboxed home + cwd for one subtest.
reset_home() {
  local name="$1"
  HOME_DIR="$TMP/$name"
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/.second-brain/projects/test-slug"
  export HOME="$HOME_DIR"
  mkdir -p "$TMP/$name-cwd/test-slug"
  cd "$TMP/$name-cwd/test-slug" || fail "cd failed in $name"
}

seed_clean() {
  printf 'durable preferences\n' > "$HOME/.second-brain/USER.md"
  printf 'project facts\n' > "$HOME/.second-brain/projects/test-slug/PROJECT.md"
}

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

# --- Subtest 1: clean state → exit 0, prints "verify: ok"
reset_home "clean"
seed_clean
OUT=$("$SCRIPT" 2>&1) || fail "clean state should exit 0 (got: $OUT)"
echo "$OUT" | grep -q "verify: ok" || fail "clean state should print 'verify: ok' (got: $OUT)"
pass "clean state: ok"

# --- Subtest 2: USER.md missing → exit non-zero, names the file
reset_home "no-user"
seed_clean
rm "$HOME/.second-brain/USER.md"
OUT=$("$SCRIPT" 2>&1) && fail "missing USER.md should fail"
echo "$OUT" | grep -q "USER.md" || fail "expected 'USER.md' in output (got: $OUT)"
pass "USER.md missing: fails"

# --- Subtest 3: USER.md empty → exit non-zero
reset_home "empty-user"
seed_clean
: > "$HOME/.second-brain/USER.md"
OUT=$("$SCRIPT" 2>&1) && fail "empty USER.md should fail"
echo "$OUT" | grep -q "USER.md" || fail "expected 'USER.md' in output (got: $OUT)"
pass "USER.md empty: fails"

# --- Subtest 4: hot tier exceeds line cap (66) → exit non-zero
reset_home "oversize"
seed_clean
yes "padding line" | head -100 > "$HOME/.second-brain/USER.md"
OUT=$("$SCRIPT" 2>&1) && fail "oversize hot tier should fail"
echo "$OUT" | grep -q "line cap\|hot tier" || fail "expected line-cap message (got: $OUT)"
pass "hot tier oversize: fails"

# --- Subtest 5: MCP dist missing → exit non-zero
reset_home "no-dist"
seed_clean
FAKE_ROOT="$TMP/no-dist-fake-root"
mkdir -p "$FAKE_ROOT/mcp"
OUT=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" "$SCRIPT" 2>&1) && fail "missing dist should fail"
echo "$OUT" | grep -q "dist/server.js\|mcp" || fail "expected MCP message (got: $OUT)"
pass "mcp dist missing: fails"

# --- Subtest 6: error-log has new entry since last verify → exit non-zero
reset_home "stale-errorlog"
seed_clean
echo "2020-01-01T00:00:00Z" > "$HOME/.second-brain/.last-verify"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"timestamp":"%s","script":"x","message":"y","exit_code":1}\n' "$NOW" > "$HOME/.second-brain/error-log.jsonl"
OUT=$("$SCRIPT" 2>&1) && fail "new error-log entry should fail"
echo "$OUT" | grep -q "error-log\|error log" || fail "expected error-log message (got: $OUT)"
pass "error-log fresh entry: fails"

# --- Subtest 7: error-log entry older than last-verify → no fail from this check
reset_home "old-errorlog"
seed_clean
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$NOW" > "$HOME/.second-brain/.last-verify"
printf '{"timestamp":"2020-01-01T00:00:00Z","script":"x","message":"y","exit_code":1}\n' > "$HOME/.second-brain/error-log.jsonl"
OUT=$("$SCRIPT" 2>&1) || fail "old error-log entry should not fail (got: $OUT)"
echo "$OUT" | grep -q "verify: ok" || fail "expected ok despite old error (got: $OUT)"
pass "error-log only old entries: ok"

# --- Subtest 8: first run with existing error-log writes timestamp without flagging
reset_home "first-run"
seed_clean
printf '{"timestamp":"2020-01-01T00:00:00Z","script":"x","message":"y","exit_code":1}\n' > "$HOME/.second-brain/error-log.jsonl"
OUT=$("$SCRIPT" 2>&1) || fail "first run should pass (got: $OUT)"
[ -f "$HOME/.second-brain/.last-verify" ] || fail ".last-verify should be written on first run"
pass "first run with existing error-log: ok and writes timestamp"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-verify.sh`

Expected: bash reports `No such file or directory` or the first subtest fails because `scripts/verify.sh` does not yet exist.

- [ ] **Step 3: Write scripts/verify.sh**

Create `scripts/verify.sh`:

```bash
#!/bin/bash
# Runtime smoke check for second-brain. Complements the static
# scripts/validate-plugin.sh with live-state assertions.
# Exit 0 = all checks pass, exit 1 = at least one check failed.
# Output: 'verify: ok' on success, 'verify: FAIL: <check> — <detail>' lines on failure.
#
# First-run note: if .last-verify does not exist, the error-log freshness
# check is skipped and a fresh timestamp is written on success. Subsequent
# runs flag only entries newer than the recorded timestamp.
set -u
source "$(dirname "$0")/lib.sh"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LINE_CAP=66
FAILS=()

SLUG=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")

# Check 1: USER.md exists and non-empty
USER_FILE="$BRAIN_DIR/USER.md"
if [ ! -f "$USER_FILE" ]; then
  FAILS+=("verify: FAIL: USER.md — file missing at $USER_FILE")
elif [ ! -s "$USER_FILE" ]; then
  FAILS+=("verify: FAIL: USER.md — file empty at $USER_FILE")
fi

# Check 2: active project's PROJECT.md exists
PROJECT_FILE="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
if [ ! -f "$PROJECT_FILE" ]; then
  FAILS+=("verify: FAIL: PROJECT.md — missing for active slug '$SLUG' at $PROJECT_FILE")
fi

# Check 3: hot tier under line cap
U_LINES=0
P_LINES=0
[ -f "$USER_FILE" ] && U_LINES=$(wc -l < "$USER_FILE" | tr -d ' ')
[ -f "$PROJECT_FILE" ] && P_LINES=$(wc -l < "$PROJECT_FILE" | tr -d ' ')
TOTAL=$((U_LINES + P_LINES))
if [ "$TOTAL" -gt "$LINE_CAP" ]; then
  FAILS+=("verify: FAIL: hot tier — line count $TOTAL exceeds line cap $LINE_CAP")
fi

# Check 4: MCP dist artifact exists
MCP_DIST="$PLUGIN_ROOT/mcp/dist/server.js"
if [ ! -f "$MCP_DIST" ]; then
  FAILS+=("verify: FAIL: mcp — dist/server.js missing at $MCP_DIST (run /second-brain:setup)")
fi

# Check 5: error-log freshness vs .last-verify
ERR_LOG="$BRAIN_DIR/error-log.jsonl"
LAST_VERIFY="$BRAIN_DIR/.last-verify"
if [ -f "$ERR_LOG" ] && [ -f "$LAST_VERIFY" ]; then
  LAST_TS=$(head -1 "$LAST_VERIFY" | tr -d '[:space:]')
  if [ -n "$LAST_TS" ]; then
    if ! sb_require_jq; then
      FAILS+=("verify: FAIL: error-log — jq required for freshness check")
    else
      NEW_COUNT=$(jq -r --arg t "$LAST_TS" 'select(.timestamp > $t) | .timestamp' "$ERR_LOG" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$NEW_COUNT" -gt 0 ]; then
        FAILS+=("verify: FAIL: error-log — $NEW_COUNT new entries since $LAST_TS")
      fi
    fi
  fi
fi

# Emit results and update .last-verify timestamp on success
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "verify: ok"
  mkdir -p "$BRAIN_DIR"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_VERIFY"
  exit 0
else
  for line in "${FAILS[@]}"; do
    echo "$line"
  done
  exit 1
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-verify.sh`

Expected output:
```
PASS: clean state: ok
PASS: USER.md missing: fails
PASS: USER.md empty: fails
PASS: hot tier oversize: fails
PASS: mcp dist missing: fails
PASS: error-log fresh entry: fails
PASS: error-log only old entries: ok
PASS: first run with existing error-log: ok and writes timestamp
ALL PASS
```

If subtest 1 (clean state) fails because `mcp/dist/server.js` doesn't exist in this checkout, run `cd mcp && npm install && npm run build` first, then re-run the test.

- [ ] **Step 5: Run validate-plugin.sh to confirm new script has valid syntax**

Run: `bash scripts/validate-plugin.sh`

Expected: `OK: all plugin files valid`. The validator runs `bash -n` on every `*.sh` under `scripts/`.

- [ ] **Step 6: Commit**

```bash
git add tests/test-verify.sh scripts/verify.sh
git commit -m "verify: add runtime smoke check"
```

---

## Task 4: Wire verify.sh into /second-brain:status

**Files:**
- Modify: `skills/status/SKILL.md`

The status skill currently has 6 numbered steps. Insert verify.sh as a new Step 6, renumber existing Step 6 ("Present the dashboard") to Step 7. Update the bottom note about `error-log.jsonl` since verify.sh now surfaces (a derivative of) it.

- [ ] **Step 1: Insert new Step 6 in skills/status/SKILL.md**

Find the section starting:

```markdown
### 6. Present the dashboard
```

Replace with:

````markdown
### 6. Runtime smoke check

Run `verify.sh` to surface live-state issues that the static validator can't see (missing files, oversized hot tier, stale errors). Print its output verbatim — verify owns its own format.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh"
```

The script exits 0 with `verify: ok` when everything is healthy, or exits non-zero with one `verify: FAIL:` line per failed check. Do not auto-remediate — point the user at the relevant skill (`/second-brain:setup` for missing files, `/second-brain:improve` for oversized hot tier) and let them act.

### 7. Present the dashboard
````

- [ ] **Step 2: Update the bottom note about error-log surfacing**

Find the closing paragraph:

```markdown
Keep the output terse. No reflection-pipeline metrics — `learnings.md`, `friction-log.jsonl`, `quality-rules.md`, `persona.md`, `tool-registry.json`, and `error-log.jsonl` either no longer exist or are no longer surfaced here. If the user wants deep reflection on the current session, point them at `/second-brain:improve`.
```

Replace with:

```markdown
Keep the output terse. No reflection-pipeline metrics — `learnings.md`, `friction-log.jsonl`, `quality-rules.md`, `persona.md`, and `tool-registry.json` no longer exist. `error-log.jsonl` is not dumped here, but `verify.sh` (Step 6) flags new entries since the last successful verify. If the user wants deep reflection on the current session, point them at `/second-brain:improve`.
```

- [ ] **Step 3: Append `Bash(bash *)` to allowed-tools on line 6**

The skill currently lists:

```
allowed-tools: Read Bash(git rev-parse:*) Bash(basename *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(test *) Bash(jq *) Bash(date *) Bash(find *) Bash(grep *) mcp__knowledge-base__knowledge_stats
```

Replace with:

```
allowed-tools: Read Bash(git rev-parse:*) Bash(basename *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(test *) Bash(jq *) Bash(date *) Bash(find *) Bash(grep *) Bash(bash *) mcp__knowledge-base__knowledge_stats
```

- [ ] **Step 4: Run validate-plugin.sh to confirm frontmatter still valid**

Run: `bash scripts/validate-plugin.sh`

Expected: `OK: all plugin files valid`.

- [ ] **Step 5: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "status: surface verify.sh runtime smoke check"
```

---

## Final verification

- [ ] **Step 1: Run all new tests**

```bash
bash tests/test-session-load-compact.sh
bash tests/test-validate-plugin-allowed-tools.sh
bash tests/test-verify.sh
```

Each must end with `ALL PASS`.

- [ ] **Step 2: Run existing test suite to confirm no regression**

```bash
bash tests/test-validate-plugin.sh
bash tests/test-stop-hook-predicate.sh
bash tests/test-hooks-regression.sh
```

Each must pass (whatever its existing pass criterion is).

- [ ] **Step 3: Run full validator on repo**

```bash
bash scripts/validate-plugin.sh
```

Expected: `OK: all plugin files valid`.

- [ ] **Step 4: Smoke-test `/second-brain:status` mentally**

Re-read `skills/status/SKILL.md` end-to-end. Confirm Step 6 references `verify.sh`, Step 7 is the dashboard, the bottom note acknowledges verify.sh's role with error-log.

---

## Self-review notes

- Each task ships one or more regression tests. Every spec section maps to a task: §Item 1 → Task 1, §Item 2 → Task 2, §Item 3 → Tasks 3+4, §Item 4 → tests within Tasks 2 and 3.
- No placeholders. Every step shows the actual command or the actual code.
- Type/name consistency: `verify.sh`, `verify: ok`, `verify: FAIL:`, `LINE_CAP=66`, `.last-verify`, `BRAIN_DIR` — all consistent across tasks and matching the spec.
- Commits use imperative lowercase no-period subjects, no AI attribution. Matches user preferences.
- `_comment` key in hooks.json is the standard JSON workaround; `validate-plugin.sh` only inspects known keys (`matcher`, `hooks`, `command`).
