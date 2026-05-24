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

# Test 5: lock held → no-op
reset; mk_tx "s1_proj_2026-05-24.txt" proj
exec 8>"$BRAIN_DIR/.extract-drain.lock"; flock -n 8
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
flock -u 8; exec 8>&-
eq "lock contention is a no-op" "$(done_count)" "0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
