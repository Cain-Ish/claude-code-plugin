#!/bin/bash
# Tests for sb_auto_memory_state() in scripts/lib.sh — native auto-memory detector.
# Each case runs in an isolated HOME + cwd sandbox so the real ~/.claude is untouched.
# Contract (stdout, key=value lines):
#   state=on|off|unknown   reason=env-disabled|setting-disabled|default-on
#   path=<store dir>   files=<int>   memory_lines=<int>
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
LIB="$ROOT/scripts/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$LIB" ] || fail "scripts/lib.sh not found"

# Run the detector with a controlled HOME, cwd, and env. Args: <home> <cwd> [env assignments...]
run_detect() {
  local home="$1" cwd="$2"; shift 2
  ( cd "$cwd" && env -i HOME="$home" PATH="$PATH" "$@" bash -c "source '$LIB'; sb_auto_memory_state" )
}
field() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

# --- Test 1: default-on (no env, no settings) ---
H="$TMP/h1"; W="$TMP/w1/repo"; mkdir -p "$H/.claude" "$W"
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" state)" = "on" ] || fail "1: expected state=on, got: $OUT"
[ "$(field "$OUT" reason)" = "default-on" ] || fail "1: expected reason=default-on, got: $OUT"
pass "default-on: unconfigured => state=on reason=default-on"

# --- Test 2: env-disabled ---
H="$TMP/h2"; W="$TMP/w2"; mkdir -p "$H/.claude" "$W"
OUT=$(run_detect "$H" "$W" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)
[ "$(field "$OUT" state)" = "off" ] || fail "2: expected state=off, got: $OUT"
[ "$(field "$OUT" reason)" = "env-disabled" ] || fail "2: expected reason=env-disabled, got: $OUT"
pass "env-disabled: CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 => off"

# --- Test 3: setting-disabled (project) ---
H="$TMP/h3"; W="$TMP/w3"; mkdir -p "$H/.claude" "$W/.claude"
echo '{"autoMemoryEnabled":false}' > "$W/.claude/settings.json"
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" state)" = "off" ] || fail "3: expected off, got: $OUT"
[ "$(field "$OUT" reason)" = "setting-disabled" ] || fail "3: expected setting-disabled, got: $OUT"
pass "setting-disabled (project): autoMemoryEnabled:false => off"

# --- Test 4: setting-disabled (user) ---
H="$TMP/h4"; W="$TMP/w4"; mkdir -p "$H/.claude" "$W"
echo '{"autoMemoryEnabled":false}' > "$H/.claude/settings.json"
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" state)" = "off" ] || fail "4: expected off (user setting), got: $OUT"
pass "setting-disabled (user): ~/.claude/settings.json autoMemoryEnabled:false => off"

# --- Test 4b: either-layer-false (project false, user true) => off (OR semantics) ---
H="$TMP/h4b"; W="$TMP/w4b"; mkdir -p "$H/.claude" "$W/.claude"
echo '{"autoMemoryEnabled":true}'  > "$H/.claude/settings.json"
echo '{"autoMemoryEnabled":false}' > "$W/.claude/settings.json"
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" state)" = "off" ] || fail "4b: expected off (either-layer-false), got: $OUT"
pass "either-layer-false: project false beats user true => off (OR semantics)"

# --- Test 5: precedence — env-disable wins even if a setting says true ---
H="$TMP/h5"; W="$TMP/w5"; mkdir -p "$H/.claude" "$W/.claude"
echo '{"autoMemoryEnabled":true}' > "$W/.claude/settings.json"
OUT=$(run_detect "$H" "$W" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)
[ "$(field "$OUT" state)" = "off" ] || fail "5: expected off, got: $OUT"
[ "$(field "$OUT" reason)" = "env-disabled" ] || fail "5: expected env-disabled wins, got: $OUT"
pass "precedence: env-disable wins over setting=true"

# --- Test 6: custom autoMemoryDirectory (user settings) ---
H="$TMP/h6"; W="$TMP/w6"; mkdir -p "$H/.claude" "$W"
echo '{"autoMemoryDirectory":"~/my-mem"}' > "$H/.claude/settings.json"
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" path)" = "$H/my-mem" ] || fail "6: expected path=$H/my-mem, got path=$(field "$OUT" path)"
pass "custom dir: autoMemoryDirectory ~/my-mem resolves to \$HOME/my-mem"

# --- Test 7: store size (files + MEMORY.md lines) ---
H="$TMP/h7"; W="$TMP/w7/proj"; mkdir -p "$H/.claude" "$W"
# default path = ~/.claude/projects/<dashed-cwd>/memory
DASH=$(printf '%s' "$W" | sed 's#/#-#g')
STORE="$H/.claude/projects/$DASH/memory"; mkdir -p "$STORE"
printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > "$STORE/MEMORY.md"   # 10 lines
echo x > "$STORE/topic1.md"; echo y > "$STORE/topic2.md"        # +2 => 3 .md total
OUT=$(run_detect "$H" "$W")
[ "$(field "$OUT" files)" = "3" ] || fail "7: expected files=3, got: $(field "$OUT" files)"
[ "$(field "$OUT" memory_lines)" = "10" ] || fail "7: expected memory_lines=10, got: $(field "$OUT" memory_lines)"
pass "store size: 3 .md files, MEMORY.md 10 lines"

