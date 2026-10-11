#!/bin/bash
# Tests for install-extract-timer.sh --ensure (idempotent install-if-needed) and the
# sb_timer_installed / sb_timer_health lib helpers (P1 Task 3). Confined to a sandbox:
# HOME / BRAIN_DIR / XDG_CONFIG_HOME are redirected and the system schedulers are stubbed
# on PATH so --apply is inert. Exercises each OS branch via SB_INSTALL_OS_OVERRIDE.
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
INSTALL="$SCRIPT_DIR/install-extract-timer.sh"
LIB="$SCRIPT_DIR/lib.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Stub the schedulers so --apply touches no real host state. sb_timer_installed asks the live
# scheduler once the unit/plist file is there: systemctl answers `is-enabled` per SB_STUB_SYSTEMCTL
# (enabled | disabled | nobus — real systemd prints a state word whenever the user bus answers, and
# nothing on stdout when it cannot be reached); launchctl answers `print` per SB_STUB_LAUNCHCTL
# (loaded | unloaded: the gui domain answers, the service does not | nodomain). Every other call is
# a no-op success. schtasks is STATEFUL — windows has no file artifact, so sb_timer_installed
# queries it; the stub records /Create in a marker, answers /Query from that marker, and clears it
# on /Delete.
mkdir -p "$SANDBOX/stubs"
cat > "$SANDBOX/stubs/systemctl" <<'STUB'
#!/bin/sh
case "$*" in *is-enabled*)
  case "${SB_STUB_SYSTEMCTL:-enabled}" in
    enabled)  echo enabled; exit 0 ;;
    disabled) echo disabled; exit 1 ;;
    nobus)    echo "Failed to connect to user scope bus via local transport" >&2; exit 1 ;;
  esac ;;
