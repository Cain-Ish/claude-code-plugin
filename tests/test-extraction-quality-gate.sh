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
out=$(echo '{"recent_decisions":["files this session: foo.ts, bar.ts","decided to use BM25+ONNX hybrid for wiki search"],"open_blockers":[],"cross_refs":[]}' | bash "$SCRIPT")
echo "$out" | jq -e '(.recent_decisions | length) == 1' >/dev/null \
  || fail "noise+signal: should keep 1 of 2 (got: $out)"
echo "$out" | jq -e '.recent_decisions[0] | contains("BM25")' >/dev/null \
  || fail "noise+signal: signal entry not preserved (got: $out)"
pass "filter noise, preserve signal"

# Test 2: kill switch
out=$(SB_QUALITY_GATE=off bash -c 'echo "{\"recent_decisions\":[\"files this session: x\"]}" | bash "'"$SCRIPT"'"')
echo "$out" | jq -e '(.recent_decisions | length) == 1' >/dev/null \
  || fail "kill switch: SB_QUALITY_GATE=off should passthrough (got: $out)"
pass "kill switch honored"

# Test 3: all-noise input → empty arrays
out=$(echo '{"recent_decisions":["files this session: a","good code"],"open_blockers":["it"],"cross_refs":[]}' | bash "$SCRIPT")
echo "$out" | jq -e '((.recent_decisions | length) == 0) and ((.open_blockers | length) == 0)' >/dev/null \
  || fail "all-noise: arrays should be empty (got: $out)"
pass "all-noise produces empty arrays"

# Test 4: rejection log written
test -s "$BD/.rejected-extractions.jsonl" || fail "rejection log should have entries"
tail -1 "$BD/.rejected-extractions.jsonl" | jq -e '.reason and .entry and .at' >/dev/null \
  || fail "log entries should be structured JSON"
pass "rejection log structured"

# Test 5: empty input → silent
out=$(echo "" | bash "$SCRIPT")
[ -z "$out" ] || fail "empty stdin should produce no output (got: $out)"
pass "empty stdin silent"

# Test 6: aggressive strictness rejects vague entries
out=$(SB_QUALITY_GATE_STRICTNESS=aggressive bash -c 'echo "{\"recent_decisions\":[\"we should fix it\"]}" | bash "'"$SCRIPT"'"')
echo "$out" | jq -e '(.recent_decisions | length) == 0' >/dev/null \
  || fail "aggressive: vague pronouns should be rejected (got: $out)"
pass "aggressive rejects pronoun-only entries"

# Test 7: cross_refs are SLUGS, not sentences — the sentence word-count rule
# must NOT be applied. Regression test for the bug that caused Test 1 of
# test-stop-extract.sh to fail (`[[new-page]]` never reached PROJECT.md
# because "new-page" is 1 word, below the < 3 threshold for sentence noise).
# Single-char slugs ("a") still reject — wiki minimum is 2 chars.
out=$(echo '{"cross_refs":["new-page","router-daemon","a","valid-slug-here"]}' | bash "$SCRIPT")
echo "$out" | jq -e '(.cross_refs | length) == 3' >/dev/null \
  || fail "cross_refs: should keep 3 of 4 (drop single-char 'a'), got: $out"
echo "$out" | jq -e '.cross_refs | any(. == "new-page")' >/dev/null \
  || fail "cross_refs: single-word slug 'new-page' dropped, got: $out"
echo "$out" | jq -e '.cross_refs | any(. == "a") | not' >/dev/null \
  || fail "cross_refs: single-char 'a' should be rejected (too short), got: $out"
pass "cross_refs: short slugs pass through (sentence rules NOT applied)"

# Test 8: cross_refs reject malformed slugs (spaces, uppercase, leading/
# trailing dashes). Use exact-equality compare — jq `contains` does
# substring matching on strings inside arrays which gives false positives.
out=$(echo '{"cross_refs":["with space","UPPERCASE","-leading","trailing-","--bad","ok"]}' | bash "$SCRIPT")
echo "$out" | jq -e '.cross_refs == ["ok"]' >/dev/null \
  || fail "cross_refs: malformed slugs should be rejected, only 'ok' kept (got: $out)"
pass "cross_refs: malformed slugs rejected"

# Test 9 (HIGH): the gate filters sentence-shaped noise but PRESERVES the
# durable payload keys it does not own (wiki_updates, relations). A real
# extractor delta carries those alongside recent_decisions — they must flow
# through untouched while the noisy decision is dropped, or the whole
# extractor->gate->merge chain would silently lose every wiki page + edge.
out=$(echo '{"recent_decisions":["files this session: noise.ts"],"wiki_updates":[{"category":"learnings","slug":"keep-me","content":"durable"}],"relations":[{"from":"a","to":"b","type":"requires"}]}' | bash "$SCRIPT")
echo "$out" | jq -e '.wiki_updates[0].slug=="keep-me" and (.relations|length)==1' >/dev/null \
  || fail "preserve-payload: wiki_updates/relations must survive the gate (got: $out)"
echo "$out" | jq -e '.wiki_updates[0].content=="durable"' >/dev/null \
  || fail "preserve-payload: wiki_updates content body altered (got: $out)"
echo "$out" | jq -e '(.recent_decisions|length)==0' >/dev/null \
  || fail "preserve-payload: the 'files this session' noise should still be filtered (got: $out)"
pass "gate preserves wiki_updates + relations while filtering decision noise"

echo
echo "ALL PASS"
