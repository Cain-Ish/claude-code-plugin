#!/usr/bin/env bash
# pins: SB_HOOK_LATE_MS — (h)/(g): a past deadline (1) handed to sb_log_audit and to the skip arm is the subject — late stamping and its unset
# pins: SB_HOOK_LATE_PID — (h)/(g): which process the deadline belongs to is the subject (GT11: the direct child only)
# R7 hook latency telemetry: scripts/hook-timer.sh wraps heavy hook commands
# (hooks.json: bash hook-timer.sh <budget_s> <script> [args…]) and appends
# {kind:"latency", hook, duration_ms, exit_code} to audit-log.jsonl — the R1
# ec=124 timeout class was only diagnosable by forensic log mining; this makes
# per-hook latency a first-class, queryable signal. The wrapper must be
# TRANSPARENT: child stdin/stdout/stderr and exit code pass through untouched,
# and a timer failure (unwritable audit log) must never break the child.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TIMER="$REPO_ROOT/scripts/hook-timer.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$TIMER" ] || fail "scripts/hook-timer.sh does not exist"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"
AUD="$BRAIN_DIR/audit-log.jsonl"

# Child fixture: echoes stdin, writes stderr, exits with requested code.
CHILD="$SANDBOX/child.sh"
cat > "$CHILD" <<'EOF'
#!/bin/bash
IN=$(cat)
echo "child-stdout:$IN"
echo "child-stderr" >&2
exit "${CHILD_RC:-0}"
EOF
chmod +x "$CHILD"

# --- (a) transparency: stdin/stdout/stderr/rc pass through ------------------
OUT=$(printf 'payload-123' | bash "$TIMER" 60 "$CHILD" 2>"$SANDBOX/err"); rc=$?
[ "$rc" -eq 0 ] || fail "(a) rc not passed through (got $rc)"
[ "$OUT" = "child-stdout:payload-123" ] || fail "(a) stdout altered: $OUT"
grep -q 'child-stderr' "$SANDBOX/err" || fail "(a) stderr swallowed"
# SIL-R7: nothing of the wrapper's own (bash 3.2 printed a "Terminated" notice for the stopped watchdog)
[ "$(cat "$SANDBOX/err")" = "child-stderr" ] || fail "(a) the wrapper added to the child's stderr: $(cat "$SANDBOX/err")"
pass "(a) wrapper is transparent (stdin/stdout/stderr/rc)"

# --- (b) nonzero child rc passes through ------------------------------------
printf 'x' | CHILD_RC=3 bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "(b) child rc=3 not propagated (got $rc)"
pass "(b) nonzero exit code propagates"

# --- (c) latency line lands in audit-log with sane fields -------------------
LINE=$(grep '"kind":"latency"' "$AUD" | head -1)
[ -n "$LINE" ] || fail "(c) no latency line in audit-log: $(cat "$AUD" 2>/dev/null)"
[ -n "$LINE" ] && echo "$LINE" | jq -e '.hook == "child.sh" and (.duration_ms | type == "number") and .duration_ms >= 0 and .duration_ms < 60000' >/dev/null \
  || fail "(c) latency line malformed: $LINE"
pass "(c) latency line: hook + numeric duration_ms"

# --- (d) budget warning at >70% of the budget -------------------------------
SLOW="$SANDBOX/slow.sh"; printf '#!/bin/bash\nsleep 1\n' > "$SLOW"; chmod +x "$SLOW"
: > "$AUD"
printf '' | bash "$TIMER" 1 "$SLOW" >/dev/null 2>&1
grep -q '"budget_warn":true' "$AUD" \
  || fail "(d) 1s child against a 1s budget must set budget_warn: $(cat "$AUD")"
pass "(d) >70%-of-budget run flags budget_warn"

# --- (e) fast run does NOT warn ---------------------------------------------
: > "$AUD"
printf '' | bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1
grep -q '"budget_warn":true' "$AUD" && fail "(e) fast child wrongly flagged"
pass "(e) fast run carries no budget_warn"

# --- (f) unwritable audit log never breaks the child ------------------------
OUT=$(printf 'p' | BRAIN_DIR=/nonexistent_dir_zz9 bash "$TIMER" 60 "$CHILD" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "child-stdout:p" ] || fail "(f) timer failure broke the child (rc=$rc out=$OUT)"
pass "(f) fail-open: unwritable audit log, child unaffected"

