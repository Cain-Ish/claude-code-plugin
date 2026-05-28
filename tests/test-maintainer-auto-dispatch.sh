#!/bin/bash
# Tests for v2.8.0 maintainer auto-dispatch — counter helpers + session-load.sh
# state machine. We never invoke `claude` here; session-load.sh writes
# additionalContext to stdout and we assert on its content + marker files.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
LIB="$REPO_ROOT/scripts/lib.sh"
# shellcheck disable=SC2034  # SCRIPT is used by tests added in later tasks
SCRIPT="$REPO_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

init_sandbox() {
  local name="$1"
  SANDBOX="$TMP/$name"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects/test-slug" \
           "$SANDBOX/repo/test-slug"
  export HOME="$SANDBOX"
  export BRAIN_DIR="$SANDBOX/.second-brain"
  cd "$SANDBOX/repo/test-slug" || fail "cd failed in $name"
  # Minimal PROJECT.md so session-load.sh resolves the slug.
  cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug
## Goal
seeded.
EOF
}

# --- Test 1: counter helpers increment, get, reset round-trip ----------
init_sandbox "helpers"
source "$LIB"
sb_inc_wiki_writes "test-slug"
sb_inc_wiki_writes "test-slug"
sb_inc_wiki_writes "test-slug"
[ "$(sb_get_wiki_writes "test-slug")" = "3" ] || fail "helpers: expected 3, got $(sb_get_wiki_writes "test-slug")"
sb_reset_wiki_writes "test-slug"
[ "$(sb_get_wiki_writes "test-slug")" = "0" ] || fail "helpers: expected 0 after reset"
# Corrupt-file recovery: write garbage, get should return 0
echo "not-a-number" > "$BRAIN_DIR/projects/test-slug/.wiki-writes"
[ "$(sb_get_wiki_writes "test-slug")" = "0" ] || fail "helpers: garbage should parse as 0"
pass "counter helpers increment/get/reset + corruption-safe"

# --- Helper: invoke session-load.sh with a fake SessionStart payload -----
run_session_load() {
  local slug="${1:-test-slug}"
  jq -nc --arg cwd "$SANDBOX/repo/$slug" \
    '{session_id:"x", cwd:$cwd, hook_event_name:"SessionStart"}' \
    | bash "$SCRIPT" 2>/dev/null
}

