#!/bin/bash
# tests/test-nested-spawn-guard.sh — R1.1 nested-spawn circuit breaker.
# Headless `claude -p` children spawned by the drainer/maintainer inherit
# SB_NESTED_SPAWN=1; every capture/context hook must then no-op instantly
# (exit 0, no output, no writes) instead of re-running the full plugin stack
# (~24s on a Pi — the cause of every observed ec=124 extraction timeout).
# SECURITY guards (PreToolUse/PostToolUse/ConfigChange) must NOT honor the
# env: an inheritable kill-switch on guards would itself be a vulnerability.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

GUARDED="ensure-dirs.sh discover-tools.sh discover-installed.sh discover-doc-sources.sh session-load.sh dream-autostage.sh persona-context.sh stop-verify-gate.sh stop-extract.sh sar-summary.sh cost-router-capture.sh pre-compact.sh subagent-capture.sh"
SECURITY="persona-tool-guard.sh wiki-write-guard.sh symlink-guard.sh flow-guard.sh config-change-guard.sh quality-gate.sh tool-return-scanner.sh simplicity-gate.sh"

# --- Part A: static — every capture/context hook carries the guard line.
for s in $GUARDED; do
  grep -q 'SB_NESTED_SPAWN:-0' "$REPO_ROOT/scripts/$s" \
    || fail "static: scripts/$s lacks the nested-spawn guard"
done
pass "static: all capture/context hook scripts carry the guard"

# --- Part B: static — security guards must NOT be disableable via the env.
for s in $SECURITY; do
  grep -q 'SB_NESTED_SPAWN' "$REPO_ROOT/scripts/$s" \
    && fail "static: scripts/$s (security guard) must not honor SB_NESTED_SPAWN"
done
pass "static: no security guard honors SB_NESTED_SPAWN"

# --- Part C: runtime — guarded scripts exit 0 with no output and no writes.
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"
export SB_NESTED_SPAWN=1
for s in $GUARDED; do
  OUT=$(echo '{"session_id":"x","transcript_path":"/nonexistent","cwd":"'"$SANDBOX"'"}' \
        | bash "$REPO_ROOT/scripts/$s" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || fail "runtime: $s exited $rc under SB_NESTED_SPAWN=1"
  [ -z "$OUT" ] || fail "runtime: $s emitted output under SB_NESTED_SPAWN=1: $(printf '%s' "$OUT" | head -c 80)"
done
LEFT=$(find "$BRAIN_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] || fail "runtime: guarded hooks wrote $LEFT path(s) into BRAIN_DIR"
unset SB_NESTED_SPAWN
pass "runtime: all guarded hooks no-op under SB_NESTED_SPAWN=1"

# --- Part D: spawn site exports the env and runs in the scratch cwd (Task 3;
# RED until Task 3 lands — that is expected while executing Task 2).
unset CLAUDECODE 2>/dev/null || true
unset ANTHROPIC_API_KEY 2>/dev/null || true
unset SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true
export PROBE="$SANDBOX/probe"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${SB_NESTED_SPAWN:-unset}" "$PWD" > "$PROBE"
echo '{"ok":true}'
EOF
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"
IN=$(mktemp); OUTF=$(mktemp); echo data > "$IN"
( source "$REPO_ROOT/scripts/lib.sh"
  sb_call_extractor "$IN" "$OUTF" test-model test-prompt 5 >/dev/null 2>&1 )
[ -f "$PROBE" ] || fail "spawn: claude stub never invoked"
read -r ENVV CWDV < "$PROBE"
[ "$ENVV" = "1" ] || fail "spawn: SB_NESTED_SPAWN not set on extractor spawn (got $ENVV)"
[ "$CWDV" = "$BRAIN_DIR/scratch" ] || fail "spawn: extractor cwd is $CWDV, want $BRAIN_DIR/scratch"
rm -f "$IN" "$OUTF"
pass "spawn site exports SB_NESTED_SPAWN=1 and runs in BRAIN_DIR/scratch"

# --- Part E: static — maintainer spawn guarded; drainer timeout default 120s.
grep -q 'SB_NESTED_SPAWN=1' "$REPO_ROOT/scripts/maintain-llm-drain.sh" \
  || fail "static: maintain-llm-drain.sh claude spawn lacks SB_NESTED_SPAWN=1"
grep -q 'SB_DRAIN_EXTRACT_TIMEOUT:-120' "$REPO_ROOT/scripts/lib.sh" \
  || fail "static: sb_extract_transcript drainer timeout default is not the dedicated 120s knob"
grep -q 'SB_NESTED_SPAWN=1' "$REPO_ROOT/scripts/extraction-quality-gate.sh" \
  || fail "static: extraction-quality-gate haiku_check spawn lacks SB_NESTED_SPAWN=1"
pass "static: maintainer + quality-gate spawns guarded; drainer timeout knob dedicated (120s)"

echo "ALL PASS"

# --- Part F (R5.1): cost-router's own hooks honor the guard too — a nested
# extractor session must not get routing banners/nudges injected (R1 deferral).
for s in classify-prompt.sh routing-status.sh; do
  grep -q 'SB_NESTED_SPAWN:-0' "$REPO_ROOT/cost-router/scripts/$s" \
    || fail "static: cost-router/scripts/$s lacks the nested-spawn guard"
  OUT=$(echo '{"prompt":"design something elaborate for me"}' \
        | SB_NESTED_SPAWN=1 bash "$REPO_ROOT/cost-router/scripts/$s" )
  [ -z "$OUT" ] || fail "runtime: cost-router/$s emitted output under SB_NESTED_SPAWN=1"
done
pass "cost-router hooks no-op under SB_NESTED_SPAWN=1"

echo "ALL PASS (incl. cost-router)"
