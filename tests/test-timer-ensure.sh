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

# Stub the schedulers so --apply touches no real host state. systemctl/launchctl are dumb
# no-ops (the systemd/launchd "installed" signal is the unit FILE, not a live query). schtasks
# is STATEFUL — windows has no file artifact, so sb_timer_installed queries it; the stub records
# /Create in a marker, answers /Query from that marker, and clears it on /Delete.
mkdir -p "$SANDBOX/stubs"
for t in systemctl launchctl; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/stubs/$t"; chmod +x "$SANDBOX/stubs/$t"
done
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

# --- Task 4: the setup skill wires the autonomous --ensure install + documents the opt-out ---
SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/setup/SKILL.md"
grep -qE 'install-extract-timer\.sh" --ensure' "$SKILL" && ok "setup: autonomously invokes install-extract-timer.sh --ensure" || no "setup: missing autonomous --ensure call"
grep -q 'SB_DISABLE_AUTO_TIMER' "$SKILL" && ok "setup: documents the SB_DISABLE_AUTO_TIMER opt-out" || no "setup: missing SB_DISABLE_AUTO_TIMER opt-out"
# The autonomous default must be the HARDENED unit — setup must NOT auto-pass --oauth (creds stay manual).
grep -qE 'install-extract-timer\.sh" --ensure[^\n]*--oauth' "$SKILL" && no "setup: --ensure must NOT auto-grant --oauth creds" || ok "setup: --ensure stays hardened (no auto --oauth)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
