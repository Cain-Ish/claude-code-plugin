#!/usr/bin/env bash
# The interactive-defer guard on WINDOWS (the primary dev platform).
#
# Incident this locks down: sb_drain_should_defer's non-pgrep fallback used
# `ps -e -o args=`, a GNU-ism MSYS ps rejects outright ("ps: unknown option -- o").
# The heredoc it fed was therefore EMPTY, so the guard answered "no interactive session"
# on every Windows tick — fail-OPEN. The drainer then spawns `claude -p` under the global
# OAuth recursive lock a live session holds, which hangs to its timeout and poison-pills
# good transcripts. Everything downstream (brain-os engine included) claims to inherit
# this guard, so a silent no-op here disarms the whole out-of-band lane.
#
# ORACLE: the real ps on this host, plus a stubbed PATH we control.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
DRAIN="$ROOT/scripts/extract-drain.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Extract the probe under test without executing the whole drainer.
eval "$(sed -n '/^sb_drain_win_claude_present()/,/^}/p' "$DRAIN")"

echo "=== W1: the probe exists and is wired into the defer decision ==="
grep -q 'sb_drain_win_claude_present' "$DRAIN" && pass "W1: probe defined" || fail "W1: probe missing"
# It must be CALLED from the fallback branch, not merely defined.
sed -n '/^sb_drain_should_defer()/,/^}/p' "$DRAIN" | grep -q 'sb_drain_win_claude_present' \
  && pass "W1: defer decision consults the Windows probe" \
  || fail "W1: probe defined but never consulted by sb_drain_should_defer (dead code)"

echo "=== W2: the broken POSIX form is never the ONLY probe ==="
# `ps -e -o args=` may remain as the POSIX branch, but on MSYS it must not be reached first.
if sed -n '/^sb_drain_should_defer()/,/^}/p' "$DRAIN" | grep -q 'ps -e -o args='; then
  _order=$(sed -n '/^sb_drain_should_defer()/,/^}/p' "$DRAIN" | grep -n 'sb_drain_win_claude_present\|ps -e -o args=' | head -2 | cut -d: -f1)
  _first=$(printf '%s\n' "$_order" | head -1); _second=$(printf '%s\n' "$_order" | tail -1)
  [ "$_first" -lt "$_second" ] && pass "W2: the Windows probe runs BEFORE the POSIX form MSYS cannot parse" \
    || fail "W2: the unparseable POSIX form is consulted first on MSYS"
else
  pass "W2: POSIX-only form removed entirely"
fi

echo "=== W3: platform behavior ==="
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # Prove the OLD form really is broken here — that is the whole reason for the probe.
    if ps -e -o args= >/dev/null 2>&1; then
      echo "  NOTE: this MSYS ps accepts -o (newer build) — the probe is belt-and-braces here"
    else
      pass "W3: confirmed 'ps -e -o args=' is unusable on this MSYS (the fail-open cause)"
    fi
    ps -W >/dev/null 2>&1 && pass "W3: 'ps -W' works (the replacement probe's foundation)" \
      || fail "W3: 'ps -W' unavailable — the Windows probe cannot work on this host"
    # A running claude.exe (this very session, when run interactively) must be seen. When the
    # suite runs headless there may be none — then assert the negative instead of skipping.
    if ps -W 2>/dev/null | grep -qiE '[/\\]claude\.exe([[:space:]]|$)'; then
      sb_drain_win_claude_present && pass "W3: probe DETECTS the live claude.exe (guard armed)" \
        || fail "W3: claude.exe is running but the probe missed it"
    else
      sb_drain_win_claude_present && fail "W3: probe reported a claude.exe that ps -W does not list" \
        || pass "W3: no claude.exe running and the probe correctly reports none"
    fi
    ;;
  *)
    # Off-Windows the probe must be inert — it must never defer a Linux/macOS drainer.
    sb_drain_win_claude_present && fail "W3: Windows probe fired on a non-Windows platform" \
      || pass "W3: probe is inert off-Windows (uname-gated)"
    ;;
esac

echo "=== W4: the Claude DESKTOP app must not pin the drainer into a permanent defer ==="
# Desktop app path shape: ...\WindowsApps\Claude_1.2.3_x64__xxx\app\resources\cowork-svc.exe
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/ps" <<'EOF'
#!/bin/sh
echo "  77636  0  0  12100 ?  0 16:24:30 C:\\Program Files\\WindowsApps\\Claude_1.24012.9.0_x64__pzs8sxrjxfjjc\\app\\resources\\cowork-svc.exe"
EOF
chmod +x "$STUB/ps"
if PATH="$STUB:$PATH" sh -c '. /dev/stdin' <<EOF 2>/dev/null
$(sed -n '/^sb_drain_win_claude_present()/,/^}/p' "$DRAIN")
uname() { echo MINGW64_NT-10.0; }
sb_drain_win_claude_present
EOF
then fail "W4: the desktop app was mistaken for the Claude Code CLI (drainer would defer forever)"
else pass "W4: desktop-app process ignored (only claude.exe counts)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
