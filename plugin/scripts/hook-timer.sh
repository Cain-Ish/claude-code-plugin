#!/bin/bash
# R7 hook latency telemetry — transparent timing wrapper for heavy hooks.
#
# hooks.json usage:  bash hook-timer.sh <budget_seconds> <script> [args…]
# (<budget_seconds> mirrors the hooks.json timeout for the wrapped entry so
# the warn threshold tracks the real ceiling.)
#
# Appends {kind:"latency", hook, duration_ms, exit_code, budget_warn?} to
# audit-log.jsonl (the trajectory channel — same file the guards write).
# Why: the R1 ec=124 class (24s hook stacks vs 25s timeouts) was only
# diagnosable by forensic log mining; this makes per-hook latency queryable
# and lets /second-brain:status render p50/p95 with budget warnings.
#
# Contract: TRANSPARENT — child stdin/stdout/stderr and exit code pass
# through untouched; any timer-side failure is swallowed (fail-open). The
# child's own SB_NESTED_SPAWN guard still applies inside it; the wrapper
# itself never gates.
set -u

BUDGET_S="${1:-0}"; shift || { echo "usage: hook-timer.sh <budget_s> <script> [args…]" >&2; exit 0; }
SCRIPT="${1:-}"; shift || true
[ -n "$SCRIPT" ] || exit 0

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"

# Millisecond clock, portable: GNU date has %N; BSD/macOS date renders a
# literal 'N' — fall back to whole seconds there (coarse but honest).
_now_ms() {
  local n
  n=$(date +%s%N 2>/dev/null)
  case "$n" in
    *N|*n|'') echo $(( $(date +%s) * 1000 )) ;;
    *) echo $(( n / 1000000 )) ;;
  esac
}

T0=$(_now_ms)
bash "$SCRIPT" "$@"
EC=$?
T1=$(_now_ms)

{
  DUR=$(( T1 - T0 )); [ "$DUR" -lt 0 ] && DUR=0
  WARN=""
  case "$BUDGET_S" in
    ''|*[!0-9]*) : ;;
    0) : ;;
    *)
      # warn when duration exceeds 70% of the budget (ms compare, int math)
      if [ $(( DUR * 10 )) -ge $(( BUDGET_S * 1000 * 7 )) ]; then
        WARN=',"budget_warn":true'
      fi
      ;;
  esac
  HOOK=$(basename "$SCRIPT")
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","kind":"latency","hook":"%s","duration_ms":%s,"exit_code":%s%s}\n' \
    "$TS" "$HOOK" "$DUR" "$EC" "$WARN" >> "$BRAIN_DIR/audit-log.jsonl"
} 2>/dev/null || true

exit "$EC"
