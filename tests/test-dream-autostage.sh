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

# ═══ R4 (SCRIPTS-02/04): stale-pending reclaim + failed-dream surfacing ═══════
mk_dream_at() {  # $1=id $2=status $3=created_at ISO
  local id="$1" st="$2" cre="$3" dir="$BRAIN_DIR/dreams/$1"
  mkdir -p "$dir/transcripts"
  jq -nc --arg id "$id" --arg st "$st" --arg c "$cre" '{id:$id, status:$st, created_at:$c, error:null}' > "$dir/status.json"
}

# Backdate a file's mtime by N seconds (cross-OS: GNU touch -d @epoch, else BSD
# date -r + touch -t). Mirrors tests/test-dream-staleness.sh. The unified staleness
# policy keys on status.json MTIME, so fixtures backdate that, not created_at.
backdate() {  # $1=file $2=seconds_ago
  local f="$1" ago="$2" t
  t=$(( $(date +%s) - ago ))
  touch -d "@$t" "$f" 2>/dev/null \
    || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null \
    || { echo "  FAIL: cannot backdate mtime (need GNU or BSD touch)"; exit 1; }
}

# (e) STALE pending (status.json mtime > 6h, runner never started) → reclaimed to
# failed + banner says failed, NOT "resume". mtime drives the reclaim now, not created_at.
reset_brain; mk_dream drm_stale pending
backdate "$BRAIN_DIR/dreams/drm_stale/status.json" 25200
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_eq "stale pending transitioned to failed" "$(jq -r '.status' "$BRAIN_DIR/dreams/drm_stale/status.json")" "failed"
assert_contains "reclaim sets the error reason" "$(jq -r '.error' "$BRAIN_DIR/dreams/drm_stale/status.json")" "runner never started"
assert_contains "banner reports the failure" "$OUT" "dream failed"
assert_not_contains "no resume banner for a dead pending" "$OUT" "Run \`/second-brain:dream\` to resume"

# (f) FRESH pending → resume banner, untouched (pre-R4 behavior preserved).
reset_brain; mk_dream_at drm_fresh pending "$(date -u +%FT%TZ)"
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_eq "fresh pending stays pending" "$(jq -r '.status' "$BRAIN_DIR/dreams/drm_fresh/status.json")" "pending"
assert_contains "fresh pending gets the resume banner" "$OUT" "resume"

# (g) FAILED dream (no pending/running) → one banner naming id + error; failed
# is terminal for the watermark so the threshold logic still runs.
reset_brain
mk_dream_at drm_dead failed "2026-06-07T00:00:00Z"
jq '.error = "exit 1: boom tail"' "$BRAIN_DIR/dreams/drm_dead/status.json" > "$BRAIN_DIR/dreams/drm_dead/status.json.t" \
  && mv "$BRAIN_DIR/dreams/drm_dead/status.json.t" "$BRAIN_DIR/dreams/drm_dead/status.json"
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_contains "failed dream banner names the id" "$OUT" "drm_dead"
assert_contains "failed dream banner carries the error" "$OUT" "boom tail"
mk_transcripts 12
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_contains "threshold banner still fires alongside the failed notice" "$OUT" "dream consolidation ready"

# (g2) D088: a FAILED dream the operator already reviewed (archived_at set by
# dream_discard/dream_accept) is TERMINAL and must NOT re-banner forever —
# only the "surface once" promise the header makes. No transcripts here, so
# a clean run must produce NO banner at all once archived_at is respected.
reset_brain
mk_dream_at drm_reviewed failed "2026-06-07T00:00:00Z"
jq '.error = "exit 1: no stderr" | .archived_at = "2026-08-31T20:37:07.731Z"' \
  "$BRAIN_DIR/dreams/drm_reviewed/status.json" > "$BRAIN_DIR/dreams/drm_reviewed/status.json.t" \
  && mv "$BRAIN_DIR/dreams/drm_reviewed/status.json.t" "$BRAIN_DIR/dreams/drm_reviewed/status.json"
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_not_contains "archived failed dream does not re-banner its id" "$OUT" "drm_reviewed"
assert_empty "archived failed dream + no new transcripts -> no banner at all (D088)" "$OUT"

# (h) quarantine file alone (probe failures stage no dream) → surfaced.
reset_brain
printf '[2026-06-11T00:00:00Z] quarantined after 3 consecutive failures: bwrap preflight failed\n' > "$BRAIN_DIR/.llm-maintain-quarantine"
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_contains "quarantine file surfaced at SessionStart" "$OUT" "quarantine"
rm -f "$BRAIN_DIR/.llm-maintain-quarantine"

# (i) STALE running (crashed mid-run, status.json mtime > 6h) → reclaimed to
# failed instead of deadlocking every future dream (the running-reclaim nuance
# of the unified mtime policy).
reset_brain; mk_dream drm_runstale running
backdate "$BRAIN_DIR/dreams/drm_runstale/status.json" 25200
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_eq "stale running transitioned to failed" "$(jq -r '.status' "$BRAIN_DIR/dreams/drm_runstale/status.json")" "failed"
assert_contains "stale running error names the cause" "$(jq -r '.error' "$BRAIN_DIR/dreams/drm_runstale/status.json")" "stale running"
assert_contains "stale running surfaces a failure banner" "$OUT" "dream failed"
assert_contains "stale running banner names the id" "$OUT" "drm_runstale"

# (j) FRESH running (mtime=now, runner heartbeating) → blocks; never reclaimed,
# never stacks a second dream. Preserves Test 4 intent under the mtime policy.
reset_brain; mk_dream drm_runfresh running; mk_transcripts 20
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_eq "fresh running stays running" "$(jq -r '.status' "$BRAIN_DIR/dreams/drm_runfresh/status.json")" "running"
assert_empty "fresh running blocks (no banner)" "$OUT"

# (k) FRESH pending (mtime=now) → resume banner, untouched (regression-lock).
reset_brain; mk_dream drm_pfresh pending
OUT=$(bash "$AUTOSTAGE" 2>/dev/null || true)
assert_eq "fresh pending stays pending" "$(jq -r '.status' "$BRAIN_DIR/dreams/drm_pfresh/status.json")" "pending"
assert_contains "fresh pending gets resume banner" "$OUT" "resume"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