# --- (g) G2 (R3, 2026-10-07): late verdicts and the hook version ------------
# A guard verdict written after Claude Code cancelled the hook was enforced by no one, yet counted
# as one. The wrapper hands its children SB_HOOK_LATE_MS (its start + budget - 2000 ms: the CLI's
# clock starts 70-2000 ms before this wrapper does), marks its own row late past it, and names the
# plugin version the hook came from (two installed versions' sessions write one log).
PLUG="$SANDBOX/plug"; mkdir -p "$PLUG/scripts" "$PLUG/.claude-plugin"
printf '{\n  "name": "second-brain",\n  "version": "9.8.7-rc.1"\n}\n' > "$PLUG/.claude-plugin/plugin.json"
# The child prints the deadline, the wrapper PID it was handed, and its own parent's PID (GT11, R3B:
# a guard honours the deadline only as hook-timer's direct child — one inherited through a claude -p
# the hook spawned is not its own).
printf '#!/bin/bash\nprintf "%%s %%s %%s" "${SB_HOOK_LATE_MS:-unset}" "${SB_HOOK_LATE_PID:-unset}" "$PPID"\n' > "$PLUG/scripts/deadline.sh"
printf '#!/bin/bash\nsleep 1\n' > "$PLUG/scripts/slow.sh"
: > "$AUD"
g_t0="${EPOCHREALTIME:-}"
OUT=$(printf '' | bash "$TIMER" 5 "$PLUG/scripts/deadline.sh" 2>/dev/null)
read -r g_late g_pid g_ppid <<< "$OUT"   # <<<-bounded: three short fields
case "$g_late" in ''|unset|*[!0-9]*) fail "(g) the child must get a numeric SB_HOOK_LATE_MS (got: '$OUT')" ;; esac
[ "$g_pid" = "$g_ppid" ] || fail "(g) SB_HOOK_LATE_PID must name the wrapper, the child's parent (got: '$OUT')"
# GT2 (R3B): the deadline is the wrapper's start + 5000 - 2000 ms, and the wrapper starts after g_t0 —
# by at most its own start-up. The window [3000, 3000 + 3999] around g_t0 fails a margin of 4000
# (1000 + start-up) and lets the wrapper take up to 4 s to start: P-Q7, a loaded MSYS box spends
# seconds on a bash spawn, and the old 1999 ms of headroom failed a correct deadline there. The source
# lock below pins the formula itself (a margin of 0 lands inside the widened window).
if [ -n "$g_t0" ]; then
  g_d=$(( g_late - 10#${g_t0//[!0-9]/} / 1000 ))
  [ "$g_d" -ge 3000 ] && [ "$g_d" -le 6999 ] \
    || fail "(g) SB_HOOK_LATE_MS must be hook-timer's start + 5000 - 2000 ms: it came ${g_d} ms after the launch (want 3000 plus the wrapper's start-up)"
else
  echo "SKIP: (g) deadline window — no EPOCHREALTIME (bash < 5)"
fi
grep -qF 'export SB_HOOK_LATE_MS=$(( T0 + BUDGET_S * 1000 - 2000 ))' "$TIMER" \
  || fail "(g) source lock: the deadline is T0 + BUDGET_S * 1000 - 2000 (the 2000 ms CLI head start)"
# The skip arm (budget 0) hands no deadline on — an inherited one included.
OUT=$(printf '' | SB_HOOK_LATE_MS=1 SB_HOOK_LATE_PID=1 bash "$TIMER" 0 "$PLUG/scripts/deadline.sh" 2>/dev/null)
case "$OUT" in "unset unset "*) ;; *) fail "(g) budget 0 must unset an inherited SB_HOOK_LATE_MS/SB_HOOK_LATE_PID (child saw: '$OUT')" ;; esac
LINE=$(grep '"kind":"latency"' "$AUD" | tail -1)
[ -n "$LINE" ] && printf '%s' "$LINE" | jq -e '.plugin_version == "9.8.7-rc.1" and (has("late") | not)' >/dev/null \
  || fail "(g) an on-time row names the plugin version and is not late: $LINE"
: > "$AUD"
printf '' | bash "$TIMER" 1 "$PLUG/scripts/slow.sh" >/dev/null 2>&1
LINE=$(grep '"kind":"latency"' "$AUD" | tail -1)
[ -n "$LINE" ] && printf '%s' "$LINE" | jq -e '.late == true' >/dev/null \
  || fail "(g) a 1 s child against a 1 s budget ends past the deadline: the row must say late: $LINE"
