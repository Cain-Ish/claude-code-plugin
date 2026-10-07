#!/usr/bin/env bash
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
# The child prints the deadline and its own clock: deadline - now = 3000 ms less the child's start-up,
# so it is at most 3000 (a larger margin, or none, lands past that) and at least 3000 - 6000.
printf '#!/bin/bash\nn="${EPOCHREALTIME:-}"; printf "%%s %%s" "${SB_HOOK_LATE_MS:-unset}" "${n//[!0-9]/}"\n' > "$PLUG/scripts/deadline.sh"
printf '#!/bin/bash\nsleep 1\n' > "$PLUG/scripts/slow.sh"
: > "$AUD"
OUT=$(printf '' | bash "$TIMER" 5 "$PLUG/scripts/deadline.sh" 2>/dev/null)
g_late="${OUT%% *}" g_now="${OUT#* }"
case "$g_late" in ''|unset|*[!0-9]*) fail "(g) the child must get a numeric SB_HOOK_LATE_MS (got: '$OUT')" ;; esac
if [ -n "$g_now" ] && [ "$g_now" != "$OUT" ]; then
  g_left=$(( g_late - 10#$g_now / 1000 ))
  [ "$g_left" -le 3000 ] && [ "$g_left" -ge -3000 ] \
    || fail "(g) SB_HOOK_LATE_MS must be the wrapper's start + 5000 - 2000 ms: the child, just started, saw ${g_left} ms left (want 3000 less its start-up)"
fi
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

echo "ALL PASS"
