#!/bin/bash
# Tests for dream-autostage.sh
# After C5-A: never stages a dream, never spawns subagent. Banner suggests
# /second-brain:dream for explicit invocation. See
# wiki/decisions/2026-05-28-plugin-architecture-rethink.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
AUTOSTAGE="$SCRIPT_DIR/dream-autostage.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki"
echo "# seed" > "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki/seed.md"

PASS=0; FAIL=0

assert_empty() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then PASS=$((PASS+1)); echo "  PASS: $label (no banner)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — expected no banner, got: $out"; fi
}
assert_banner() {
  local label="$1" out="$2"
  if printf '%s' "$out" | grep -q '/second-brain:dream'; then PASS=$((PASS+1)); echo "  PASS: $label (suggestion banner)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — expected /second-brain:dream banner, got: $out"; fi
}
assert_contains() {
  local label="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -q "$needle"; then PASS=$((PASS+1)); echo "  PASS: $label (has $needle)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — '$needle' not in: $out"; fi
}
assert_not_contains() {
  local label="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -q "$needle"; then FAIL=$((FAIL+1)); echo "  FAIL: $label — '$needle' should NOT appear in: $out";
  else PASS=$((PASS+1)); echo "  PASS: $label (no $needle)"; fi
}
assert_eq() {
  local label="$1" a="$2" b="$3"
  if [ "$a" = "$b" ]; then PASS=$((PASS+1)); echo "  PASS: $label";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — '$a' != '$b'"; fi
}

mk_transcripts() {  # $1 = count
  local n="$1" i
  for i in $(seq 1 "$n"); do
    echo "session $i" > "$BRAIN_DIR/transcripts/sess-$i-$RANDOM.txt"
  done
}
mk_dream() {  # $1 = id, $2 = status (creates a transcripts/ subdir = stable anchor)
  local id="$1" st="$2" dir="$BRAIN_DIR/dreams/$1"
  mkdir -p "$dir/transcripts"
  jq -nc --arg id "$id" --arg st "$st" '{id:$id, status:$st}' > "$dir/status.json"
}
count_dreams() { find "$BRAIN_DIR/dreams" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' '; }
reset_brain() {
  rm -rf "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
  mkdir -p "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
}

echo "=== dream-autostage.sh tests (C5-A: explicit-invocation only) ==="

# Test 1: kill switch → no banner
reset_brain; mk_transcripts 20
OUT=$(SB_DREAM_AUTOSTAGE=off bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "kill switch off" "$OUT"

# Test 2: no dream yet, >= threshold → banner, NO new dream staged
reset_brain; mk_transcripts 12
BEFORE=$(count_dreams)
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
AFTER=$(count_dreams)
assert_banner "no dream + 12 transcripts → suggestion banner" "$OUT"
assert_eq "threshold trip stages no new dream" "$BEFORE" "$AFTER"
assert_not_contains "banner does not instruct subagent spawn" "$OUT" "Spawn"
assert_not_contains "banner does not instruct subagent spawn (lowercase)" "$OUT" "run_in_background"

# Test 3: below threshold → no banner
reset_brain; mk_transcripts 3
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "below threshold" "$OUT"

# Test 4: in-flight dream (running) → no banner
reset_brain; mk_transcripts 20
mk_dream drm_inflight running
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "in-flight (running) dream" "$OUT"

# Test 5: completed dream + enough NEW transcripts after it → banner
reset_brain
mk_dream drm_old completed
sleep 1                      # ensure transcripts mtime > dream transcripts/ anchor
mk_transcripts 12
BEFORE=$(count_dreams)
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
AFTER=$(count_dreams)
assert_banner "completed dream + 12 new transcripts" "$OUT"
assert_eq "completed-watermark trip stages no new dream" "$BEFORE" "$AFTER"

# Test 6: completed dream NEWER than all transcripts → no banner
reset_brain
mk_transcripts 12
sleep 1
mk_dream drm_recent completed   # transcripts/ anchor created after the transcripts
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "transcripts older than dream" "$OUT"

# Test 7: pending dream → recovery banner naming the id, no new dream staged
reset_brain; mk_transcripts 2
mk_dream drm_stranded pending
BEFORE=$(count_dreams)
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
AFTER=$(count_dreams)
assert_banner "pending dream → recovery banner" "$OUT"
assert_contains "recovery names the pending id" "$OUT" "drm_stranded"
assert_eq "pending recovery stages no new dream" "$BEFORE" "$AFTER"
assert_not_contains "pending banner does not instruct subagent spawn" "$OUT" "Spawn"

# Test 8: old pending + newer completed → recover the PENDING one, don't stage
reset_brain
mk_dream drm_oldpending pending
sleep 1
mk_dream drm_newdone completed
mk_transcripts 20
BEFORE=$(count_dreams)
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
AFTER=$(count_dreams)
assert_contains "all-dreams scan recovers old pending" "$OUT" "drm_oldpending"
assert_eq "no new dream staged while one pending" "$BEFORE" "$AFTER"

# Test 9: orphan dir (no status.json) must NOT hijack the watermark
reset_brain
mk_transcripts 12
sleep 1
mk_dream drm_done completed       # anchor newer than the 12 transcripts
mkdir -p "$BRAIN_DIR/dreams/drm_orphan"
touch "$BRAIN_DIR/dreams/drm_orphan"   # newest by mtime, but no status.json
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "orphan dir does not hijack watermark" "$OUT"

# Test 10: non-numeric threshold defaults to 10
reset_brain; mk_transcripts 12
OUT=$(SB_DREAM_NEW_THRESHOLD=abc bash "$AUTOSTAGE" 2>/dev/null || true)
assert_banner "non-numeric threshold → default 10 (12 fires)" "$OUT"
reset_brain; mk_transcripts 3
OUT=$(SB_DREAM_NEW_THRESHOLD=abc bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "non-numeric threshold → default 10 (3 no fire)" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
