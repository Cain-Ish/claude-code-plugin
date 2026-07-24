#!/bin/bash
# Tests the loop-DEAD banner (P1.1, archive/docs branch, docs/plans/2026-07-13-p1-observability.md):
# scheduler REGISTERED but the drainer has not ticked in SB_LOOP_DEAD_HOURS — the
# case the timeout/dead-letter banners cannot see (they need attempts to leave
# signatures; a task that never fires leaves nothing). Timer state is injected via
# the CAP_TIMER env seam (in production CAP_TIMER is only ever a shell-local probe
# result; SB_CAPTURE_HEALTH_BANNER=off keeps 0a-ter from recomputing it).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

BRAIN="$TMP/.second-brain"
WORKDIR="$TMP/demo"
STUB="$TMP/stub"; mkdir -p "$STUB" "$WORKDIR" "$BRAIN/projects/demo" "$BRAIN/bin"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
printf '# PROJECT: demo\n' > "$BRAIN/projects/demo/PROJECT.md"

run() {
  (cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' \
    | env PATH="$STUB:$PATH" HOME="$TMP" CLAUDE_PROJECT_DIR="$WORKDIR" \
          BRAIN_DIR="$BRAIN" ANTHROPIC_API_KEY="" \
          SB_CAPTURE_HEALTH_BANNER=off SB_DISABLE_AUTO_TIMER=1 \
          "$@" bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
}

STAMP_OLD=202501010000   # far past any 48h threshold
mk_health() { printf '{"status":"ok","reason":"drained 0"}\n' > "$BRAIN/.extractor-health.json"; }

# --- Test 1: timer=yes + stale health marker → banner + loud error-log line ---
mk_health; touch -t "$STAMP_OLD" "$BRAIN/.extractor-health.json"
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' || fail "stale marker + timer=yes should fire the loop-dead banner"
grep -q 'loop-dead:' "$BRAIN/error-log.jsonl" 2>/dev/null || fail "loop-dead TRACE line missing from error-log"
pass "stale marker + registered timer → loop-dead banner (loud)"

# --- Test 2: fresh marker → silent ---
mk_health   # fresh mtime (now)
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' && fail "fresh marker must not fire the banner"
pass "fresh marker → no banner"

# --- Test 3: kill switch off + stale → silent ---
touch -t "$STAMP_OLD" "$BRAIN/.extractor-health.json"
OUT=$(run CAP_TIMER=yes SB_LOOP_DEAD_BANNER=off)
echo "$OUT" | grep -q 'looks DEAD' && fail "SB_LOOP_DEAD_BANNER=off must silence the banner"
pass "kill switch silences the banner"

# --- Test 4: timer NOT registered → silent (timer-absent is the self-install banner's lane) ---
OUT=$(run CAP_TIMER=no)
echo "$OUT" | grep -q 'looks DEAD' && fail "timer=no must not fire (not this banner's case)"
pass "timer absent → no banner"

# --- Test 5: never-ran fallback — no stamped files, shim mtime is the clock ---
rm -f "$BRAIN/.extractor-health.json" "$BRAIN/.extraction-state.jsonl"
printf '#!/bin/bash\n' > "$BRAIN/bin/sb-extract-drain.sh"
touch -t "$STAMP_OLD" "$BRAIN/bin/sb-extract-drain.sh"
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' || fail "old shim + zero runs should read as dead (never-ran case)"
pass "never-ran: old shim + registered timer → banner"

# --- Test 6: never-ran but FRESH shim (just installed) → silent grace period ---
touch "$BRAIN/bin/sb-extract-drain.sh"
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' && fail "freshly installed shim must get the grace period"
pass "fresh install → no banner (grace)"

echo; echo "ALL PASS"
