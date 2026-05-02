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
