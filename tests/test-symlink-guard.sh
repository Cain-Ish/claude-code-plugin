#!/bin/bash
# pins: SB_SYMLINK_GUARD — kill-switch test: asserts =off yields no decision (Test 10)
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

# True only if this filesystem creates REAL symlinks (Windows/Git-Bash without Developer Mode
# silently makes a file copy). The symlink-resolution guard can only be exercised where symlinks
# are real; the guard itself is OS-agnostic and unchanged.
supports_symlinks() {
  local d; d=$(mktemp -d)
  echo t > "$d/t.txt"; ln -s "$d/t.txt" "$d/l.txt" 2>/dev/null
  local ok=1; [ -L "$d/l.txt" ] && ok=0
  rm -rf "$d"; return $ok
}

# Helper: build a tool_input JSON and pipe to symlink-guard.sh; print stdout.
# Uses printf (not jq --arg) to avoid Windows/Git-Bash jq translating POSIX paths
# to Windows C:\ form — that mismatch breaks the guard's HOME-prefix check in the test.
run_guard() {  # $1 tool, $2 file_path
  # Escape double-quotes and backslashes in the path for safe JSON embedding.
  local esc_tool esc_path
  esc_tool=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  esc_path=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' \
    "$esc_tool" "$esc_path" | bash "$SCRIPT" 2>/dev/null
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

# --- Test 5b: direct write to ~/.claude/.credentials.json (file) → deny --
OUT=$(run_guard "Write" "$HOME/.claude/.credentials.json")
assert_deny "direct write to ~/.claude/.credentials.json" "$OUT" "claude-oauth"

# --- Test 5c: legit ~/.claude write (plans/memory/settings) → allow ------
# The ~/.claude TREE must never be a credential prefix: plan files, auto-memory
# and settings.json are routine write targets. Only the token FILE is denied.
OUT=$(run_guard "Write" "$HOME/.claude/plans/some-plan.md")
assert_allow "write to ~/.claude/plans/*" "$OUT"
OUT=$(run_guard "Edit" "$HOME/.claude/settings.json")
assert_allow "edit of ~/.claude/settings.json" "$OUT"

# --- Test 6: direct write to /etc/* → deny -------------------------------
OUT=$(run_guard "Write" "/etc/sudoers.d/test")
assert_deny "direct write to /etc/sudoers.d/test" "$OUT" "etc"

# --- Test 7: write to project file → allow -------------------------------
OUT=$(run_guard "Write" "$HOME/work/repo/main.py")
assert_allow "write to project file" "$OUT"

# --- Test 8: symlink-escape into ~/.ssh → deny (resolves through symlink)
# Create a symlink inside the project that points into ~/.ssh.
if supports_symlinks; then
  SYMLINK_PATH="$HOME/work/repo/innocent.txt"
  ln -sf "$HOME/.ssh/authorized_keys" "$SYMLINK_PATH"
  OUT=$(run_guard "Write" "$SYMLINK_PATH")
  assert_deny "symlink-escape from project file → ~/.ssh" "$OUT" "ssh"
  rm -f "$SYMLINK_PATH"
else
  echo "SKIP: test 8 — symlink-escape via leaf symlink requires real symlink support (Windows without Developer Mode)"
  pass "symlink-escape via leaf symlink (skipped — no symlink support)"
fi

# --- Test 9: symlinked parent dir → deny (resolves through parent symlink)
# project/foo is a symlink to ~/.ssh; project/foo/key is what Claude tries.
if supports_symlinks; then
  ln -sf "$HOME/.ssh" "$HOME/work/repo/foo"
  OUT=$(run_guard "Write" "$HOME/work/repo/foo/new_key")
  assert_deny "write through symlinked parent dir into ~/.ssh" "$OUT" "ssh"
  rm -f "$HOME/work/repo/foo"
else
  echo "SKIP: test 9 — symlinked-parent escape requires real symlink support (Windows without Developer Mode)"
  pass "write through symlinked parent dir (skipped — no symlink support)"
fi

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
# Use printf (not jq --arg) so Git-Bash/Windows jq does not translate POSIX paths to C:\ form.
gen(){ local et ep; et=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'); ep=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$et" "$ep"; }
OUT=$(gen Write "$HOME/.ssh/authorized_keys" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "realpath absent → fail CLOSED on literal ~/.ssh write" "$OUT" "ssh"
OUT=$(gen Write "$HOME/work/repo/main.py" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_allow "realpath absent → normal project write not over-blocked" "$OUT"

# --- Test 18: realpath absent + symlinked PARENT → portable cd/pwd -P resolver still denies ----
# This is the macOS/BSD path (realpath lacks -m): the guard must resolve the parent dir's
# symlinks via `cd … && pwd -P` and still catch a symlinked-parent escape into ~/.ssh.
if supports_symlinks; then
  ln -sf "$HOME/.ssh" "$HOME/work/repo/foo2"
  OUT=$(gen Write "$HOME/work/repo/foo2/new_key" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "realpath absent + symlinked parent → cd/pwd -P fallback denies (macOS path)" "$OUT" "ssh"
  rm -f "$HOME/work/repo/foo2"
else
  echo "SKIP: test 18 — symlinked-parent escape requires real symlink support (Windows without Developer Mode)"
  pass "realpath absent + symlinked parent (skipped — no symlink support)"
fi

# --- Test 19: realpath absent + LEAF symlink (benign-named file IS a symlink into ~/.ssh) -------
# The fallback must dereference the leaf, not just the parent — else a `Write innocent.txt`
# whose innocent.txt → ~/.ssh/authorized_keys slips through on stock macOS (the review finding).
if supports_symlinks; then
  ln -sf "$HOME/.ssh/authorized_keys" "$HOME/work/repo/innocent.txt"
  OUT=$(gen Write "$HOME/work/repo/innocent.txt" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "realpath absent + LEAF symlink into ~/.ssh → leaf-deref denies (macOS path)" "$OUT" "ssh"
  rm -f "$HOME/work/repo/innocent.txt"
else
  echo "SKIP: test 19 — leaf-symlink escape requires real symlink support (Windows without Developer Mode)"
  pass "realpath absent + LEAF symlink (skipped — no symlink support)"
fi

# --- Test 20 (Windows form): C:\ credential path is denied ---------------
# THE G-HOOK-2 fix. On Windows, Claude Code sends 'C:\Users\…' and GNU realpath
# re-emits 'C:/Users/…'; before the fix neither matched the '/c/…' credential
# prefixes and the guard was completely inert on the platform this plugin is
# developed on. cygpath + realpath are STUBBED so the Windows path is exercised
# identically on Linux/BSD CI. Regression lock: drop the RESOLVED normalization
# in symlink-guard.sh and this test flips to a silent allow (FAIL).
WINHOME="$TMP/winhome"; mkdir -p "$WINHOME/.ssh" "$WINHOME/work/repo"
WINBIN="$TMP/winbin"; mkdir -p "$WINBIN"
# cygpath -u 'C:/winhome/<rest>' -> $WINHOME/<rest>; passthrough otherwise.
cat > "$WINBIN/cygpath" <<'EOF'
#!/bin/sh
p="$2"; W="$SB_TEST_WINHOME"
case "$p" in
  C:/winhome/*) printf '%s/%s\n' "$W" "${p#C:/winhome/}" ;;
  C:/winhome)   printf '%s\n' "$W" ;;
  *) printf '%s\n' "$p" ;;
esac
EOF
# realpath emits the Windows 'C:/winhome/…' drive form (as GNU realpath does on
# git-bash) so the guard MUST normalize its output to match the /c/… prefixes.
cat > "$WINBIN/realpath" <<'EOF'
#!/bin/sh
f=""; for a; do case "$a" in -*) ;; *) f="$a";; esac; done
W="$SB_TEST_WINHOME"
case "$f" in
  "$W"/*) printf 'C:/winhome/%s\n' "${f#"$W"/}" ;;
  "$W")   printf 'C:/winhome\n' ;;
  *) printf '%s\n' "$f" ;;
esac
EOF
chmod +x "$WINBIN/cygpath" "$WINBIN/realpath"
win_guard() {  # $1 tool  $2 windows-form path
  local et ep
  et=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ep=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$et" "$ep" \
    | HOME="$WINHOME" SB_TEST_WINHOME="$WINHOME" PATH="$WINBIN:$PATH" bash "$SCRIPT" 2>/dev/null
}
OUT=$(win_guard "Write" 'C:\winhome\.ssh\authorized_keys')
assert_deny "Windows C:\\ path into ~/.ssh → deny (G-HOOK-2 armed on Windows)" "$OUT" "ssh"
OUT=$(win_guard "Write" 'C:\winhome\work\repo\main.py')
assert_allow "Windows C:\\ project path → allow (not over-blocked)" "$OUT"

# --- Test 21: case-varied credential path is still denied -----------------
# NTFS (and default APFS) are case-insensitive: C:\winhome\.SSH IS ~/.ssh
# there, so a case-sensitive prefix match lets '.SSH' sail through (panel-
# confirmed bypass). Regression lock: make the credential compare case-
# sensitive again and this flips to a silent allow (FAIL).
OUT=$(win_guard "Write" 'C:\winhome\.SSH\authorized_keys')
assert_deny "case-varied .SSH path → deny (case-insensitive FS bypass closed)" "$OUT" "ssh"

# --- Test 22: \\?\ extended-length form is still denied -------------------
# \\?\C:\… is a legal Windows path form; before the normalizer stripped it,
# the drive-letter case never matched and the guard was blind to it.
OUT=$(win_guard "Write" '\\?\C:\winhome\.ssh\authorized_keys')
assert_deny "extended-length \\\\?\\ credential path → deny" "$OUT" "ssh"

# --- Test 23: lib.sh unsourceable → inline fallback normalizer still arms the guard
# The guard carries a minimal inline sb_normalize_path for the lib-missing
# configuration. That branch was previously untested — drift there would
# disarm the Windows guard ONLY when lib.sh fails to source, invisibly.
# Force the source to fail (CLAUDE_PLUGIN_ROOT=/nonexistent) and require deny.
win_guard_nolib() {  # $1 tool  $2 windows-form path  (win_guard + broken plugin root)
  local et ep
  et=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ep=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$et" "$ep" \
    | CLAUDE_PLUGIN_ROOT=/nonexistent HOME="$WINHOME" SB_TEST_WINHOME="$WINHOME" PATH="$WINBIN:$PATH" bash "$SCRIPT" 2>/dev/null
}
OUT=$(win_guard_nolib "Write" 'C:\winhome\.ssh\authorized_keys')
assert_deny "lib.sh unsourceable → inline fallback still denies (fallback branch armed)" "$OUT" "ssh"
OUT=$(win_guard_nolib "Write" '\\?\C:\winhome\.ssh\authorized_keys')
assert_deny "lib.sh unsourceable + \\\\?\\ form → deny (fallback strips long-path prefix)" "$OUT" "ssh"

# --- Test 24 (D182): \\.\ device-namespace path into ~/.ssh → deny -----------
# \\.\C:\… is a legal Windows device-namespace path form; before the
# normalizer stripped it, the drive-letter case never matched (same class as
# \\?\, test 22) and the guard was blind to it.
OUT=$(win_guard "Write" '\\.\C:\winhome\.ssh\authorized_keys')
assert_deny "device-namespace \\\\.\\ credential path → deny (D182)" "$OUT" "ssh"

# --- Test 25 (D182): NTFS 8.3 short-name path components → fail CLOSED (deny) ---
# "SSH~1" / "TMP~1.MKZ" pass through cygpath/realpath UNEXPANDED (neither tool
# expands 8.3 aliases back to their long form), so a credential dir reached via
# its short alias never matched the long-form prefix list. The guard cannot
# safely resolve these — it must deny outright rather than silently allow.
OUT=$(run_guard "Write" "$HOME/work/repo/SSH~1/id_rsa")
assert_deny "8.3 short-name component 'SSH~1' → deny (D182, cannot safely resolve)" "$OUT" "8.3"
OUT=$(run_guard "Write" "$HOME/work/repo/TMP~1.MKZ/SSH~1/id_rsa")
assert_deny "8.3 short-name components 'TMP~1.MKZ/SSH~1' → deny (D182)" "$OUT" "8.3"
# A normal tilde-containing filename with NO digit suffix (not 8.3-shaped) is
# not over-blocked — only the '~<digits>' alias marker triggers the deny.
OUT=$(run_guard "Write" "$HOME/work/repo/notes~draft.md")
assert_allow "'~' without a digit suffix is not 8.3-shaped — not over-blocked" "$OUT"

# --- Test 26 (D183): lexical '..' collapse in the no-realpath fallback -------
# realpath+greadlink stubbed to exit 127 (the stock-macOS shape test 17 uses).
# Vector A: a '..' escape through a NOT-YET-CREATED intermediate directory
# (the common case for a Write that creates new dirs) must still resolve and
# deny — before this fix `cd` failed on the missing "newdir" and the fallback
# fell back to the RAW lexical path with '..' still literally in it, which
# never prefix-matched ~/.ssh and silently allowed.
OUT=$(gen Write "$HOME/work/repo/newdir/../../../.ssh/id_rsa" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "D183 vector A: '..' through a not-yet-created dir → deny" "$OUT" "ssh"

# Vector B: '..' through an EXISTING parent (control — already worked before
# the fix; must keep working).
OUT=$(gen Write "$HOME/work/../work/repo/../../.ssh/id_rsa" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "D183 vector B: '..' through an existing parent → deny" "$OUT" "ssh"

# Vector C: no '..' at all, direct existing-parent path (control).
OUT=$(gen Write "$HOME/.ssh/id_rsa" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "D183 vector C: direct ~/.ssh path (no realpath) → deny" "$OUT" "ssh"

# Vector E: a symlinked ancestor with a NOT-YET-CREATED child (no '..' at
# all) — the fallback must dereference the symlinked ancestor via `pwd -P`
# even though the leaf's immediate parent doesn't exist yet. This defeats
# G-HOOK-2's stated purpose if missed.
if supports_symlinks; then
  ln -sf "$HOME/.ssh" "$HOME/work/repo/link-to-ssh"
  OUT=$(gen Write "$HOME/work/repo/link-to-ssh/sub/id_rsa" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "D183 vector E: symlinked ancestor + not-yet-created child → deny" "$OUT" "ssh"
  rm -f "$HOME/work/repo/link-to-ssh"
else
  echo "SKIP: test 26 vector E — requires real symlink support (Windows without Developer Mode)"
  pass "D183 vector E (skipped — no symlink support)"
fi

# A normal project write with '..' segments that stay inside the project is
# NOT over-blocked (the collapse must resolve correctly, not just deny everything).
OUT=$(gen Write "$HOME/work/repo/sub/../main.py" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_allow "D183: '..' collapsing to an in-project path is not over-blocked" "$OUT"

echo
echo "ALL PASS"
