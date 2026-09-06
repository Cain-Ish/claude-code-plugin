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
  printf 'durable preferences\n\n## Intent\nrun query first.\n' > "$HOME/.second-brain/USER.md"
  printf 'project facts\n' > "$HOME/.second-brain/projects/test-slug/PROJECT.md"
  # verify.sh resolves the wiki under $HOME/knowledge (or
  # CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR), not $HOME/.second-brain. The earlier
  # mkdir under .second-brain was a leftover from the pre-1.0 layout.
  mkdir -p "$HOME/knowledge/wiki"
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

# --- Subtest 4 (D188): USER.md over its 6000B byte cap → exit non-zero.
# The cap is BYTE-based now, aligned with session-load.sh's own USER.md force-emit
# cap (over which content is silently head-c'd, losing real pinned preferences) —
# not line-based, so the fixture must actually exceed 6000 bytes, not just 66 lines.
reset_home "oversize"
seed_clean
yes "padding line with enough characters per line to cross the byte cap, not just a line count" | head -100 > "$HOME/.second-brain/USER.md"
[ "$(wc -c < "$HOME/.second-brain/USER.md" | tr -d ' ')" -gt 6000 ] || fail "fixture setup: USER.md not actually over 6000B"
OUT=$("$SCRIPT" 2>&1) && fail "oversize hot tier should fail"
echo "$OUT" | grep -q "byte cap\|hot tier" || fail "expected byte-cap message (got: $OUT)"
pass "hot tier oversize (USER.md byte cap): fails"

# --- Subtest 4b (D188): PROJECT.md over its 3000B render cap is NOT a hard failure —
# session-load.sh's section-priority render (D162) handles this gracefully with its
# own breadcrumb, so a large-but-healthy PROJECT.md must not permanently fail verify
# (the exact "worsening FAIL since 2026-05-04" bug this ledger item fixes).
reset_home "big-project-md"
seed_clean
yes "recorded decision line with enough bytes to accumulate past the render cap" | head -100 > "$HOME/.second-brain/projects/test-slug/PROJECT.md"
[ "$(wc -c < "$HOME/.second-brain/projects/test-slug/PROJECT.md" | tr -d ' ')" -gt 3000 ] || fail "fixture setup: PROJECT.md not actually over 3000B"
OUT=$("$SCRIPT" 2>&1) || fail "a large PROJECT.md alone must not fail verify (got: $OUT)"
echo "$OUT" | grep -q "verify: ok" || fail "expected verify: ok despite a large PROJECT.md (got: $OUT)"
pass "large PROJECT.md (over render cap) alone: still ok (D162 handles it, not a verify failure)"

# --- Subtest 5: MCP dist missing → exit non-zero
reset_home "no-dist"
seed_clean
FAKE_ROOT="$TMP/no-dist-fake-root"
mkdir -p "$FAKE_ROOT/mcp"
OUT=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" "$SCRIPT" 2>&1) && fail "missing dist should fail"
echo "$OUT" | grep -q "dist/server.bundle.js\|mcp" || fail "expected MCP message (got: $OUT)"
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

# --- Subtest 7b (D188): a FRESH exit_code:0 trace row (e.g. a legitimate informational
# line that isn't `gate=`-prefixed) must NOT count toward "new entries" — only a real
# failure (exit_code != 0) should. Before D188 this check counted ec=0 trace rows too,
# which is exactly what made a healthy install (session-load.sh writes several such
# rows every session) fail this check permanently.
reset_home "fresh-trace-only"
seed_clean
echo "2020-01-01T00:00:00Z" > "$HOME/.second-brain/.last-verify"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"timestamp":"%s","script":"session-load.sh","message":"some-trace-line","exit_code":0}\n' "$NOW" > "$HOME/.second-brain/error-log.jsonl"
OUT=$("$SCRIPT" 2>&1) || fail "a fresh exit_code:0 trace row alone should not fail verify (got: $OUT)"
echo "$OUT" | grep -q "verify: ok" || fail "expected ok despite a fresh ec=0 trace row (got: $OUT)"
pass "error-log: fresh exit_code:0 trace row is ignored, only real failures count"

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

# --- Subtest 9b: empty error-log file → ok (truncating to clear is a normal pattern)
# Pre-fix bug: `jq -e '.'` on an empty file exits non-zero, so the pre-validator
# treated `: > error-log.jsonl` as "malformed JSON". After fix, the pre-validator
# is gated on `[ -s "$ERR_LOG" ]` (exists AND non-zero size) so the empty case
# passes cleanly. Real users hit this when running `/second-brain:status` after
# clearing an old error log.
reset_home "empty-errorlog"
seed_clean
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$NOW" > "$HOME/.second-brain/.last-verify"
: > "$HOME/.second-brain/error-log.jsonl"   # truncate to empty
OUT=$("$SCRIPT" 2>&1) || fail "empty error-log should NOT fail (got: $OUT)"
echo "$OUT" | grep -q "malformed" && fail "empty error-log must NOT be flagged as malformed (got: $OUT)"
echo "$OUT" | grep -q "verify: ok" || fail "expected 'verify: ok' for empty error-log (got: $OUT)"
pass "error-log empty: ok (not malformed)"

# --- Subtest 10: USER.md present but missing ## Intent section → exit non-zero
reset_home "no-intent"
seed_clean
printf 'durable preferences without intent section\n' > "$HOME/.second-brain/USER.md"
OUT=$("$SCRIPT" 2>&1) && fail "USER.md without ## Intent should fail"
echo "$OUT" | grep -q "## Intent" || fail "expected '## Intent' message (got: $OUT)"
pass "USER.md missing ## Intent: fails"

# --- Subtest 11: wiki dir missing → exit non-zero
reset_home "no-wiki"
seed_clean
rm -rf "$HOME/knowledge/wiki"
OUT=$("$SCRIPT" 2>&1) && fail "missing wiki dir should fail"
echo "$OUT" | grep -q "wiki" || fail "expected 'wiki' in output (got: $OUT)"
pass "wiki dir missing: fails"

echo "ALL PASS"
