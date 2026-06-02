#!/bin/bash
# Tests for scripts/symlink-guard.sh — PreToolUse credential-dir symlink guard.
# Closes G-HOOK-2 from wiki/security/plugin-hardening-gap-analysis-2026-05-28.md.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/symlink-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate HOME so credential-dir prefix checks evaluate against a sandbox.
export HOME="$TMP/home"
mkdir -p "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config/claude" \
         "$HOME/.password-store" "$HOME/work/repo" "$HOME/.config/gh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Helper: build a tool_input JSON and pipe to symlink-guard.sh; print stdout.
run_guard() {  # $1 tool, $2 file_path
  jq -nc --arg t "$1" --arg p "$2" '{
    session_id: "test",
    hook_event_name: "PreToolUse",
    tool_name: $t,
    tool_input: { file_path: $p }
  }' | bash "$SCRIPT" 2>/dev/null
}

assert_allow() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then pass "$label (no decision → allow)"; return; fi
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
  if [ "$decision" = "deny" ]; then
    fail "$label — expected allow, got deny ($out)"
  else
    pass "$label (decision=$decision)"
  fi
}
assert_deny() {
  local label="$1" out="$2" needle="$3"
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
  [ "$decision" = "deny" ] || fail "$label — expected deny, got '$decision' (out: $out)"
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  printf '%s' "$reason" | grep -q "$needle" || fail "$label — reason should mention '$needle' (got: $reason)"
  pass "$label (deny, reason mentions $needle)"
}

# --- Test 1: direct write to ~/.ssh/* → deny -----------------------------
OUT=$(run_guard "Write" "$HOME/.ssh/authorized_keys")
assert_deny "direct write to ~/.ssh/authorized_keys" "$OUT" "ssh"

# --- Test 2: direct write to ~/.gnupg/* → deny ---------------------------
OUT=$(run_guard "Edit" "$HOME/.gnupg/pubring.kbx")
assert_deny "direct edit to ~/.gnupg/pubring.kbx" "$OUT" "gnupg"

# --- Test 3: direct write to ~/.aws/credentials → deny -------------------
OUT=$(run_guard "Write" "$HOME/.aws/credentials")
assert_deny "direct write to ~/.aws/credentials" "$OUT" "aws"

# --- Test 4: direct write to ~/.config/claude/* → deny -------------------
OUT=$(run_guard "Write" "$HOME/.config/claude/auth.json")
assert_deny "direct write to ~/.config/claude/auth.json" "$OUT" "claude-config"

# --- Test 5: direct write to ~/.netrc (file, not prefix) → deny ----------
OUT=$(run_guard "Write" "$HOME/.netrc")
assert_deny "direct write to ~/.netrc" "$OUT" "netrc"

# --- Test 6: direct write to /etc/* → deny -------------------------------
OUT=$(run_guard "Write" "/etc/sudoers.d/test")
assert_deny "direct write to /etc/sudoers.d/test" "$OUT" "etc"

# --- Test 7: write to project file → allow -------------------------------
OUT=$(run_guard "Write" "$HOME/work/repo/main.py")
assert_allow "write to project file" "$OUT"

# --- Test 8: symlink-escape into ~/.ssh → deny (resolves through symlink)
# Create a symlink inside the project that points into ~/.ssh.
SYMLINK_PATH="$HOME/work/repo/innocent.txt"
ln -sf "$HOME/.ssh/authorized_keys" "$SYMLINK_PATH"
OUT=$(run_guard "Write" "$SYMLINK_PATH")
assert_deny "symlink-escape from project file → ~/.ssh" "$OUT" "ssh"
rm -f "$SYMLINK_PATH"

# --- Test 9: symlinked parent dir → deny (resolves through parent symlink)
# project/foo is a symlink to ~/.ssh; project/foo/key is what Claude tries.
ln -sf "$HOME/.ssh" "$HOME/work/repo/foo"
OUT=$(run_guard "Write" "$HOME/work/repo/foo/new_key")
assert_deny "write through symlinked parent dir into ~/.ssh" "$OUT" "ssh"
rm -f "$HOME/work/repo/foo"