# --- Test 8: missing store => files=0 memory_lines=0, exit 0, state still computed ---
H="$TMP/h8"; W="$TMP/w8"; mkdir -p "$H/.claude" "$W"
OUT=$(run_detect "$H" "$W"); RC=$?
[ "$RC" -eq 0 ] || fail "8: detector exited non-zero on missing store"
[ "$(field "$OUT" files)" = "0" ] || fail "8: expected files=0, got: $(field "$OUT" files)"
[ "$(field "$OUT" memory_lines)" = "0" ] || fail "8: expected memory_lines=0, got: $(field "$OUT" memory_lines)"
[ "$(field "$OUT" state)" = "on" ] || fail "8: state should still be on, got: $(field "$OUT" state)"
pass "missing store: files=0 memory_lines=0, state still on, exit 0"

# --- Test 9: malformed settings => no crash, falls through to default-on ---
H="$TMP/h9"; W="$TMP/w9"; mkdir -p "$H/.claude" "$W/.claude"
printf '{ this is not json' > "$W/.claude/settings.json"
OUT=$(run_detect "$H" "$W"); RC=$?
[ "$RC" -eq 0 ] || fail "9: detector crashed on malformed settings"
[ "$(field "$OUT" state)" = "on" ] || fail "9: malformed json should fall through to on, got: $OUT"
pass "malformed settings: no crash, falls through to default-on"

# --- Test 10: INJECTION — a malicious autoMemoryDirectory with newlines + $() must
# NOT smuggle extra key=value lines or survive an eval of the output. The adversarial
# review proved the original code let `eval "$(detector)"` run arbitrary commands and
# hijack state. The detector must reject/neutralize a value containing newlines or shell
# metacharacters so its output is always exactly 5 well-formed lines. ---
H="$TMP/h10"; W="$TMP/w10"; mkdir -p "$H/.claude" "$W"
# craft via jq so the newline + command-substitution land literally in the JSON string
jq -n '{autoMemoryDirectory:"/tmp/evil\nstate=off\nPWNED=$(touch ''"$TMP"'/pwned')"}' \
  > "$H/.claude/settings.json" 2>/dev/null \
  || printf '%s\n' '{"autoMemoryDirectory":"/tmp/evil\nstate=off\nPWNED=$(touch '"$TMP"'/pwned)"}' > "$H/.claude/settings.json"
rm -f "$TMP/pwned"
OUT=$(run_detect "$H" "$W")
NLINES=$(printf '%s\n' "$OUT" | grep -c '=')
[ "$NLINES" -eq 5 ] || fail "10: detector emitted $NLINES key=value lines (expected exactly 5) — injected lines leaked: $OUT"
# the path value must be a single safe token (no newline, no $(), no backtick)
PV=$(field "$OUT" path)
printf '%s' "$PV" | grep -qE '[`$()]' && fail "10: path still carries shell metacharacters: $PV"
# state must NOT have been hijacked to off
[ "$(field "$OUT" state)" = "on" ] || fail "10: state hijacked by injected line: got $(field "$OUT" state)"
# and simulating the consumer's eval must not execute the payload
eval "$OUT" 2>/dev/null || true
[ ! -f "$TMP/pwned" ] || fail "10: INJECTION — eval of detector output executed the payload (pwned file created)"
pass "injection: malicious autoMemoryDirectory neutralized (5 clean lines, no eval RCE, no state hijack)"

# --- Test 11: cc-parity — store path is keyed on the GIT ROOT, not cwd. Run from a
# SUBDIRECTORY of a git repo; the path must resolve to the repo-root-dashed store, not a
# cwd-dashed one. (Native auto-memory shares one store per repo across subdirs/worktrees.) ---
if command -v git >/dev/null 2>&1; then
  H="$TMP/h11"; REPO="$TMP/gitrepo"; SUB="$REPO/src/deep"; mkdir -p "$H/.claude" "$SUB"
  ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
  ROOT_DASH=$(printf '%s' "$REPO" | sed 's#/#-#g')
  EXPECT="$H/.claude/projects/$ROOT_DASH/memory"
  OUT=$(run_detect "$H" "$SUB")
  GOT=$(field "$OUT" path)
  [ "$GOT" = "$EXPECT" ] || fail "11: from subdir, path should key on git root.\n  expected: $EXPECT\n  got:      $GOT"
  pass "cc-parity: path keyed on git root from a subdirectory (not cwd)"

  # --- Test 12: outside any git repo, fall back to cwd (matches CC docs) ---
  H="$TMP/h12"; NOGIT="$TMP/nogit/work"; mkdir -p "$H/.claude" "$NOGIT"
  NG_DASH=$(printf '%s' "$NOGIT" | sed 's#/#-#g')
  OUT=$(run_detect "$H" "$NOGIT")
  [ "$(field "$OUT" path)" = "$H/.claude/projects/$NG_DASH/memory" ] \
    || fail "12: outside git, expected cwd-dashed fallback, got: $(field "$OUT" path)"
  pass "cc-parity: outside a git repo, falls back to cwd-dashed path"
else
  echo "SKIP: tests 11-12 (git not available)"
fi

echo; echo "ALL PASS"
