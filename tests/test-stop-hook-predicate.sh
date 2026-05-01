#!/bin/bash
# Tests for scripts/stop-hook-predicate.sh
# Predicate exit codes: 0 = predicate fired (write allowed), 1 = no-op (no write)
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/stop-hook-predicate.sh"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

make_pair() {
  local baseline_content="$1" current_content="$2"
  # Use %b so \n in the fixture string becomes a real newline (0x0A);
  # the predicate's awk parser is line-anchored and requires real LFs.
  printf '%b' "$baseline_content" > "$TMP/baseline.md"
  printf '%b' "$current_content" > "$TMP/current.md"
}
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1: identical files → no-op (exit 1)
make_pair "## Goal\nx" "## Goal\nx"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" && fail "identical files should not fire"
pass "identical files: no-op"

# Test 2: Goal text differs → fires (exit 0)
make_pair "## Goal\nold" "## Goal\nnew"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "goal-diff should fire"
pass "goal differs: fires"

# Test 3: State word-count delta >20% → fires
make_pair "## State\none two three four five" "## State\none two three four five six seven eight"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "state delta should fire"
pass "state +60% words: fires"

# Test 4: State word-count delta <20% → no-op
make_pair "## State\nten words here total exactly ten words here total" "## State\nten words here total exactly ten words here today"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" && fail "state minor change should not fire"
pass "state minor change: no-op"

# Test 5: Open blockers line count differs → fires
make_pair "## Open blockers\n- [active] one" "## Open blockers\n- [active] one\n- [active] two"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "new blocker should fire"
pass "new open blocker: fires"

# Test 6: [decision] marker added → fires
make_pair "## Recent decisions\n- nothing" "## Recent decisions\n- nothing\n- [decision] picked X over Y"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "[decision] marker should fire"
pass "[decision] marker added: fires"

echo "ALL PASS"
