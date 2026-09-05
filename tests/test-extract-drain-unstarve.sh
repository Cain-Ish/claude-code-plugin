#!/bin/bash
# pins: SB_DRAIN_BATCH — fixes the per-tick batch size so the unstarve ordering assertions are deterministic
# pins: SB_DRAIN_DEFER_MAX — raises the defer ceiling so the fixture's deliberately-starved items aren't force-processed before the unstarve behavior under test fires
# pins: SB_DRAIN_STALE_MAX — raises the stale ceiling (24h) so the fixture's items aren't force-processed by staleness before the unstarve behavior under test fires
# pins: SB_EXTRACT_STUB — points extraction at a stub binary so the drain tick runs hermetically without a real Claude spawn
# pins: SB_INTERACTIVE_OVERRIDE — forces the interactive-session gate open so the drain tick actually runs in this non-interactive test shell
# extract-drain.sh un-starve (Phase 1 task 3): an always-on interactive operator
# must not starve the backlog forever. A bounded staleness-escape lets ONE drain
# through when consecutive defers cross SB_DRAIN_DEFER_MAX or the oldest pending
# transcript ages past SB_DRAIN_STALE_MAX.
# ORACLE: whether do_extract actually ran, observed via a stub that appends the
# slug to invoked.log — never by re-reading the drainer's own state, plus raw
# reads of the .drain-defer-count file (a filesystem fact the drainer wrote).
set -u
# The forced escape is now gated on a lock-bypass condition (ANTHROPIC_API_KEY or pmode); unset
# both so the gate is deterministic, then escape cases supply ANTHROPIC_API_KEY explicitly.
unset CLAUDECODE ANTHROPIC_API_KEY SB_DRAIN_DEFER_PMODE_ONLY 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
DRAIN="$ROOT/scripts/extract-drain.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"            # contain ~ so nothing can touch the real home
export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR/transcripts"
# auto_improve/auto_maintain OFF: this test exercises ONLY the defer/escape +
# stub-extraction path. Without this the drainer's default-ON cascade would fire
# the real maintain-llm-drain → a live bwrap+claude -p on a host that has them.
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$BRAIN_DIR/config.json"
TXD="$BRAIN_DIR/transcripts"; CNT="$BRAIN_DIR/.drain-defer-count"; LOG="$SANDBOX/invoked.log"

# Stub extractor = the oracle: append slug ($2) to invoked.log, succeed.
STUB="$SANDBOX/stub.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "${2:-?}" >> "%s"\nexit 0\n' "$LOG" > "$STUB"; chmod +x "$STUB"

