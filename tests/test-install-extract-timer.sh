#!/bin/bash
# Tests for install-extract-timer.sh (print mode — never touches real systemd)
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
INSTALL="$SCRIPT_DIR/install-extract-timer.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export XDG_CONFIG_HOME="$SANDBOX/config"   # redirect systemd user dir into sandbox

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== install-extract-timer.sh tests ==="

# Test 1: default (print) mode emits both units and touches nothing
OUT=$(bash "$INSTALL" 2>&1 || true)
printf '%s' "$OUT" | grep -q 'sb-extract-drain.service' && ok "prints .service" || no "prints .service"
printf '%s' "$OUT" | grep -q 'OnUnitActiveSec=30min'     && ok "prints .timer body" || no "prints .timer body"
printf '%s' "$OUT" | grep -q 'extract-drain.sh'          && ok "ExecStart resolved to drainer path" || no "ExecStart resolved"
printf '%s' "$OUT" | grep -q 'enable-linger'             && ok "surfaces linger command" || no "surfaces linger command"
[ ! -e "$XDG_CONFIG_HOME/systemd/user/sb-extract-drain.timer" ] \
  && ok "print mode writes nothing" || no "print mode writes nothing"

# Test 2: no ACTIVE PrivateDevices= directive (a warning comment mentioning it is fine)
printf '%s' "$OUT" | grep -qE '^[[:space:]]*PrivateDevices=' && no "must NOT set PrivateDevices directive" || ok "no active PrivateDevices directive"

# Test 3: rendered service has no unresolved @EXEC@ token
printf '%s' "$OUT" | grep -q '@EXEC@' && no "ExecStart still has @EXEC@ token" || ok "ExecStart token substituted"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
