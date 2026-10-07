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
# by at most its own start-up. A window of [3000, 3000 + 1999] around g_t0 fails a margin of 4000
# (1000 + start-up) and one of 0 (5000 + start-up); the source lock below pins the formula itself.
if [ -n "$g_t0" ]; then
  g_d=$(( g_late - 10#${g_t0//[!0-9]/} / 1000 ))
  [ "$g_d" -ge 3000 ] && [ "$g_d" -le 4999 ] \
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
printf '%s' "$LINE" | jq -e '.plugin_version == "9.8.7-rc.1" and (has("late") | not)' >/dev/null \
  || fail "(g) an on-time row names the plugin version and is not late: $LINE"
: > "$AUD"
printf '' | bash "$TIMER" 1 "$PLUG/scripts/slow.sh" >/dev/null 2>&1
LINE=$(grep '"kind":"latency"' "$AUD" | tail -1)
printf '%s' "$LINE" | jq -e '.late == true' >/dev/null \
  || fail "(g) a 1 s child against a 1 s budget ends past the deadline: the row must say late: $LINE"
: > "$AUD"
printf '' | bash "$TIMER" 60 "$CHILD" >/dev/null 2>&1
LINE=$(grep '"kind":"latency"' "$AUD" | tail -1)
printf '%s' "$LINE" | jq -e '(has("plugin_version") | not) and (has("late") | not)' >/dev/null \
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

echo "ALL PASS"
