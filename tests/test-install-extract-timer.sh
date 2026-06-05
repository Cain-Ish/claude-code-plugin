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

# Test 7 (SP-4): launchd (macOS) rendering, forced via SB_INSTALL_OS_OVERRIDE.
LA=$(SB_INSTALL_OS_OVERRIDE=launchd bash "$INSTALL" 2>&1)
printf '%s' "$LA" | grep -q '<plist' && ok "launchd: renders a plist" || no "launchd: no plist"
{ printf '%s' "$LA" | grep -q 'StartInterval' && printf '%s' "$LA" | grep -q 'RunAtLoad'; } && ok "launchd: StartInterval + RunAtLoad" || no "launchd: interval/runatload"
printf '%s' "$LA" | grep -q 'extract-drain.sh' && ok "launchd: ProgramArguments → drainer" || no "launchd: drainer path"
printf '%s' "$LA" | grep -qi 'logged in' && ok "launchd: prints the no-linger caveat" || no "launchd: no-linger caveat"

# Test 8 (SP-4): launchd snapshots the user's engine env into the unit (minimal-env fix).
LAE=$(SB_INSTALL_OS_OVERRIDE=launchd SB_EXTRACTOR_LOCAL_URL=http://x:1 bash "$INSTALL" 2>&1)
printf '%s' "$LAE" | grep -q 'SB_EXTRACTOR_LOCAL_URL' && ok "launchd: snapshots SB_EXTRACTOR_LOCAL_URL into the unit env" || no "launchd: env snapshot"

# Test 8b (SP-4 gate): a value with XML-special chars is escaped in the plist (valid XML).
LAX=$(SB_INSTALL_OS_OVERRIDE=launchd SB_EXTRACTOR_LOCAL_URL='http://x?a=1&b=2' bash "$INSTALL" 2>&1)
printf '%s' "$LAX" | grep -q '&amp;' && ok "launchd: XML-escapes & in env values" || no "launchd: unescaped & (invalid plist)"
printf '%s' "$LAX" | grep -qE '<string>[^<]*&[^a]' && no "launchd: raw & leaked into a <string>" || ok "launchd: no raw & in <string>"

# Test 9 (SP-4): windows (Task Scheduler) rendering.
WIN=$(SB_INSTALL_OS_OVERRIDE=windows bash "$INSTALL" 2>&1)
printf '%s' "$WIN" | grep -q 'schtasks /Create' && ok "windows: renders a schtasks command" || no "windows: no schtasks"
printf '%s' "$WIN" | grep -q 'MINUTE /MO 30' && ok "windows: 30-min interval" || no "windows: interval"
printf '%s' "$WIN" | grep -qi 'no sandbox' && ok "windows: prints the no-sandbox caveat" || no "windows: sandbox caveat"

# Test 10 (SP-4): unsupported OS → the frictionless API-key fallback, no crash.
UNS=$(SB_INSTALL_OS_OVERRIDE=plan9 bash "$INSTALL" 2>&1)
printf '%s' "$UNS" | grep -q 'ANTHROPIC_API_KEY' && ok "unsupported OS → points at the API-key fallback" || no "unsupported OS fallback"

# Test 11 (SP-4): the Linux/systemd path is unchanged under the OS override.
SD=$(SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>&1)
printf '%s' "$SD" | grep -q 'sb-extract-drain.service' && ok "systemd path intact" || no "systemd path broke"

# Test 12 (SP-B deep-review HIGH): a CUSTOM knowledge dir is forwarded to the out-of-band
# job AND granted in the systemd sandbox (else extraction+consolidation hit the wrong tree).
KD=/data/mykb
SDC=$(CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" SB_INSTALL_OS_OVERRIDE=systemd bash "$INSTALL" 2>/dev/null)
printf '%s' "$SDC" | grep -q "Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=$KD" && ok "systemd: custom KD forwarded via Environment=" || no "systemd: custom KD not forwarded"
printf '%s' "$SDC" | grep -qE "^ReadWritePaths=.*$KD" && ok "systemd: custom KD granted in ReadWritePaths" || no "systemd: custom KD not granted (sandbox would block writes)"
# default render must NOT inject a CLAUDE env line (back-compat)
printf '%s' "$SD" | grep -q 'Environment=CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR' && no "default render injected a custom KD env line" || ok "default render unchanged (no custom KD)"
LAK=$(CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" SB_INSTALL_OS_OVERRIDE=launchd bash "$INSTALL" 2>/dev/null)
printf '%s' "$LAK" | grep -q "$KD" && ok "launchd: custom KD snapshotted into the plist env" || no "launchd: custom KD not forwarded"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
