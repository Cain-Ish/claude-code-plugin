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

# --- Subtest 9: malformed JSONL in error-log → exit non-zero, distinct message
reset_home "malformed-errorlog"
seed_clean
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$NOW" > "$HOME/.second-brain/.last-verify"
printf 'this is not json\n{"timestamp":"%s","script":"x","message":"y","exit_code":1}\n' "$NOW" > "$HOME/.second-brain/error-log.jsonl"
OUT=$("$SCRIPT" 2>&1) && fail "malformed error-log should fail"
echo "$OUT" | grep -q "malformed JSON" || fail "expected 'malformed JSON' message (got: $OUT)"
pass "error-log malformed: fails distinctly"

echo "ALL PASS"