invoked(){ [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
cnt(){ [ -f "$CNT" ] && tr -d '[:space:]' < "$CNT" || echo "ABSENT"; }
mk_tx(){  # header lines, then --- , then a body large enough to dodge the too-small fast-path
  { printf 'slug: proj\nsession: s1\ndate: 2026-01-01\n---\n'; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$TXD/$1"
}
reset(){ rm -f "$LOG" "$LOG.attempts" "$CNT" "$BRAIN_DIR/.last-drain-escape" "$BRAIN_DIR/.extraction-state.jsonl"; rm -rf "$TXD"; mkdir -p "$TXD"; }
run(){ env "$@" SB_EXTRACT_STUB="$STUB" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true; }
backdate(){ local f="$1" ago="$2" t; t=$(( $(date +%s) - ago ));
  touch -d "@$t" "$f" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null; }

echo "=== extract-drain un-starve ==="

# T1: active + fresh + no counter → defer, counter bumped to 1
reset; mk_tx a.txt
run SB_INTERACTIVE_OVERRIDE=active
[ "$(invoked)" = "0" ] && pass "T1: deferred (no extract)" || fail "T1: extracted while active"
[ "$(cnt)" = "1" ] && pass "T1: defer counter bumped to 1" || fail "T1: counter=$(cnt) (want 1)"

# T2: active + counter at max + escape-safe (api key) → escape (extracts), counter reset
reset; mk_tx a.txt; printf '6' > "$CNT"
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_DEFER_MAX=6 ANTHROPIC_API_KEY=test-key
[ "$(invoked)" -ge "1" ] && pass "T2: counter-threshold escape extracted" || fail "T2: did not escape (invoked=$(invoked))"
[ "$(cnt)" = "ABSENT" ] && pass "T2: counter reset on escape" || fail "T2: counter not reset ($(cnt))"

# T3: active + stale transcript (2d old) + escape-safe → age escape regardless of counter
reset; mk_tx a.txt; backdate "$TXD/a.txt" 172800
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_STALE_MAX=86400 ANTHROPIC_API_KEY=test-key
[ "$(invoked)" -ge "1" ] && pass "T3: stale-age escape extracted" || fail "T3: age escape did not fire (invoked=$(invoked))"

# T4: active + below both bounds → defer, counter increments 2→3
reset; mk_tx a.txt; printf '2' > "$CNT"
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_DEFER_MAX=6 SB_DRAIN_STALE_MAX=86400
[ "$(invoked)" = "0" ] && pass "T4: below bounds → deferred" || fail "T4: extracted below bounds"
[ "$(cnt)" = "3" ] && pass "T4: counter incremented 2→3" || fail "T4: counter=$(cnt) (want 3)"

# T5: inactive → normal drain + counter reset
reset; mk_tx a.txt; printf '5' > "$CNT"
run SB_INTERACTIVE_OVERRIDE=inactive
[ "$(invoked)" -ge "1" ] && pass "T5: inactive drains normally" || fail "T5: inactive did not drain (invoked=$(invoked))"
[ "$(cnt)" = "ABSENT" ] && pass "T5: non-deferred run resets counter" || fail "T5: counter not reset ($(cnt))"

# T8: cross-OS — pmode helper preserves pgrep||ps fallback, no /proc read, pmode wired
grep -q 'command -v pgrep' "$DRAIN" && grep -q 'ps -e -o args=' "$DRAIN" && pass "T8: pgrep||ps fallback preserved" || fail "T8: fallback missing"
grep -q '/proc/' "$DRAIN" && fail "T8: introduced a /proc read (Linux-only)" || pass "T8: no /proc read (cross-OS)"
grep -q 'SB_DRAIN_DEFER_PMODE_ONLY' "$DRAIN" && pass "T8: pmode-only relaxation wired" || fail "T8: pmode switch missing"

# T9: age-escape is RATE-LIMITED — a FAILING escape (lock truly held, transcript stays pending)
# must NOT re-fire on the very next tick (review fix: else it burns a full extract budget every
# cycle until the transcript poison-pills). Oracle = the count of extraction ATTEMPTS.
reset
FSTUB="$SANDBOX/fstub.sh"; printf '#!/bin/bash\nprintf "%%s\\n" "${2:-?}" >> "%s.attempts"\nexit 1\n' "$LOG" > "$FSTUB"; chmod +x "$FSTUB"
mk_tx a.txt; backdate "$TXD/a.txt" 172800
attempts(){ [ -f "$LOG.attempts" ] && wc -l < "$LOG.attempts" | tr -d ' ' || echo 0; }
cdrun(){ env SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_STALE_MAX=86400 ANTHROPIC_API_KEY=test-key SB_EXTRACT_STUB="$FSTUB" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true; }
cdrun; A1=$(attempts)
cdrun; A2=$(attempts)
[ "$A1" -ge "1" ] && pass "T9: first age-escape attempted extraction (A1=$A1)" || fail "T9: first escape didn't attempt (A1=$A1)"
[ "$A2" = "$A1" ] && pass "T9: next tick rate-limited — no re-escape (attempts stayed $A1)" || fail "T9: re-escaped on next tick ($A1→$A2)"

# T-gate (INVERTED 2026-08-23): under pure OAuth (no ANTHROPIC_API_KEY, no pmode) a starved
# backlog MUST escape. The previous oracle asserted the opposite — "must NOT escape, a forced
# claude -p would hang on the held OAuth lock" (ee8a74c, 2026-05-24, Linux/systemd) — and that
# oracle was the 3-day production outage: 120 consecutive defers, 72/100 transcripts never
# mined, every tick exiting 0, CI green throughout. The premise no longer holds: measured
# 2026-08-22/23 on Claude Code 2.1.241 with an interactive session live, 72 real transcripts
# drained via claude-cli, 0 failed, seconds each. The timeout wrapper bounds the worst case
# (one `retry`, dead-letter only after SB_DRAIN_MAX_FAILS) — that bound IS the safety story.
# A test that locks "do not drain" as correct can never go red when memory stops flowing.
reset; mk_tx a.txt; printf '6' > "$CNT"
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_DEFER_MAX=6   # deliberately NO key, NO pmode
[ "$(invoked)" -ge "1" ] && pass "T-gate: starved under pure OAuth → escapes (the 3-day-outage oracle is inverted)" || fail "T-gate: starved under pure OAuth did NOT escape — this is the 120-defer outage shape"

# T-interaction: a COUNTER-branch escape must NOT consume the AGE-branch cooldown (review fix).
# counter at max + stale pending transcript + api key: run 1 escapes via the counter (no age
# stamp); run 2 (counter reset, transcript still stale+pending) must STILL be able to age-escape.
reset; mk_tx a.txt; backdate "$TXD/a.txt" 172800; printf '6' > "$CNT"
icrun(){ env SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_DEFER_MAX=6 SB_DRAIN_STALE_MAX=86400 ANTHROPIC_API_KEY=test-key SB_EXTRACT_STUB="$FSTUB" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true; }
icrun; I1=$(attempts)
icrun; I2=$(attempts)
[ "$I2" -gt "$I1" ] && pass "T-interaction: counter escape does not consume the age cooldown ($I1→$I2)" || fail "T-interaction: counter escape suppressed the age escape ($I1→$I2)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
