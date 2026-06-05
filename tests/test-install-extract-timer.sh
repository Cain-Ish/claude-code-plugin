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

# Test 4 (U3): hardened default unit grants brain + knowledge, NOT ~/.claude
HARD="$SCRIPT_DIR/../systemd/sb-extract-drain.service"
grep -q 'ReadWritePaths=.*%h/.second-brain' "$HARD" && ok "hardened: brain writable" || no "hardened: brain writable"
grep -q 'ReadWritePaths=.*%h/knowledge' "$HARD"      && ok "hardened: knowledge writable (wiki)" || no "hardened: knowledge writable"
grep -q '%h/.claude' "$HARD" && no "hardened must NOT grant ~/.claude" || ok "hardened: no creds grant"

# Test 5 (U3): OAuth variant exists and grants ~/.claude
OAUTH="$SCRIPT_DIR/../systemd/sb-extract-drain-oauth.service"
{ [ -f "$OAUTH" ] && grep -q '%h/.claude' "$OAUTH"; } && ok "oauth variant grants ~/.claude" || no "oauth variant missing/no creds grant"
{ [ -f "$OAUTH" ] && grep -q 'ReadWritePaths=.*%h/knowledge' "$OAUTH"; } && ok "oauth variant also writes knowledge" || no "oauth variant knowledge grant"

# Test 6 (U4): installer default print = hardened (no creds); --oauth print = creds + announced grant
DOUT=$(bash "$INSTALL" 2>&1 || true)
printf '%s' "$DOUT" | grep -q '%h/.claude' && no "default print leaked creds grant" || ok "default print = hardened (no creds)"
OOUT=$(bash "$INSTALL" --oauth 2>&1 || true)
printf '%s' "$OOUT" | grep -q '%h/.claude' && ok "--oauth print renders creds grant" || no "--oauth print missing creds grant"
printf '%s' "$OOUT" | grep -qiE 'grant|NOTE' && ok "--oauth announces the grant" || no "--oauth announces the grant"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