: > "$AUD"
printf '' | bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1
LINE=$(grep '"kind":"latency"' "$AUD" | tail -1)
[ -n "$LINE" ] && printf '%s' "$LINE" | jq -e '(has("plugin_version") | not) and (has("late") | not)' >/dev/null \
  || fail "(g) a script with no plugin.json beside it gets no version, and a fast one no late flag: $LINE"
pass "(g) deadline handed to the child; latency row: plugin_version, late past the deadline"

# --- (h) sb_log_audit honours the deadline as hook-timer's direct child only (GT11) and keeps a
# caller's late flag without jq (GX8, R3B: the printf fallback dropped extra) -----------------------
LIB="$REPO_ROOT/scripts/lib.sh"
if [ -n "${EPOCHREALTIME:-}" ]; then
  : > "$AUD"
  # A past deadline handed to this shell's child (PPID = $$): late.
  BRAIN_DIR="$BRAIN_DIR" SB_HOOK_LATE_MS=1 SB_HOOK_LATE_PID=$$ bash -c 'source "$1"; sb_log_audit h-test ask r1 t "why" s1' _ "$LIB"
  # The same deadline handed to another process: not this one's.
  BRAIN_DIR="$BRAIN_DIR" SB_HOOK_LATE_MS=1 SB_HOOK_LATE_PID=1 bash -c 'source "$1"; sb_log_audit h-test ask r2 t "why" s1' _ "$LIB"
  grep '"rule":"r1"' "$AUD" | grep -q '"late":true' || fail "(h) a past deadline for this process must stamp late: $(cat "$AUD")"
  grep '"rule":"r2"' "$AUD" | grep -q '"late":true' && fail "(h) a deadline handed to another process must not stamp late: $(cat "$AUD")"
else
  echo "SKIP: (h) sb_log_audit deadline — no EPOCHREALTIME (bash < 5)"
fi
H_NJ="$SANDBOX/nojq"; mkdir -p "$H_NJ"
for t in date mkdir tr sed cat head dirname basename uname grep; do
  h_p=$(command -v "$t") || continue
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$h_p" > "$H_NJ/$t"; chmod +x "$H_NJ/$t"
done
: > "$AUD"
PATH="$H_NJ" BRAIN_DIR="$BRAIN_DIR" "$BASH" -c 'source "$1" 2>/dev/null; command -v jq >/dev/null && exit 3; sb_log_audit h-test ask r3 t "why" s1 "{\"late\":true}"' _ "$LIB"; h_rc=$?
[ "$h_rc" = 3 ] && fail "(h) precondition: jq must be off the shim PATH"
grep '"rule":"r3"' "$AUD" | grep -q '"late":true' \
  || fail "(h) GX8: without jq, the caller's extra late flag must reach the row: $(cat "$AUD")"
pass "(h) sb_log_audit: the deadline is the direct child's only; a caller's late flag survives a missing jq"

# --- (i)-(l) audit H7 watchdog. The CLI kills a hook at its budget and the wrapper dies with it,
# writing no row. A watchdog sleeps the WHOLE budget (the CLI's clock starts first, so it has given
# up by then) and, if the hook still runs, writes the timeout row itself. Under a short budget
# (< 10 s: the PreToolUse guards) it also reaps the hook's process group, grandchildren included (no
# pkill on git-bash); a heavy hook (>= 10 s) is never killed and finishes its side effects. The
# wrapper maps to 124 only a child the watchdog killed, and keeps no state between runs (review
# SEC-R6, IMP-R1/R2/R8, SIL-R1/R3/R7, TST-R3, PORT-R1).
# hang.sh leaves a grandchild: a kill that stops at the direct child misses it. heavy.sh outlives a
# 10 s budget, then does its side effect and exits 3 (its own code, not the wrapper's).
HANG="$SANDBOX/hang.sh"
printf '#!/bin/bash\ncat >/dev/null\nsleep 30 &\necho $! > "$1"\nwait\n' > "$HANG"; chmod +x "$HANG"
HEAVY="$SANDBOX/heavy.sh"
printf '#!/bin/bash\ncat >/dev/null\nsleep 11\n: > "$1"\nexit 3\n' > "$HEAVY"; chmod +x "$HEAVY"
# ms_clock: the rows' duration is the wrapper's own clock — ms-precise with bash 5's EPOCHREALTIME or
# GNU date %N; a whole-second clock can read 3.0 s as 2000 ms, so duration bounds are skipped there.
ms_clock=""
if [ -n "$(bash -c 'printf %s "${EPOCHREALTIME:-}"')" ] || [[ $(date +%s%N) =~ ^[0-9]+$ ]]; then ms_clock=1; fi
row_ms() { printf '%s' "$1" | sed 's/.*"duration_ms":\([0-9]*\).*/\1/'; }
# cli_run <brain> <budget> <kill_at> <script> [args…]: the wrapper as Claude Code runs it — SIGKILLed
# before its own budget (the CLI's clock started first), so only the watchdog is left to act.
cli_run() {
  local b=$1 budget=$2 k=$3 w; shift 3
  printf 'in' | BRAIN_DIR="$b" bash "$TIMER" "$budget" "$@" >/dev/null 2>&1 &
  w=$!; sleep "$k"; kill -KILL "$w" 2>/dev/null
}
# The 10-11 s cases run in the background while (i)-(k) run; (l) collects them.
mkdir -p "$SANDBOX/l1" "$SANDBOX/l2" "$SANDBOX/i2"
( printf 'in' | BRAIN_DIR="$SANDBOX/l1" bash "$TIMER" 10 "$HEAVY" "$SANDBOX/l1/done" >/dev/null 2>&1
  echo $? > "$SANDBOX/l1/rc" ) &
