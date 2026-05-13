#!/bin/bash
# Tests for scripts/extraction-quality-gate.sh — Layer 4 Quality Gate.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/extraction-quality-gate.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Use isolated brainDir so we don't pollute real logs.
BD=$(mktemp -d)
export BRAIN_DIR="$BD"
trap 'rm -rf "$BD"' EXIT

# Test 1: noise gets filtered, signal kept
out=$(echo '{"recent_decisions":["files this session: foo.ts, bar.ts","decided to use BM25+ONNX hybrid for wiki search"],"open_blockers":[],"cross_refs":[]}' | "$SCRIPT")
echo "$out" | jq -e '(.recent_decisions | length) == 1' >/dev/null \
  || fail "noise+signal: should keep 1 of 2 (got: $out)"
echo "$out" | jq -e '.recent_decisions[0] | contains("BM25")' >/dev/null \
  || fail "noise+signal: signal entry not preserved (got: $out)"
pass "filter noise, preserve signal"

# Test 2: kill switch
out=$(SB_QUALITY_GATE=off bash -c 'echo "{\"recent_decisions\":[\"files this session: x\"]}" | "'"$SCRIPT"'"')
echo "$out" | jq -e '(.recent_decisions | length) == 1' >/dev/null \
  || fail "kill switch: SB_QUALITY_GATE=off should passthrough (got: $out)"
pass "kill switch honored"

# Test 3: all-noise input → empty arrays
out=$(echo '{"recent_decisions":["files this session: a","good code"],"open_blockers":["it"],"cross_refs":[]}' | "$SCRIPT")
echo "$out" | jq -e '((.recent_decisions | length) == 0) and ((.open_blockers | length) == 0)' >/dev/null \
  || fail "all-noise: arrays should be empty (got: $out)"
pass "all-noise produces empty arrays"

# Test 4: rejection log written
test -s "$BD/.rejected-extractions.jsonl" || fail "rejection log should have entries"
tail -1 "$BD/.rejected-extractions.jsonl" | jq -e '.reason and .entry and .at' >/dev/null \
  || fail "log entries should be structured JSON"
pass "rejection log structured"

# Test 5: empty input → silent
out=$(echo "" | "$SCRIPT")
[ -z "$out" ] || fail "empty stdin should produce no output (got: $out)"
pass "empty stdin silent"

# Test 6: aggressive strictness rejects vague entries
out=$(SB_QUALITY_GATE_STRICTNESS=aggressive bash -c 'echo "{\"recent_decisions\":[\"we should fix it\"]}" | "'"$SCRIPT"'"')
echo "$out" | jq -e '(.recent_decisions | length) == 0' >/dev/null \
  || fail "aggressive: vague pronouns should be rejected (got: $out)"
pass "aggressive rejects pronoun-only entries"

echo
echo "ALL PASS"
