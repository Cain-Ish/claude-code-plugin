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

# Millisecond clock into _MS, with no process where bash can tell the time itself: bash 5's
# $EPOCHREALTIME (seconds.micro; the radix char is locale-dependent, so digits only). The old
# form spent two `date` spawns plus `basename` and `date -u` below on every wrapped call (~55 ms
# on MSYS, and far more under load: this wrapper sits on the PreToolUse hot path, where a hook
# that answers late is cancelled and the tool runs). Elsewhere: GNU date %N; BSD/macOS date
# renders a literal 'N' — fall back to whole seconds there (coarse but honest).
_now_ms() {
  local n
  if [ -n "${EPOCHREALTIME:-}" ]; then
    n="${EPOCHREALTIME//[!0-9]/}"
    _MS=$(( 10#$n / 1000 ))
    return 0
  fi
  n=$(date +%s%N 2>/dev/null)
  case "$n" in
    *N|*n|'') _MS=$(( $(date +%s) * 1000 )) ;;
    *) _MS=$(( n / 1000000 )) ;;
  esac
}

_now_ms; T0=$_MS
# G2 (R3, 2026-10-07): a verdict written after Claude Code cancelled the hook was enforced by no one
# (the tool ran), yet counted like any other. SB_HOOK_LATE_MS is the epoch ms from which a verdict
# counts as late: the budget, less a 2000 ms margin, from this wrapper's start. The margin is the
# CLI's own head start: its timeout clock starts before it launches `bash hook-timer.sh`, which took
# 70-2000 ms on a loaded MSYS box (R3 measurements) — so a verdict 3 s in may already be past a 5 s
# timeout. Conservative on purpose: "late" may over-report, never claim a cancelled verdict was
# enforced. The guards' audit rows stamp it (_fp_audit, sb_log_audit; EPOCHREALTIME, bash 5 only).
# SB_HOOK_LATE_PID (GT11, R3B): this wrapper's PID — the deadline belongs to its direct child (whose
# $PPID it is) and to nothing that child spawns: a claude -p under stop-extract runs hooks of its own
# with this export still in their environment. A budget of 0 (or none) hands no deadline on, and drops
# one inherited from a wrapper further up.
case "$BUDGET_S" in
  ''|*[!0-9]*|0) unset SB_HOOK_LATE_MS SB_HOOK_LATE_PID ;;
  *) export SB_HOOK_LATE_MS=$(( T0 + BUDGET_S * 1000 - 2000 )) SB_HOOK_LATE_PID=$$ ;;
esac
# Watchdog (audit H7): the CLI SIGKILLs a hook at its budget and this wrapper dies with it, writing no
# row while the child runs on. So the child runs in the background and a watchdog fires 0.3 s early
# (a whole second cost the 5 s PreToolUse guards a fifth of their budget, so more of them failed open
# under load; GNU, BSD and MSYS sleep all take the fraction): it flags the timeout, TERMs the child and
# the child's direct children (a node under the hook script survives a bare kill, MSYS included), and
# KILLs them 0.2 s later, so the row is written before the CLI's own kill at the budget. shortcut:
# grandchildren deeper than that are not reached; switch to a process group (set -m) if one is ever
# seen surviving.
# Stdin passes through (<&0); the watchdog's fds are detached so an orphaned sleep cannot hold a
# caller's output pipe open.
bash "$SCRIPT" "$@" <&0 &
CHILD=$!
WD=""
TO_FLAG="$BRAIN_DIR/.hook-timer-$$.timeout"
case "$BUDGET_S" in
  ''|*[!0-9]*|0|1) : ;;
  *)
    ( sleep "$(( BUDGET_S - 1 )).7"
      kill -0 "$CHILD" 2>/dev/null || exit 0
      : > "$TO_FLAG"
      command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$CHILD" 2>/dev/null
      kill "$CHILD" 2>/dev/null
      sleep 0.2
      command -v pkill >/dev/null 2>&1 && pkill -KILL -P "$CHILD" 2>/dev/null
      kill -KILL "$CHILD" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    WD=$!
    ;;
esac
wait "$CHILD"
EC=$?
[ -n "$WD" ] && kill "$WD" 2>/dev/null
TIMEOUT=""
if [ -e "$TO_FLAG" ]; then
  TIMEOUT=',"timeout":true'; EC=124
  rm -f "$TO_FLAG" 2>/dev/null
fi
_now_ms; T1=$_MS

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
      # late: the hook was still running when the CLI may already have cancelled it (see above).
      [ -n "${SB_HOOK_LATE_MS:-}" ] && [ "$T1" -ge "$SB_HOOK_LATE_MS" ] && WARN="$WARN"',"late":true'
      ;;
  esac
  # plugin_version: which hook code wrote the row (two installed versions' sessions coexist; a stale
  # hook's rows looked like a regression). Read beside the script, builtins only.
  PV="" PJ=""
  IFS= read -r -d '' -n 8192 PJ < "${SCRIPT%/*}/../.claude-plugin/plugin.json"
  [[ $PJ =~ \"version\"[[:space:]]*:[[:space:]]*\"([0-9A-Za-z.+-]{1,32})\" ]] && PV=',"plugin_version":"'"${BASH_REMATCH[1]}"'"'
  HOOK="${SCRIPT##*/}"
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC0 printf -v TS '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi
  printf '{"ts":"%s","kind":"latency","hook":"%s","duration_ms":%s,"exit_code":%s%s%s%s}\n' \
    "$TS" "$HOOK" "$DUR" "$EC" "$WARN" "$PV" "$TIMEOUT" >> "$BRAIN_DIR/audit-log.jsonl"
} 2>/dev/null || true

exit "$EC"
