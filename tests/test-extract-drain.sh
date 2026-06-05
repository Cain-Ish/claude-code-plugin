#!/bin/bash
# Tests for extract-drain.sh
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
DRAIN="$SCRIPT_DIR/extract-drain.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"

# These tests run the drainer for its processing behavior. When the suite runs
# inside a Claude Code session, CLAUDECODE=1 leaks in and the drainer (correctly)
# refuses — so unset it here for determinism. Test 1 re-sets it explicitly.
unset CLAUDECODE 2>/dev/null || true
# The suite also runs while an interactive `claude` is alive (the session running
# it), which the new defer-guard would (correctly) skip on. Force the guard to
# "inactive" for the processing tests; the defer test overrides to "active".
export SB_INTERACTIVE_OVERRIDE=inactive

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 — got '$2' want '$3'"; }

# A stub that "extracts" a transcript: succeeds unless the slug is 'poison'.
# The drainer calls: "$SB_EXTRACT_STUB" <txt> <slug>
STUB="$SANDBOX/stub.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
slug="$2"
[ "$slug" = "poison" ] && exit 1
exit 0
EOF
chmod +x "$STUB"
export SB_EXTRACT_STUB="$STUB"

mk_tx() {  # $1 = name, $2 = slug
  local f="$BRAIN_DIR/transcripts/$1"
  cat > "$f" <<EOF
--- session-meta ---
session_id: ${1%%_*}
project_slug: $2
date: 2026-05-24
tool_count: 2
line_count: 4
---

USER: x
ASSISTANT: y
EOF
}
done_count() { [ -f "$STATE" ] && grep -c '"outcome":"ok"' "$STATE" || echo 0; }
reset() { rm -rf "$BRAIN_DIR/transcripts" "$STATE" "$BRAIN_DIR/.extract-drain.lock"; mkdir -p "$BRAIN_DIR/transcripts"; }

echo "=== extract-drain.sh tests ==="

# Test 1: refuses to run inside a session
reset; mk_tx "s1_proj_2026-05-24.txt" proj
CLAUDECODE=1 bash "$DRAIN" >/dev/null 2>&1 || true
eq "in-session refusal leaves state empty" "$(done_count)" "0"

# Test 1b: an interactive claude session active → defer cleanly (no work, no state)
reset; mk_tx "s1_proj_2026-05-24.txt" proj
SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "interactive session → no extraction" "$(done_count)" "0"
[ ! -f "$STATE" ] && ok "interactive defer writes no state at all" || no "interactive defer wrote state"

# Test 2: processes up to BATCH oldest-first
reset
for i in 1 2 3 4 5 6 7; do mk_tx "s${i}_proj_2026-05-24.txt" proj; sleep 0.05; done
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "batch of 5 processed" "$(done_count)" "5"

# Test 3: a done transcript is not reprocessed; remaining 2 drain next run
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "remaining 2 drained, total 7" "$(done_count)" "7"

# Test 4: poison transcript → retry then terminal error after MAX_FAILS
reset; mk_tx "p1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 1
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 2
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 3rd → terminal error
RETRIES=$(grep -c '"outcome":"retry"' "$STATE" || echo 0)
ERRORS=$(grep -c '"outcome":"error"' "$STATE" || echo 0)
eq "poison: 2 retries recorded" "$RETRIES" "2"
eq "poison: 1 terminal error" "$ERRORS" "1"
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # must NOT touch it again
eq "poison: not reprocessed after terminal" "$(grep -c '"outcome":"retry"' "$STATE" || echo 0)" "2"

# Test 4b: a run where everything fails → health status must be "fail" (not clobbered to ok)
reset; mk_tx "f1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true
HSTATUS=$(jq -r '.status // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)
eq "all-fail run reports health=fail" "$HSTATUS" "fail"

# Test 5: lock held → no-op
reset; mk_tx "s1_proj_2026-05-24.txt" proj
exec 8>"$BRAIN_DIR/.extract-drain.lock"; flock -n 8
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
flock -u 8; exec 8>&-
eq "lock contention is a no-op" "$(done_count)" "0"

# Test 2c (U2): summary health reports the REAL backend, not hardcoded "cli-oauth"
# (the stub writes no per-call backend → summary should read the health file and
# default to "drainer", never overwrite a real backend with a fixed label).
reset; mk_tx "b1_proj_2026-05-24.txt" proj
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
HBACK=$(jq -r '.backend // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)
[ "$HBACK" != "cli-oauth" ] && ok "summary backend not hardcoded cli-oauth (got '$HBACK')" || no "summary hardcoded backend=cli-oauth"

# Test 2d (U2): the summary PRESERVES the real backend the per-transcript extractor
# wrote (e.g. local), rather than overwriting it. Pre-seed a real backend; the stub
# writes no health, so the summary must read+keep it.
reset; mk_tx "c1_proj_2026-05-24.txt" proj
printf '{"checked_at":"x","backend":"local","status":"ok","reason":""}\n' > "$BRAIN_DIR/.extractor-health.json"
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "summary preserves real backend=local" "$(jq -r '.backend // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)" "local"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
