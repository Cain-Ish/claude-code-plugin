#!/bin/bash
# pins: SB_CAPTURE_HEALTH_BANNER — silences this unrelated banner so only the loop-dead banner under test appears in captured output
# pins: SB_DISABLE_AUTO_TIMER — silences this unrelated timer banner so only the loop-dead banner under test appears in captured output
# pins: SB_LOOP_DEAD_BANNER — kill-switch test: asserts =off suppresses the loop-dead banner
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
# The progress marker is .extraction-state.jsonl — the drainer's done-set. It was
# .extractor-health.json until 0.47.0, but on OAuth every Stop hook rewrites that file to
# status=queued whether or not anything drained, so the old clock was always fresh and this
# banner was suppressed in EXACTLY the starvation case it exists for (ledger F5: during the
# 3-day 2026-08 outage it never fired once).
mk_state() { printf '{"basename":"s1_demo_2026-01-01.txt","ts":"2026-01-01T00:00:00Z","outcome":"ok"}\n' > "$BRAIN/.extraction-state.jsonl"; }

# --- Test 1: timer=yes + stale progress marker → banner + audit-log trace line ---
# D173: this is trace (also user-visible via the banner), not a hook failure —
# gate=/ec0 routes it to audit-log, and it must never pollute error-log.
mk_state; touch -t "$STAMP_OLD" "$BRAIN/.extraction-state.jsonl"
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' || fail "stale marker + timer=yes should fire the loop-dead banner"
grep -q 'gate=loop-dead' "$BRAIN/audit-log.jsonl" 2>/dev/null || fail "loop-dead TRACE line missing from audit-log"
grep -q 'loop-dead' "$BRAIN/error-log.jsonl" 2>/dev/null && fail "loop-dead trace leaked into error-log"
pass "stale marker + registered timer → loop-dead banner (audit-log trace, not error-log)"

# --- Test 2: fresh marker → silent ---
mk_state   # fresh mtime (now)
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' && fail "fresh marker must not fire the banner"
pass "fresh marker → no banner"

# --- Test 2b (F5 regression): stale STATE + FRESH health file must STILL fire — the health
# file is refreshed by every OAuth Stop and must carry zero weight in the clock.
touch -t "$STAMP_OLD" "$BRAIN/.extraction-state.jsonl"
printf '{"status":"queued","reason":"in-session OAuth"}
' > "$BRAIN/.extractor-health.json"   # fresh NOW
OUT=$(run CAP_TIMER=yes)
echo "$OUT" | grep -q 'looks DEAD' || fail "F5 regression: a fresh health file must not mask a stale done-set (the 3-day-outage blind spot)"
pass "stale state + fresh health → banner still fires (health carries no weight)"
rm -f "$BRAIN/.extractor-health.json"

# --- Test 3: kill switch off + stale → silent ---
touch -t "$STAMP_OLD" "$BRAIN/.extraction-state.jsonl"
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