L1=$!
cli_run "$SANDBOX/l2" 10 8 "$HEAVY" "$SANDBOX/l2/done" &
L2=$!
cli_run "$SANDBOX/i2" 3 2 "$HANG" "$SANDBOX/i2/gc.pid" &
I2=$!

# --- (i) a short-budget hook still running at its budget: reaped with its grandchild, exit 124, one row
: > "$AUD"
i_t0=$SECONDS
printf 'in' | bash "$TIMER" 3 "$HANG" "$SANDBOX/gc-i.pid" >/dev/null 2>"$SANDBOX/err-i"; i_rc=$?
i_dt=$(( SECONDS - i_t0 ))
[ "$i_dt" -le 6 ] || fail "(i) the wrapper did not cut a hung child near its budget (took ${i_dt}s)"
[ "$i_rc" -eq 124 ] || fail "(i) a child the watchdog killed must exit 124 (got $i_rc)"
i_row=$(grep '"kind":"latency"' "$AUD" | grep '"hook":"hang.sh"' | grep '"timeout":true')
[ -n "$i_row" ] || fail "(i) no timeout latency row for the killed hook: $(cat "$AUD")"
[ "$(grep -c '"kind":"latency"' "$AUD")" -eq 1 ] || fail "(i) one run, one row: $(cat "$AUD")"
if [ -n "$ms_clock" ]; then
  i_ms=$(row_ms "$i_row")
  [ "${i_ms:-0}" -ge 3000 ] || fail "(i) the watchdog cut a 3 s-budget hook at ${i_ms} ms: never before the budget (the CLI still waits on it)"
fi
grep -q 'Terminated' "$SANDBOX/err-i" && fail "(i) a job notice leaked to stderr (bash 3.2): $(cat "$SANDBOX/err-i")"
sleep 0.5
i_gc=$(cat "$SANDBOX/gc-i.pid" 2>/dev/null)
[ -n "$i_gc" ] || fail "(i) precondition: hang.sh never recorded its grandchild"
kill -0 "$i_gc" 2>/dev/null && { kill "$i_gc" 2>/dev/null; fail "(i) the hook's grandchild (sleep 30) survived the reap"; }
pass "(i) a short-budget hook past its budget: reaped with its grandchild, exit 124, one timeout row"

# --- (j) SEC-R6: a verdict printed in budget, its hook exiting just before the budget, passes through
# untouched (the old watchdog fired 0.3 s early and turned it into 124 = fail-open). The child aims at
# the wrapper's start + budget - 200 ms, read off SB_HOOK_LATE_MS (start + budget - 2000 ms).
if [ -n "$(bash -c 'printf %s "${EPOCHREALTIME:-}"')" ]; then
  VERD="$SANDBOX/verdict.sh"
  cat > "$VERD" <<'EOF'