# --- Test 2: counter below threshold → no banner ------------------------
init_sandbox "below-threshold"
source "$LIB"
sb_set_wiki_writes "test-slug" 2
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
echo "$OUT" | grep -q "wiki maintenance suggested" && fail "below-threshold: should NOT emit banner"
[ ! -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "below-threshold: dispatched marker should not exist"
pass "below threshold (2 < 3): no banner emitted"

# --- Test 3: counter at threshold → user-facing suggestion banner ------
# C3-B: banner no longer creates DISP_FILE (no longer instructs dispatch).
# Reconcile state machine still recognizes DISP_FILE if manually created.
init_sandbox "at-threshold"
source "$LIB"
sb_set_wiki_writes "test-slug" 3
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
echo "$OUT" | grep -q "wiki maintenance suggested" || fail "at-threshold: suggestion banner missing"
echo "$OUT" | grep -q "/second-brain:dream" || fail "at-threshold: explicit-invocation path missing"
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" && fail "at-threshold: legacy BLOCKING wording must not appear"
echo "$OUT" | grep -q "you MUST" && fail "at-threshold: legacy 'you MUST' wording must not appear"
[ ! -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "at-threshold: dispatched marker should NOT be created by suggestion banner (C3-B)"
pass "at threshold (3 >= 3): user-facing suggestion banner; no auto-dispatch marker"

# --- Test 4: SB_MAINTAINER_AUTO=off suppresses banner -------------------
init_sandbox "kill-switch"
source "$LIB"
sb_set_wiki_writes "test-slug" 10
export SB_MAINTAINER_AUTO=off
OUT=$(run_session_load)
unset SB_MAINTAINER_AUTO
echo "$OUT" | grep -q "wiki maintenance suggested" && fail "kill-switch: should not emit banner"
[ ! -f "$SANDBOX/.second-brain/projects/test-slug/.maintainer-dispatched" ] || \
  fail "kill-switch: dispatched marker should not exist"
pass "SB_MAINTAINER_AUTO=off suppresses banner even at counter=10"

# --- Test 5: SB_MAINTAINER_THRESHOLD override --------------------------
init_sandbox "threshold-override"
source "$LIB"
sb_set_wiki_writes "test-slug" 2
export SB_MAINTAINER_THRESHOLD=2
OUT=$(run_session_load)
unset SB_MAINTAINER_THRESHOLD
echo "$OUT" | grep -q "wiki maintenance suggested" || fail "threshold-override: banner missing at count=2 threshold=2"
pass "SB_MAINTAINER_THRESHOLD=2 triggers at counter=2"

# --- Test 6: success path → counter reset, fail-count reset, markers cleared
# Reconcile path still works when DISP_FILE+ACK_FILE present (manually or
# via legacy dispatch instructions an older session emitted).
init_sandbox "success-path"
source "$LIB"
sb_set_wiki_writes "test-slug" 3
sb_inc_maintainer_fails "test-slug"
sb_inc_maintainer_fails "test-slug"
PROJ_DIR="$SANDBOX/.second-brain/projects/test-slug"
touch "$PROJ_DIR/.maintainer-dispatched"
echo ok > "$PROJ_DIR/.maintainer-needed-last"
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
[ "$(sb_get_wiki_writes "test-slug")" = "0" ] || fail "success-path: counter not reset"
[ "$(sb_get_maintainer_fails "test-slug")" = "0" ] || fail "success-path: fail-count not reset"
[ ! -f "$PROJ_DIR/.maintainer-dispatched" ] || fail "success-path: dispatched marker should be removed"
[ ! -f "$PROJ_DIR/.maintainer-needed-last" ] || fail "success-path: ack marker should be removed"
echo "$OUT" | grep -q "wiki maintenance suggested" && fail "success-path: should not emit a new banner after reset"
pass "success path: counter+fail-count reset, both markers cleared, no fresh banner"

# --- Test 7: failure path → counter→N-1, fail-count++, error logged ----
init_sandbox "failure-path"
source "$LIB"
sb_set_wiki_writes "test-slug" 3
PROJ_DIR="$SANDBOX/.second-brain/projects/test-slug"
touch "$PROJ_DIR/.maintainer-dispatched"   # dispatched but no ACK = failure
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
OUT=$(run_session_load)
[ "$(sb_get_wiki_writes "test-slug")" = "2" ] || \
  fail "failure-path: counter should be N-1=2, got $(sb_get_wiki_writes "test-slug")"
[ "$(sb_get_maintainer_fails "test-slug")" = "1" ] || \
  fail "failure-path: fail-count should be 1, got $(sb_get_maintainer_fails "test-slug")"
[ ! -f "$PROJ_DIR/.maintainer-dispatched" ] || fail "failure-path: dispatched marker should be removed"
grep -q "maintainer-auto-dispatch-failed" "$SANDBOX/.second-brain/error-log.jsonl" 2>/dev/null || \
  fail "failure-path: error-log entry missing"
echo "$OUT" | grep -q "maintainer auto-dispatch failed" || \
  fail "failure-path: user-visible fail banner missing from output"
pass "failure path: counter→N-1, fail-count incremented, error logged"

# --- Test 8: 3 consecutive failures → auto-disabled --------------------
init_sandbox "auto-disable"
source "$LIB"
PROJ_DIR="$SANDBOX/.second-brain/projects/test-slug"
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD SB_MAINTAINER_MAX_FAILS
# Simulate 3 failed dispatches in a row
for _i in 1 2 3; do
  sb_set_wiki_writes "test-slug" 3
  touch "$PROJ_DIR/.maintainer-dispatched"
  run_session_load >/dev/null
done
[ -f "$PROJ_DIR/.maintainer-auto-disabled" ] || \
  fail "auto-disable: marker should be created after 3 failures"
# Now even with high counter, dispatch is suppressed
sb_set_wiki_writes "test-slug" 99
OUT=$(run_session_load)
echo "$OUT" | grep -q "BLOCKING REQUIREMENT" && fail "auto-disable: banner should be suppressed when marker present"
pass "3 consecutive failures auto-disable; subsequent runs suppressed"

# --- Test 9: migration converts .maintainer-needed → .wiki-writes -------
init_sandbox "migration"
PROJ_DIR="$SANDBOX/.second-brain/projects/test-slug"
PROJ_DIR2="$SANDBOX/.second-brain/projects/other-slug"
mkdir -p "$PROJ_DIR2"
touch "$PROJ_DIR/.maintainer-needed"
touch "$PROJ_DIR2/.maintainer-needed"
unset SB_MAINTAINER_AUTO SB_MAINTAINER_THRESHOLD
bash "$REPO_ROOT/scripts/migrate-to-2.8.0.sh" >/dev/null 2>&1
[ -f "$PROJ_DIR/.maintainer-needed" ] && fail "migration: old flag should be removed (test-slug)"
[ -f "$PROJ_DIR2/.maintainer-needed" ] && fail "migration: old flag should be removed (other-slug)"
[ "$(cat "$PROJ_DIR/.wiki-writes")" = "3" ] || \
  fail "migration: counter should be set to threshold (3), got $(cat "$PROJ_DIR/.wiki-writes" 2>/dev/null)"
[ "$(cat "$PROJ_DIR2/.wiki-writes")" = "3" ] || \
  fail "migration: counter should be set for other-slug too, got $(cat "$PROJ_DIR2/.wiki-writes" 2>/dev/null)"
# Idempotent re-run is a no-op
bash "$REPO_ROOT/scripts/migrate-to-2.8.0.sh" >/dev/null 2>&1
[ "$(cat "$PROJ_DIR/.wiki-writes")" = "3" ] || fail "migration: re-run should be idempotent"
pass "migration: old .maintainer-needed → .wiki-writes=N, idempotent"

# --- Test 10: migration refuses non-numeric threshold ------------------
init_sandbox "migration-bad-threshold"
PROJ_DIR="$SANDBOX/.second-brain/projects/test-slug"
touch "$PROJ_DIR/.maintainer-needed"
SB_MAINTAINER_THRESHOLD=abc bash "$REPO_ROOT/scripts/migrate-to-2.8.0.sh" 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] || fail "bad-threshold: script should exit non-zero on invalid N"
[ -f "$PROJ_DIR/.maintainer-needed" ] || fail "bad-threshold: legacy flag should remain when migration refuses"
[ ! -f "$PROJ_DIR/.wiki-writes" ] || fail "bad-threshold: counter should NOT exist when migration refuses"
pass "migration refuses non-numeric SB_MAINTAINER_THRESHOLD; legacy flag preserved"

echo "ALL PASS"
