#!/bin/bash
# Tests for dream-autostage.sh
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
  if printf '%s' "$out" | grep -q 'dream auto-staged'; then PASS=$((PASS+1)); echo "  PASS: $label (banner)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $label — expected banner, got: $out"; fi
}
mk_transcripts() {  # $1 = count
  local n="$1" i
  for i in $(seq 1 "$n"); do
    echo "session $i" > "$BRAIN_DIR/transcripts/sess-$i-$RANDOM.txt"
  done
}
reset_brain() {
  rm -rf "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
  mkdir -p "$BRAIN_DIR/transcripts" "$BRAIN_DIR/dreams"
}

echo "=== dream-autostage.sh tests ==="

# Test 1: kill switch → no banner
reset_brain; mk_transcripts 20
OUT=$(SB_DREAM_AUTOSTAGE=off bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "kill switch off" "$OUT"

# Test 2: no dream yet, >= threshold → banner
reset_brain; mk_transcripts 12
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_banner "no dream + 12 transcripts" "$OUT"

# Test 3: below threshold → no banner
reset_brain; mk_transcripts 3
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "below threshold" "$OUT"

# Test 4: in-flight dream (running) → no banner
reset_brain; mk_transcripts 20
mkdir -p "$BRAIN_DIR/dreams/drm_inflight"
echo '{"id":"drm_inflight","status":"running"}' > "$BRAIN_DIR/dreams/drm_inflight/status.json"
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "in-flight dream" "$OUT"

# Test 5: completed dream + enough NEW transcripts after it → banner
reset_brain
mkdir -p "$BRAIN_DIR/dreams/drm_old"
echo '{"id":"drm_old","status":"completed"}' > "$BRAIN_DIR/dreams/drm_old/status.json"
sleep 1                      # ensure transcripts mtime > dream dir
mk_transcripts 12
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_banner "completed dream + 12 new transcripts" "$OUT"

# Test 6: completed dream NEWER than all transcripts → no banner
reset_brain
mk_transcripts 12
sleep 1
mkdir -p "$BRAIN_DIR/dreams/drm_recent"
echo '{"id":"drm_recent","status":"completed"}' > "$BRAIN_DIR/dreams/drm_recent/status.json"
touch "$BRAIN_DIR/dreams/drm_recent"   # make dream dir the newest
OUT=$(SB_DREAM_NEW_THRESHOLD=10 bash "$AUTOSTAGE" 2>/dev/null || true)
assert_empty "transcripts older than dream" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
