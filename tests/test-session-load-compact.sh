#!/bin/bash
# Tests for scripts/session-load.sh — verifies that the SessionStart hook
# is NOT registered for the "compact" source-event. Per upstream
# anthropics/claude-code#15174, SessionStart hook output is silently dropped
# after compaction (v2.0.72+), so running session-load.sh on compact was pure
# waste — and on long sessions it compounded the post-compact context-bloat
# loop. This test locks in the matcher change in hooks/hooks.json.
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SCRIPT="$PLUGIN_ROOT/scripts/session-load.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1: hooks.json SessionStart matcher must not include "compact".
SS_MATCHER=$(jq -r '.hooks.SessionStart[0].matcher' "$HOOKS_JSON" 2>/dev/null)
[ -n "$SS_MATCHER" ] || fail "could not read SessionStart matcher from $HOOKS_JSON"
echo "$SS_MATCHER" | grep -q compact \
  && fail "SessionStart matcher still contains 'compact' (got: $SS_MATCHER) — per upstream #15174 this is wasted work"
pass "SessionStart matcher excludes 'compact'"

# Test 2: matcher still covers the real session-start events we depend on.
for ev in startup resume clear; do
  echo "$SS_MATCHER" | grep -qE "(^|\|)$ev(\||$)" \
    || fail "matcher dropped '$ev' too (got: $SS_MATCHER)"
done
pass "SessionStart matcher still covers startup|resume|clear"

# Test 3: session-load.sh itself still functions on every source value the
# old matcher used to handle, including 'compact'. Defense-in-depth: even
# if Claude Code accidentally fires SessionStart with source=compact in a
# future version, the script must not crash and must still emit hot-tier.
export HOME="$TMP"
mkdir -p "$HOME/.second-brain/projects/test-slug"
printf '%s\n' "SENTINEL_USER" > "$HOME/.second-brain/USER.md"
printf '%s\n' "SENTINEL_PROJECT" > "$HOME/.second-brain/projects/test-slug/PROJECT.md"
mkdir -p "$TMP/test-slug"
cd "$TMP/test-slug" || fail "cd to test-slug failed"

for SRC in startup resume clear compact; do
  PAYLOAD=$(jq -nc --arg s "$SRC" '{source:$s, session_id:"abc", transcript_path:"/dev/null"}')
  OUT=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>&1) \
    || fail "session-load.sh exited non-zero on source=$SRC"
  echo "$OUT" | grep -q SENTINEL_USER \
    || fail "session-load.sh produced no hot-tier output for source=$SRC"
done
pass "session-load.sh still produces hot-tier output across source variants (defensive)"

echo
echo "ALL PASS"
