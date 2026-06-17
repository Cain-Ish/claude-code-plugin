#!/bin/bash
# extract-drain.sh un-starve (Phase 1 task 3): an always-on interactive operator
# must not starve the backlog forever. A bounded staleness-escape lets ONE drain
# through when consecutive defers cross SB_DRAIN_DEFER_MAX or the oldest pending
# transcript ages past SB_DRAIN_STALE_MAX.
# ORACLE: whether do_extract actually ran, observed via a stub that appends the
# slug to invoked.log — never by re-reading the drainer's own state, plus raw
# reads of the .drain-defer-count file (a filesystem fact the drainer wrote).
set -u
unset CLAUDECODE 2>/dev/null || true
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
reset(){ rm -f "$LOG" "$CNT" "$BRAIN_DIR/.extraction-state.jsonl"; rm -rf "$TXD"; mkdir -p "$TXD"; }
run(){ env "$@" SB_EXTRACT_STUB="$STUB" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true; }
backdate(){ local f="$1" ago="$2" t; t=$(( $(date +%s) - ago ));
  touch -d "@$t" "$f" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null)" "$f" 2>/dev/null; }

echo "=== extract-drain un-starve ==="

# T1: active + fresh + no counter → defer, counter bumped to 1
reset; mk_tx a.txt
run SB_INTERACTIVE_OVERRIDE=active
[ "$(invoked)" = "0" ] && pass "T1: deferred (no extract)" || fail "T1: extracted while active"
[ "$(cnt)" = "1" ] && pass "T1: defer counter bumped to 1" || fail "T1: counter=$(cnt) (want 1)"

# T2: active + counter at max → escape (extracts), counter reset
reset; mk_tx a.txt; printf '6' > "$CNT"
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_DEFER_MAX=6
[ "$(invoked)" -ge "1" ] && pass "T2: counter-threshold escape extracted" || fail "T2: did not escape (invoked=$(invoked))"
[ "$(cnt)" = "ABSENT" ] && pass "T2: counter reset on escape" || fail "T2: counter not reset ($(cnt))"

# T3: active + stale transcript (2d old) → age escape regardless of counter
reset; mk_tx a.txt; backdate "$TXD/a.txt" 172800
run SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_STALE_MAX=86400
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