# --- Test 10: SB_SYMLINK_GUARD=off → empty output (no decision) ---------
OUT=$(SB_SYMLINK_GUARD=off run_guard "Write" "$HOME/.ssh/authorized_keys")
[ -z "$OUT" ] || fail "kill switch should produce empty output (got: $OUT)"
pass "SB_SYMLINK_GUARD=off bypasses guard"

# --- Test 11: tool other than Write/Edit/MultiEdit → ignored ------------
OUT=$(run_guard "Bash" "$HOME/.ssh/authorized_keys")
[ -z "$OUT" ] || fail "Bash tool should be ignored by symlink-guard (got: $OUT)"
pass "Bash tool ignored (out of scope)"

# --- Test 12: empty file_path → ignored (no false positive) -------------
OUT=$(jq -nc '{session_id:"t", hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{}}' | bash "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] || fail "empty file_path should be silently ignored (got: $OUT)"
pass "missing file_path silently ignored"

# --- Test 13: tilde-prefixed path expands then matches ------------------
# tool_input.file_path can arrive as "~/.ssh/..." — guard must expand $HOME.
OUT=$(run_guard "Write" "~/.ssh/id_rsa")
assert_deny "tilde-prefixed ~/.ssh/id_rsa path" "$OUT" "ssh"

# --- Test 14: relative path inside project → allow ----------------------
cd "$HOME/work/repo" || fail "cd failed"
OUT=$(run_guard "Edit" "main.py")
assert_allow "relative path inside project" "$OUT"

# --- Test 15: file under ~/.password-store → deny -----------------------
OUT=$(run_guard "Write" "$HOME/.password-store/work/github.gpg")
assert_deny "write under ~/.password-store" "$OUT" "passwordstore"

# --- Test 16: write to credential-dir NODE itself (no trailing /) → deny -
# Regression test for the v0.21.0 review finding: the prefix check matches
# "$HOME/.ssh/*" but a Write whose path resolves to "$HOME/.ssh" exactly
# (no trailing slash) was passing unchallenged. Fixed by adding an equality
# fallback alongside the prefix glob.
OUT=$(run_guard "Write" "$HOME/.ssh")
assert_deny "write to credential-dir node itself (no trailing /)" "$OUT" "ssh"
OUT=$(run_guard "Write" "$HOME/.aws")
assert_deny "write to ~/.aws node itself" "$OUT" "aws"
OUT=$(run_guard "Write" "/etc")
assert_deny "write to /etc node itself" "$OUT" "etc"

# --- Test 17: realpath BINARY absent → fail CLOSED (lexical fallback still denies) -------
# The deny-guard must not fail-open if `realpath` is missing. Shadow it with a stub that
# produces no output (RESOLVED empty) and confirm a literal ~/.ssh write is still denied,
# while a normal project write is still allowed (the lexical fallback must not over-block).
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 127\n' > "$STUB/realpath"; chmod +x "$STUB/realpath"
gen(){ jq -nc --arg t "$1" --arg p "$2" '{session_id:"t",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p}}'; }
OUT=$(gen Write "$HOME/.ssh/authorized_keys" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "realpath absent → fail CLOSED on literal ~/.ssh write" "$OUT" "ssh"
OUT=$(gen Write "$HOME/work/repo/main.py" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_allow "realpath absent → normal project write not over-blocked" "$OUT"

# --- Test 18: realpath absent + symlinked PARENT → portable cd/pwd -P resolver still denies ----
# This is the macOS/BSD path (realpath lacks -m): the guard must resolve the parent dir's
# symlinks via `cd … && pwd -P` and still catch a symlinked-parent escape into ~/.ssh.
ln -sf "$HOME/.ssh" "$HOME/work/repo/foo2"
OUT=$(gen Write "$HOME/work/repo/foo2/new_key" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "realpath absent + symlinked parent → cd/pwd -P fallback denies (macOS path)" "$OUT" "ssh"
rm -f "$HOME/work/repo/foo2"

echo
echo "ALL PASS"