esac
exit 0
STUB
cat > "$SANDBOX/stubs/launchctl" <<'STUB'
#!/bin/sh
[ "$1" = print ] || exit 0
case "${SB_STUB_LAUNCHCTL:-loaded}" in
  loaded)   exit 0 ;;
  unloaded) case "$2" in */*/*) exit 113 ;; *) exit 0 ;; esac ;;
  nodomain) exit 112 ;;
esac
STUB
chmod +x "$SANDBOX/stubs/systemctl" "$SANDBOX/stubs/launchctl"
cat > "$SANDBOX/stubs/schtasks" <<'STUB'
#!/bin/sh
M="${SB_SCHTASKS_STATE:-$SANDBOX/schtask.marker}"
case "$1" in
  /Create) : > "$M"; exit 0 ;;
  /Query)  [ -f "$M" ] && exit 0 || exit 1 ;;
  /Delete) rm -f "$M"; exit 0 ;;
  *)       exit 0 ;;
esac
STUB
chmod +x "$SANDBOX/stubs/schtasks"
export PATH="$SANDBOX/stubs:$PATH"

echo "=== install-extract-timer.sh --ensure tests ==="

# --- linux/systemd: absent -> --ensure installs -> 2nd --ensure is an idempotent no-op ---
LX="$SANDBOX/lx"; mkdir -p "$LX"
run_lx() { XDG_CONFIG_HOME="$LX/config" BRAIN_DIR="$LX/brain" HOME="$LX/home" \
           SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" "$@" 2>&1; }
UNIT="$LX/config/systemd/user/sb-extract-drain.timer"
[ ! -e "$UNIT" ] && ok "precondition: systemd timer unit absent" || no "precondition: unit already present"
O1=$(run_lx --ensure || true)
[ -f "$UNIT" ] && ok "ensure(systemd): installs the timer unit when absent" || no "ensure(systemd): did not install unit (got: $O1)"
O2=$(run_lx --ensure || true)
printf '%s' "$O2" | grep -qi 'already installed' && ok "ensure(systemd): idempotent (no-op + 'already installed' on 2nd call)" || no "ensure(systemd): not idempotent (got: $O2)"

# --- macOS/launchd: absent -> install -> idempotent ---
MAC="$SANDBOX/mac"; mkdir -p "$MAC"
run_mac() { BRAIN_DIR="$MAC/brain" HOME="$MAC/home" \
            SB_INSTALL_OS_OVERRIDE=launchd bash "$INSTALL" "$@" 2>&1; }
PLIST="$MAC/home/Library/LaunchAgents/sb-extract-drain.plist"
M1=$(run_mac --ensure || true)
[ -f "$PLIST" ] && ok "ensure(launchd): installs the LaunchAgent plist when absent" || no "ensure(launchd): no plist (got: $M1)"
M2=$(run_mac --ensure || true)
printf '%s' "$M2" | grep -qi 'already installed' && ok "ensure(launchd): idempotent" || no "ensure(launchd): not idempotent (got: $M2)"

# --- windows/schtasks: absent -> register -> idempotent (stateful stub) ---
WIN="$SANDBOX/win"; mkdir -p "$WIN"
export SB_SCHTASKS_STATE="$WIN/schtask.marker"
run_win() { BRAIN_DIR="$WIN/brain" HOME="$WIN/home" \
            SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" "$@" 2>&1; }
W1=$(run_win --ensure || true)
[ -f "$SB_SCHTASKS_STATE" ] && ok "ensure(windows): registers the scheduled task when absent" || no "ensure(windows): task not registered (got: $W1)"
W2=$(run_win --ensure || true)
printf '%s' "$W2" | grep -qi 'already installed' && ok "ensure(windows): idempotent" || no "ensure(windows): not idempotent (got: $W2)"
unset SB_SCHTASKS_STATE

# --- direct helper contract: sb_timer_health reflects state ---
ABS=$(HOME="$SANDBOX/empty-home" XDG_CONFIG_HOME="$SANDBOX/empty-cfg" BRAIN_DIR="$SANDBOX/empty-brain" \
      bash -c ". \"$LIB\"; sb_timer_health systemd")
[ "$ABS" = absent ] && ok "sb_timer_health: 'absent' when no unit present" || no "sb_timer_health: expected 'absent', got '$ABS'"
INS=$(XDG_CONFIG_HOME="$LX/config" HOME="$LX/home" BRAIN_DIR="$LX/brain" \
      bash -c ". \"$LIB\"; sb_timer_health systemd")
[ "$INS" = installed ] && ok "sb_timer_health: 'installed' after ensure ran" || no "sb_timer_health: expected 'installed', got '$INS'"

# Regression (live-found): a registration present but the SHIM missing — e.g. a stale task left by an
# old version whose shim was GC'd — must read as 'absent' so --ensure / the session-load self-heal
# re-applies and regenerates it, instead of a false 'installed' that leaves the scheduler execing a
# non-existent shim and failing silently every fire.
SHX="$SANDBOX/shimless"; mkdir -p "$SHX/config/systemd/user"
: > "$SHX/config/systemd/user/sb-extract-drain.timer"   # unit present, but NO $SHX/brain/bin/sb-extract-drain.sh
SHL=$(XDG_CONFIG_HOME="$SHX/config" HOME="$SHX/home" BRAIN_DIR="$SHX/brain" \
      bash -c ". \"$LIB\"; sb_timer_health systemd")
[ "$SHL" = absent ] && ok "sb_timer_health: unit present but shim missing → 'absent' (repairable)" || no "sb_timer_health: shim-less state wrongly '$SHL'"
# And once the shim exists alongside the unit → 'installed'.
mkdir -p "$SHX/brain/bin"; : > "$SHX/brain/bin/sb-extract-drain.sh"
SHL2=$(XDG_CONFIG_HOME="$SHX/config" HOME="$SHX/home" BRAIN_DIR="$SHX/brain" \
       bash -c ". \"$LIB\"; sb_timer_health systemd")
[ "$SHL2" = installed ] && ok "sb_timer_health: unit + shim both present → 'installed'" || no "sb_timer_health: unit+shim wrongly '$SHL2'"

# Residual (2026-10-11): the unit/plist FILE alone read a disabled timer / an unloaded agent as
# installed, so --ensure never healed it. With the scheduler reachable, its own answer decides;
# unreachable (no user bus, a container, WSL without systemd, no gui domain) the file stands — a
# re-apply could not be verified either, so 'absent' would re-run --ensure on every session —
# and one error-log row (not one per session) says the state could not be verified.
th() {  # th <os> <config-root> <brain> -> sb_timer_health's answer
  XDG_CONFIG_HOME="$2/config" HOME="$2/home" BRAIN_DIR="$3" bash -c ". \"$LIB\"; sb_timer_health $1"
}
unver_rows() { if [ -f "$1/error-log.jsonl" ]; then grep -c 'cannot be verified' "$1/error-log.jsonl" || true; else echo 0; fi; }
LB="$SANDBOX/lb"; mkdir -p "$LB/bin"; : > "$LB/bin/sb-extract-drain.sh"
H=$(SB_STUB_SYSTEMCTL=disabled th systemd "$LX" "$LB")
[ "$H" = absent ] && ok "systemd: unit file present but timer disabled → 'absent' (--ensure re-enables it)" || no "systemd: disabled timer wrongly '$H'"
H=$(SB_STUB_SYSTEMCTL=enabled th systemd "$LX" "$LB")
[ "$H" = installed ] && [ "$(unver_rows "$LB")" = 0 ] && ok "systemd: enabled timer → 'installed', nothing logged" || no "systemd: enabled timer → '$H', rows $(unver_rows "$LB")"
H=$(SB_STUB_SYSTEMCTL=nobus th systemd "$LX" "$LB"); H2=$(SB_STUB_SYSTEMCTL=nobus th systemd "$LX" "$LB")
[ "$H" = installed ] && [ "$H2" = installed ] && ok "systemd: no user bus → 'installed' (no re-apply loop)" || no "systemd: no user bus → '$H'/'$H2'"
[ "$(unver_rows "$LB")" = 1 ] && ok "systemd: no user bus → exactly one error-log row across two calls" || no "systemd: no user bus logged $(unver_rows "$LB") rows (want 1)"
O3=$(SB_STUB_SYSTEMCTL=disabled run_lx --ensure || true)
printf '%s' "$O3" | grep -q '^applied' && ok "ensure(systemd): a disabled timer is re-applied" || no "ensure(systemd): disabled timer not re-applied (got: $O3)"
O4=$(SB_STUB_SYSTEMCTL=nobus run_lx --ensure || true)
printf '%s' "$O4" | grep -qi 'already installed' && ok "ensure(systemd): no user bus → no re-apply" || no "ensure(systemd): no user bus re-applied (got: $O4)"
MB="$SANDBOX/mb"; mkdir -p "$MB/bin"; : > "$MB/bin/sb-extract-drain.sh"
H=$(SB_STUB_LAUNCHCTL=unloaded th launchd "$MAC" "$MB")
[ "$H" = absent ] && ok "launchd: plist present but agent not loaded → 'absent'" || no "launchd: unloaded agent wrongly '$H'"
H=$(SB_STUB_LAUNCHCTL=loaded th launchd "$MAC" "$MB")
[ "$H" = installed ] && [ "$(unver_rows "$MB")" = 0 ] && ok "launchd: loaded agent → 'installed', nothing logged" || no "launchd: loaded agent → '$H', rows $(unver_rows "$MB")"
H=$(SB_STUB_LAUNCHCTL=nodomain th launchd "$MAC" "$MB"); H2=$(SB_STUB_LAUNCHCTL=nodomain th launchd "$MAC" "$MB")
[ "$H" = installed ] && [ "$H2" = installed ] && [ "$(unver_rows "$MB")" = 1 ] \
  && ok "launchd: no gui domain → 'installed' + exactly one error-log row" || no "launchd: no gui domain → '$H'/'$H2', rows $(unver_rows "$MB")"

# --- Task 4: the setup skill wires the autonomous --ensure install + documents the opt-out ---
SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/setup/SKILL.md"
grep -qE 'install-extract-timer\.sh" --ensure' "$SKILL" && ok "setup: autonomously invokes install-extract-timer.sh --ensure" || no "setup: missing autonomous --ensure call"
grep -q 'SB_DISABLE_AUTO_TIMER' "$SKILL" && ok "setup: documents the SB_DISABLE_AUTO_TIMER opt-out" || no "setup: missing SB_DISABLE_AUTO_TIMER opt-out"
# The autonomous default must be the HARDENED unit — setup must NOT auto-pass --oauth (creds stay manual).
grep -qE 'install-extract-timer\.sh" --ensure[^\n]*--oauth' "$SKILL" && no "setup: --ensure must NOT auto-grant --oauth creds" || ok "setup: --ensure stays hardened (no auto --oauth)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