#!/bin/bash
cat >/dev/null
echo '{"permissionDecision":"ask"}'
n=${EPOCHREALTIME//[!0-9]/}
left=$(( SB_HOOK_LATE_MS + 2000 - 200 - 10#$n / 1000 ))
[ "$left" -gt 0 ] && sleep "$(( left / 1000 )).$(printf %03d $(( left % 1000 )))"
exit 0
EOF
  chmod +x "$VERD"
  : > "$AUD"
  OUT=$(printf 'in' | bash "$TIMER" 3 "$VERD" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "(j) an in-budget verdict must keep its exit 0 (got $rc)"
  [ "$OUT" = '{"permissionDecision":"ask"}' ] || fail "(j) the verdict must pass through untouched: $OUT"
  LINE=$(grep '"kind":"latency"' "$AUD")
  [ -n "$LINE" ] && printf '%s' "$LINE" | jq -e '.exit_code == 0 and (has("timeout") | not)' >/dev/null \
    || fail "(j) an in-budget run is no timeout: $LINE"
  pass "(j) a verdict printed and exited just before the budget keeps exit 0 and its stdout"
else
  echo "SKIP: (j) in-budget edge — no EPOCHREALTIME in bash (bash < 5): the child cannot aim at the budget"
fi

# --- (k) IMP-R1: no state from an earlier run changes this one. The old wrapper read a flag file keyed
# on its PID; a reused PID turned a healthy guard into exit 124 (fail-open). Plant that artifact for
# the exact PID the wrapper will get (sh keeps its PID through exec) and check nothing changes.
: > "$AUD"
OUT=$(printf 'p' | sh -c ': > "$1/.hook-timer-$$.timeout"; exec bash "$2" 5 "$3"' _ "$BRAIN_DIR" "$TIMER" "$CHILD" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "child-stdout:p" ] || fail "(k) a stale artifact changed a healthy run (rc=$rc out=$OUT)"
LINE=$(grep '"kind":"latency"' "$AUD")
[ -n "$LINE" ] && printf '%s' "$LINE" | jq -e '.exit_code == 0 and (has("timeout") | not)' >/dev/null \
  || fail "(k) a stale artifact must not mark a healthy run timed out: $LINE"
pass "(k) a stale artifact for the same PID changes neither the exit code nor the row"

# --- (l) heavy hooks (budget >= 10 s; 10 = session-load --compact) are never killed, and the short
# budget's reap works with the wrapper dead, as in production. -------------------------------------
wait "$L1" "$L2" "$I2"
# l2's hook runs on as an orphan once its wrapper is killed: give it up to 5 s past l1's.
l_w=0
until [ -e "$SANDBOX/l2/done" ] || [ "$l_w" -ge 10 ]; do sleep 0.5; l_w=$(( l_w + 1 )); done
l_rc=$(cat "$SANDBOX/l1/rc" 2>/dev/null)
[ "$l_rc" = 3 ] || fail "(l) a heavy hook that finishes after its budget keeps its own exit code (want 3, got '$l_rc')"
for l in l1 l2; do
  [ -e "$SANDBOX/$l/done" ] || fail "(l) $l: the heavy hook was killed before its side effect"
  l_rows=$(grep -c '"kind":"latency"' "$SANDBOX/$l/audit-log.jsonl" 2>/dev/null)
  [ "$l_rows" = 1 ] || fail "(l) $l: one run, one row (got ${l_rows:-0}): $(cat "$SANDBOX/$l/audit-log.jsonl" 2>/dev/null)"
  LINE=$(grep '"kind":"latency"' "$SANDBOX/$l/audit-log.jsonl")
  printf '%s' "$LINE" | jq -e '.hook == "heavy.sh" and .timeout == true and .exit_code == 124' >/dev/null \
    || fail "(l) $l: the heavy hook past its budget must leave a timeout row: $LINE"
  if [ -n "$ms_clock" ]; then
    l_ms=$(row_ms "$LINE")
    [ "${l_ms:-0}" -ge 10000 ] || fail "(l) $l: the timeout row came at ${l_ms} ms, before the 10 s budget"
  fi
done
LINE=$(grep '"kind":"latency"' "$SANDBOX/i2/audit-log.jsonl" 2>/dev/null)
printf '%s' "$LINE" | jq -e '.hook == "hang.sh" and .timeout == true' >/dev/null \
  || fail "(l) i2: with the wrapper killed, the watchdog must still write the timeout row: $LINE"
i_gc=$(cat "$SANDBOX/i2/gc.pid" 2>/dev/null)
[ -n "$i_gc" ] || fail "(l) i2 precondition: hang.sh never recorded its grandchild"
kill -0 "$i_gc" 2>/dev/null && { kill "$i_gc" 2>/dev/null; fail "(l) i2: with the wrapper killed, the short-budget hook's grandchild survived"; }
pass "(l) heavy hooks finish past their budget with one timeout row (wrapper alive or killed); a killed wrapper's guard is still reaped"

echo "ALL PASS"
