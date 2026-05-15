#!/bin/bash
# Tests for scripts/merge-persona-signals.sh — signal dedup + auto-graduation.
# Goal: prove that the loosened dedup (set-min, 50%) catches paraphrased
# repeats, and that two high-confidence sightings now auto-graduate.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/merge-persona-signals.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export BRAIN_DIR="$TMP/brain"
mkdir -p "$BRAIN_DIR"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Stub sb_pin_to_user so graduation is observable without writing the real USER.md
# (we only want to verify the graduated flag flips). We do this by symlinking
# the lib so the script's `source lib.sh` picks up our override.
mkdir -p "$TMP/stub-scripts"
cat > "$TMP/stub-scripts/lib.sh" <<'EOF'
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
sb_parse_input() { :; }
sb_safe_json_array() { echo "${1:-[]}"; }
sb_log_error() { :; }
sb_pin_to_user() { echo "PIN: $1" >> "$BRAIN_DIR/pin-log"; return 0; }
EOF

# Run the script with our stub lib. We do this by copying merge-persona-signals.sh
# into the stub dir so its `source "$(dirname "$0")/lib.sh"` picks up the stub.
cp "$SCRIPT" "$TMP/stub-scripts/merge-persona-signals.sh"
STUB_SCRIPT="$TMP/stub-scripts/merge-persona-signals.sh"

run_merge() {
  echo "$1" | bash "$STUB_SCRIPT"
}

# Helper: count signals in the JSONL state file
count_signals() { wc -l < "$BRAIN_DIR/persona-signals.jsonl" 2>/dev/null | tr -d ' '; }
get_field() { jq -r --argjson i "$1" --arg f "$2" 'nth($i; inputs) | .[$f]' "$BRAIN_DIR/persona-signals.jsonl" 2>/dev/null; }

# --- Test 1: two paraphrased signals about the same behavior merge into count=2 ---
rm -f "$BRAIN_DIR/persona-signals.jsonl"

S1='[{"category":"workflow","signal":"prefers explicit evaluate-then-integrate workflow plan comparison step required before implementation decisions","evidence":"e1","confidence":"high"}]'
S2='[{"category":"workflow","signal":"user prefers evaluate before integrate workflow comparison step needed implementation","evidence":"e2","confidence":"high"}]'

CLAUDE_SESSION_ID=s1 run_merge "$S1"
CLAUDE_SESSION_ID=s2 run_merge "$S2"

N=$(count_signals)
[ "$N" = "1" ] || fail "paraphrased signals should merge into one (got $N entries)"
pass "paraphrased signals dedupe"

CNT=$(jq -s 'first | .count' "$BRAIN_DIR/persona-signals.jsonl")
[ "$CNT" = "2" ] || fail "merged signal should have count=2 (got $CNT)"
pass "merged count is 2"

# --- Test 2: count=2 + high confidence auto-graduates ---
GRAD=$(jq -s 'first | .graduated' "$BRAIN_DIR/persona-signals.jsonl")
[ "$GRAD" = "true" ] || fail "count=2 high-confidence should auto-graduate (got graduated=$GRAD)"
pass "count=2 high-confidence auto-graduates"

# Verify sb_pin_to_user was called
[ -f "$BRAIN_DIR/pin-log" ] || fail "sb_pin_to_user should have been invoked"
pass "graduation invokes pin_to_user"

# --- Test 3: medium confidence does NOT auto-graduate at count=2 ---
rm -f "$BRAIN_DIR/persona-signals.jsonl" "$BRAIN_DIR/pin-log"

M1='[{"category":"workflow","signal":"another behavior pattern observed sometimes maybe","evidence":"e1","confidence":"medium"}]'
M2='[{"category":"workflow","signal":"another behavior pattern observed sometimes maybe possibly","evidence":"e2","confidence":"medium"}]'

CLAUDE_SESSION_ID=m1 run_merge "$M1"
CLAUDE_SESSION_ID=m2 run_merge "$M2"

CNT=$(jq -s 'first | .count' "$BRAIN_DIR/persona-signals.jsonl")
GRAD=$(jq -s 'first | .graduated' "$BRAIN_DIR/persona-signals.jsonl")
[ "$CNT" = "2" ] || fail "medium signals should merge (got count=$CNT)"
[ "$GRAD" = "false" ] || fail "medium confidence must NOT auto-graduate (got graduated=$GRAD)"
pass "medium confidence stays ungraduated"

# --- Test 4: trivially-different signals (only 1-2 words shared) do NOT merge ---
rm -f "$BRAIN_DIR/persona-signals.jsonl"

D1='[{"category":"workflow","signal":"prefers running unit tests before commit","evidence":"e1","confidence":"high"}]'
D2='[{"category":"code_style","signal":"writes comments only for non-obvious code","evidence":"e2","confidence":"high"}]'

CLAUDE_SESSION_ID=d1 run_merge "$D1"
CLAUDE_SESSION_ID=d2 run_merge "$D2"

N=$(count_signals)
[ "$N" = "2" ] || fail "unrelated signals must stay separate (got $N entries)"
pass "unrelated signals stay separate"

# --- Test 5: 3-word floor — very short signals don't merge into anything ---
rm -f "$BRAIN_DIR/persona-signals.jsonl"

T1='[{"category":"workflow","signal":"short signal here","evidence":"e1","confidence":"high"}]'
T2='[{"category":"workflow","signal":"short signal here","evidence":"e2","confidence":"high"}]'

# Same 3 content words on both sides. unique content words = ["short","signal","here"] = 3 words.
# Min is 3 → guard passes → 100% overlap → merge.
CLAUDE_SESSION_ID=t1 run_merge "$T1"
CLAUDE_SESSION_ID=t2 run_merge "$T2"
N=$(count_signals)
[ "$N" = "1" ] || fail "identical 3-word signals should merge (got $N entries)"
pass "3-word floor passes when both sides have 3 words"

# But a 2-word signal won't merge with a 5-word one even if all words match,
# because the 2-word side fails the >=3 guard.
rm -f "$BRAIN_DIR/persona-signals.jsonl"
T3='[{"category":"workflow","signal":"two words","evidence":"e1","confidence":"high"}]'
T4='[{"category":"workflow","signal":"two words here long enough","evidence":"e2","confidence":"high"}]'
CLAUDE_SESSION_ID=t3 run_merge "$T3"
CLAUDE_SESSION_ID=t4 run_merge "$T4"
N=$(count_signals)
[ "$N" = "2" ] || fail "below-floor signal should NOT merge (got $N entries)"
pass "3-word floor blocks ultra-short matches"

echo
echo "ALL PASS"
