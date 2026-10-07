#!/bin/bash
# run-all-timeout: 180   (measured 67s alone on MSYS 2026-10-08 with 9.3 GB free and ~400 processes, after the R3B GX6 cases; 32-72s in other runs that day)
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
# dir_link TARGET LINK: a DIRECTORY link — `ln -s` where it makes a real one, else an NTFS junction
# through node (DA #8, chronicle §3: Git-Bash without Developer Mode deep-COPIES on `ln -s`, so every
# symlinked-directory case skipped on the dev box and the Windows lane). Junctions link directories
# only: the leaf-FILE symlink cases still need real symlinks and still skip there. 0 = link made.
dir_link() {
  if supports_symlinks; then ln -sf "$1" "$2"; return; fi
  command -v node >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1 || return 1
  node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "junction")' "$(cygpath -w "$1")" "$(cygpath -w "$2")" \
    && [ -L "$2" ] && [ -d "$2" ]
}
# dir_unlink LINK: remove the link itself, never what it points at (`rm -rf` of a junction can walk
# into the target): rmdir through node for a junction, rm -f for a symlink.
dir_unlink() {
  if [ -L "$1" ] && ! supports_symlinks; then node -e 'require("fs").rmdirSync(process.argv[1])' "$(cygpath -w "$1")"; else rm -f "$1"; fi
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
if dir_link "$HOME/.ssh" "$HOME/work/repo/foo"; then
  OUT=$(run_guard "Write" "$HOME/work/repo/foo/new_key")
  assert_deny "write through symlinked parent dir into ~/.ssh" "$OUT" "ssh"
  dir_unlink "$HOME/work/repo/foo"
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
# Test 17c: the resolver returns an unrelated path for a LITERAL ~/.ssh target (a HOME
# spelling pwd -P rewrites, a broken realpath): the literal target must still be denied.
STUBW="$TMP/stubwrong"; mkdir -p "$STUBW"
printf '#!/bin/sh
echo /tmp/somewhere/else
' > "$STUBW/realpath"; chmod +x "$STUBW/realpath"
OUT=$(gen Write "$HOME/.ssh/authorized_keys" | PATH="$STUBW:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_deny "resolver disagrees with a literal ~/.ssh target → literal check still denies" "$OUT" "ssh"
# Test 17b: same, with HOME spelled in Windows form (a GitHub Windows runner sets
# HOME='D:\a\_temp\…'). The credential prefixes must be built from the normalized HOME, or a
# ~/.ssh write fails OPEN. Only meaningful where cygpath exists (sb_normalize_path's C: rule).
if command -v cygpath >/dev/null 2>&1; then
  for WH in "$(cygpath -m "$HOME")" "$(cygpath -w "$HOME")"; do
    OUT=$(gen Write "$WH/.ssh/authorized_keys" | HOME="$WH" PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
    assert_deny "realpath absent + Windows-form HOME ($WH) → still denies ~/.ssh write" "$OUT" "ssh"
  done
else
  echo "SKIP: Test 17b (Windows-form HOME) needs cygpath — Windows hosts only"
fi

# --- Test 18: realpath absent + symlinked PARENT → portable cd/pwd -P resolver still denies ----
# This is the macOS/BSD path (realpath lacks -m): the guard must resolve the parent dir's
# symlinks via `cd … && pwd -P` and still catch a symlinked-parent escape into ~/.ssh.
if dir_link "$HOME/.ssh" "$HOME/work/repo/foo2"; then
  OUT=$(gen Write "$HOME/work/repo/foo2/new_key" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "realpath absent + symlinked parent → cd/pwd -P fallback denies (macOS path)" "$OUT" "ssh"
  dir_unlink "$HOME/work/repo/foo2"
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
  [Cc]:/winhome/*) printf '%s/%s\n' "$W" "${p#?:/winhome/}" ;;
  [Cc]:/winhome)   printf '%s\n' "$W" ;;
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

# --- Test 24b (SEC-H2): Windows alias spellings of a local credential dir ---------------------
# Neither cygpath nor realpath resolves these, so before the fix every one was ALLOWED: an
# administrative share (X$) through any host spelling is mapped to its drive and checked; NTFS
# stream syntax is denied outright; any other UNC target asks (where a share leads is unknown).
for sp in '\\LOCALHOST\C$\winhome\.ssh\authorized_keys' '\\LocalHost\c$\winhome\.ssh\authorized_keys' \
          '\\myhost\C$\winhome\.ssh\authorized_keys' '\\?\UNC\localhost\C$\winhome\.ssh\authorized_keys' \
          '\\0--1.ipv6-literal.net\C$\winhome\.ssh\authorized_keys'; do
  OUT=$(win_guard "Write" "$sp")
  assert_deny "SEC-H2 admin-share alias $sp" "$OUT" "ssh"
done
for sp in 'C:\winhome\.ssh::$INDEX_ALLOCATION\authorized_keys' 'C:\winhome\.ssh:$I30:$INDEX_ALLOCATION\authorized_keys'; do
  OUT=$(win_guard "Edit" "$sp")
  assert_deny "SEC-H2 NTFS stream alias $sp" "$OUT" "stream"
done
OUT=$(win_guard "Write" '\\nas\share\docs\x.md')
[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' | tr -d '\r')" = ask ] \
  && printf '%s' "$OUT" | grep -q 'UNC' || fail "SEC-H2: a plain UNC share target must ask (got: $OUT)"
pass "SEC-H2: a non-admin UNC share asks"
OUT=$(win_guard "Write" '\\myhost\C$\winhome\work\repo\main.py')
assert_allow "SEC-H2: an admin-share path outside the credential dirs is not over-blocked" "$OUT"

# --- Test 25 (D182): NTFS 8.3 short-name path components → fail CLOSED (deny) ---
# "SSH~1" / "TMP~1.MKZ" pass through cygpath/realpath UNEXPANDED (neither tool
# expands 8.3 aliases back to their long form), so a credential dir reached via
# its short alias never matched the long-form prefix list. The guard cannot
# safely resolve these — it must deny outright rather than silently allow.
# 8.3 aliases are a Windows-filesystem concept, so the guard applies the rule only where
# cygpath exists (or the host is MSYS): run these vectors through the stubbed-cygpath lane.
OUT=$(PATH="$WINBIN:$PATH" run_guard "Write" "$HOME/work/repo/SSH~1/id_rsa")
assert_deny "8.3 short-name component 'SSH~1' → deny (D182, cannot safely resolve)" "$OUT" "8.3"
OUT=$(PATH="$WINBIN:$PATH" run_guard "Write" "$HOME/work/repo/TMP~1.MKZ/SSH~1/id_rsa")
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
if dir_link "$HOME/.ssh" "$HOME/work/repo/link-to-ssh"; then
  OUT=$(gen Write "$HOME/work/repo/link-to-ssh/sub/id_rsa" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "D183 vector E: symlinked ancestor + not-yet-created child → deny" "$OUT" "ssh"
  dir_unlink "$HOME/work/repo/link-to-ssh"
else
  echo "SKIP: test 26 vector E — requires real symlink support (Windows without Developer Mode)"
  pass "D183 vector E (skipped — no symlink support)"
fi

# A normal project write with '..' segments that stay inside the project is
# NOT over-blocked (the collapse must resolve correctly, not just deny everything).
OUT=$(gen Write "$HOME/work/repo/sub/../main.py" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
assert_allow "D183: '..' collapsing to an in-project path is not over-blocked" "$OUT"

# Vector F (D183 follow-up): a RELATIVE leaf-symlink target that itself
# contains '..' must have that '..' re-collapsed against the symlink's
# directory, not spliced in raw. Before the fix, `ln -s ../../.ssh/id_rsa
# repo/notes.txt` resolved to ".../repo/../../.ssh/id_rsa" verbatim (the
# unresolved '..' never prefix-matched ~/.ssh) and silently allowed.
if supports_symlinks; then
  ln -sf "../../.ssh/id_rsa" "$HOME/work/repo/notes.txt"
  OUT=$(gen Write "$HOME/work/repo/notes.txt" | PATH="$STUB:$PATH" bash "$SCRIPT" 2>/dev/null)
  assert_deny "D183 vector F: relative leaf-symlink target with '..' re-collapses → deny" "$OUT" "ssh"
  rm -f "$HOME/work/repo/notes.txt"
else
  echo "SKIP: test 26 vector F — requires real symlink support (Windows without Developer Mode)"
  pass "D183 vector F (skipped — no symlink support)"
fi

# --- Test 27 (D182 follow-up): 8.3 short-name rule must not over-block a
# real long filename that merely CONTAINS a tilde+digit (nothing to expand).
mkdir -p "$HOME/work/repo"
: > "$HOME/work/repo/notes~1.md"
OUT=$(run_guard "Write" "$HOME/work/repo/notes~1.md")
assert_allow "8.3 negative control: real 'notes~1.md' in a project dir is not over-blocked" "$OUT"
rm -f "$HOME/work/repo/notes~1.md"

# When cygpath is available, a REAL 8.3 alias must still resolve to its true
# long-form target and be denied via the normal credential-prefix match (not
# the fail-closed branch) — expansion must not become a new bypass.
if command -v cygpath >/dev/null 2>&1; then
  SHORT_W=$(cygpath -d "$HOME/.ssh" 2>/dev/null)
  SHORT_POSIX=$(cygpath -u "$SHORT_W" 2>/dev/null | tr -d '\r')
  if [ -n "$SHORT_POSIX" ] && printf '%s' "$SHORT_POSIX" | grep -qE '~[0-9]+'; then
    OUT=$(run_guard "Write" "$SHORT_POSIX/id_rsa")
    assert_deny "8.3 real alias of ~/.ssh expands and still denies" "$OUT" "ssh"
  else
    echo "SKIP: test 27 real-alias case — this filesystem/HOME path has no 8.3 alias to test"
    pass "8.3 real-alias case (skipped — no short alias produced)"
  fi
else
  echo "SKIP: test 27 real-alias case — cygpath not on PATH"
  pass "8.3 real-alias case (skipped — no cygpath)"
fi

# --- B7: fail SAFE under load — credential targets decided before any dependency -------------
# A PreToolUse hook that answers after its timeout is CANCELLED and the Write RUNS (CLI 2.1.283
# probe, 2026-09-28; this guard was cancelled 50 times in 4 heavy sessions at ~1.5 s per call).
# Fixture: a plugin root whose lib.sh sleeps, plus PATH shims that sleep for every external the
# full logic spawns (jq, realpath, cygpath, tr, grep, …). A credential target must still be
# denied within B7_BOUND seconds. No GNU `timeout` (absent on macOS): whole-second SECONDS.
# Generous bounds (a passing run never sleeps; a stalled one sleeps B7_SLEEP): load cannot flake it.
# Item 17: on bash < 4.3 (the macOS lane's /bin/bash 3.2) the guards' builtin payload reader steps
# aside and jq decides every call, as on main — a stalled jq can then hold the verdict, so these
# stalled-dependency cases cannot hold there by design and are skipped (loudly) on such a bash.
FP_OFF=0
bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }' && FP_OFF=1
B7_SLEEP=20; B7_BOUND=10
B7="$TMP/b7"; mkdir -p "$B7/root/scripts" "$B7/shims" "$B7/brain"
# Precondition: the audit dir exists BEFORE the shims go on PATH — _fp_audit would otherwise run the
# shimmed (sleeping) mkdir and the bound would measure the fixture, not the guard.
[ -d "$B7/brain" ] || fail "B7 precondition: $B7/brain must exist before the shims are installed"
printf 'sleep %s\n' "$B7_SLEEP" > "$B7/root/scripts/lib.sh"
for t in jq cat tr grep sed awk head tail cut wc realpath greadlink readlink cygpath dirname basename mkdir mv uname git; do
  printf '#!/bin/sh\nsleep %s\nexit 127\n' "$B7_SLEEP" > "$B7/shims/$t"; chmod +x "$B7/shims/$t"
done
b7_deny() {  # b7_deny <label> <tool> <file_path> <needle> [HOME override]
  if [ "$FP_OFF" = 1 ]; then echo "SKIP: B7 $1 — the fast path is off on bash < 4.3 (item 17: jq decides, as on main)"; return 0; fi
  local label="$1" s out h="${5:-$HOME}"
  s=$SECONDS
  out=$(gen "$2" "$3" | HOME="$h" CLAUDE_PLUGIN_ROOT="$B7/root" BRAIN_DIR="$B7/brain" PATH="$B7/shims:$PATH" bash "$SCRIPT" 2>/dev/null)
  s=$(( SECONDS - s ))
  [ "$s" -le "$B7_BOUND" ] \
    || fail "B7 $label: took ${s}s under a sleeping lib.sh/jq/realpath (bound ${B7_BOUND}s) — a loaded machine cancels this hook and the Write RUNS"
  assert_deny "B7 $label (${s}s, every dependency stalled)" "$out" "$4"
}
b7_deny "literal ~/.ssh target"        Write "$HOME/.ssh/authorized_keys" ssh
b7_deny "tilde form"                   Write "~/.ssh/id_rsa" ssh
b7_deny "case-varied .SSH"             Edit  "$HOME/.SSH/config" ssh
b7_deny "~/.aws node itself"           Write "$HOME/.aws" aws
b7_deny "OAuth token file"             Write "$HOME/.claude/.credentials.json" claude-oauth
b7_deny "/etc"                         MultiEdit /etc/sudoers.d/x etc
b7_deny "'..' through a missing dir"   Write "$HOME/work/repo/newdir/../../../.ssh/id_rsa" ssh
b7_deny "Windows C:\\ payload"         Write 'C:\Users\victim\.ssh\authorized_keys' ssh /c/Users/victim
b7_deny "\\\\?\\ payload"              Write '\\?\C:\Users\victim\.gnupg\x' gnupg /c/Users/victim
b7_deny "Windows-form HOME"            Write /c/Users/victim/.aws/credentials aws 'C:\Users\victim'
if dir_link "$HOME/.ssh" "$HOME/work/repo/b7-dirlink"; then
  b7_deny "symlinked parent dir"       Write "$HOME/work/repo/b7-dirlink/new_key" ssh
  dir_unlink "$HOME/work/repo/b7-dirlink"
else
  echo "SKIP: B7 symlinked-parent case — no real symlink and no junction (node/cygpath) support"
fi
if supports_symlinks; then
  : > "$HOME/.ssh/authorized_keys"; ln -sf "$HOME/.ssh/authorized_keys" "$HOME/work/repo/b7-innocent.txt"
  b7_deny "leaf symlink into ~/.ssh"   Write "$HOME/work/repo/b7-innocent.txt" ssh
  rm -f "$HOME/work/repo/b7-innocent.txt"
else
  echo "SKIP: B7 leaf-symlink case — no real symlink support (a junction links directories only)"
fi

# No false positives from the fast path: only tool_input.file_path decides — never text in the
# content, a nested look-alike key, or a sibling directory whose name merely starts with .ssh.
npj() { printf '{"session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$1" "$2" | bash "$SCRIPT" 2>/dev/null; }
OUT=$(npj "$HOME/work/repo/notes.md" 'see ~/.ssh/authorized_keys and \"file_path\":\"~/.ssh/id_rsa\" and /etc/passwd')
assert_allow "content naming ~/.ssh and a quoted file_path is not a target" "$OUT"
OUT=$(run_guard Write "$HOME/.sshkeys-notes/x.md")
assert_allow "a sibling ~/.sshkeys-notes dir is not ~/.ssh" "$OUT"
OUT=$(run_guard Edit "$HOME/work/repo/etc/config.yml")
assert_allow "a project etc/ dir is not /etc" "$OUT"

# --- Payload size: every verdict must arrive before the 5 s hook timeout ---------------------
# bounded LABEL LIMIT PAYLOAD-FILE [VAR=val…]: run the guard on the payload in the background,
# stdout to a file, a watchdog killing it past LIMIT seconds — a hung guard must FAIL the test, not
# hang it (a timed-out PreToolUse hook is cancelled and the Write RUNS). BD_OUT = stdout; BD_MS =
# elapsed ms (EPOCHREALTIME on bash 5; whole seconds from `date` on older bash, the macOS lane);
# BD_EL = whole seconds. The guard must exit 0. LIMIT is only the kill; every run must also
# answer within HOOK_BOUND_MS.
# Runs use a UTF-8 locale when there is one (DA #3: the multibyte payloads exist to hit bash's
# wide-character slow paths, which the C locale a bare CI shell starts in never takes).
UTF8_LOC=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  [ "$( (LC_ALL=$l; s=$'\303\251'; printf %s "${#s}") 2>/dev/null)" = 1 ] && { UTF8_LOC=$l; break; }
done
[ -n "$UTF8_LOC" ] || echo "SKIP: no UTF-8 locale — the size cases below run in the C locale, off the wide-character paths"
now_ms() { local n="${EPOCHREALTIME:-}"; n="${n//[!0-9]/}"; if [ -n "$n" ]; then echo $((10#$n / 1000)); else echo $(( $(date +%s) * 1000 )); fi; }
bounded() {
  local label="$1" lim="$2" pf="$3" pid wd rc t0; shift 3
  t0=$(now_ms)
  env ${UTF8_LOC:+LC_ALL=$UTF8_LOC} "$@" bash "$SCRIPT" < "$pf" > "$TMP/bounded.out" 2> "$TMP/bounded.err" & pid=$!
  # TERM, then KILL 2 s later: a guard blocked writing a pipe on MSYS ignores TERM, and `wait` on it
  # never returned — the test hung until run-all's timeout with no message (final review, 0.54.1).
  ( sleep "$lim"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  BD_MS=$(( $(now_ms) - t0 )); BD_EL=$((BD_MS / 1000))
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$BD_MS" -lt $((lim * 1000)) ] || fail "$label: still running after ${lim}s (killed)"
  [ "$rc" = 0 ] || fail "$label: the guard exited $rc ($(head -c 300 "$TMP/bounded.err"))"
  # Every size case must answer inside the hook budget (item F8/DA #6: the old 10 s lock let a
  # 9 s answer pass while production cancelled it at 5 s).
  [ "$BD_MS" -le "$HOOK_BOUND_MS" ] || fail "$label: answered in ${BD_MS} ms, bound $HOOK_BOUND_MS ms — past it the hook is cancelled and the tool RUNS"
  BD_OUT=$(cat "$TMP/bounded.out")
}
# within LABEL MS: the last bounded run answered inside MS milliseconds.
within() { [ "$BD_MS" -le "$2" ] || fail "$1: answered in ${BD_MS} ms, bound $2 ms — past it the hook is cancelled and the Write RUNS"; }
# The hook timeout is 5 s; hook-timer.sh, bash's start and the spawn under a loaded box take the
# rest: a case that must answer in time is bound at 4 s. BIG_BOUND stays the kill limit.
HOOK_BOUND_MS=4000
# big_body N: an 'é' then N bytes of 80-column lines, as a JSON string body (\n escapes, no raw
# newline). The one multibyte character matters: bash then matches in wide characters, where a
# ${v//pat/rep} pass costs O(matches x length) — the decode of such a value took 117 s.
big_body() { printf '\303\251'; printf '%*s' "$1" '' | tr ' ' x | fold -w 80 | awk '{printf "%s\\n", $0}'; }
BIG_BOUND=10
BODY=$(big_body 524288)

# P-H1: a 512 KB Write. The fast path sees only the first 16 KiB, so a file_path AFTER the content
# is decided by the full logic — which took 144 s (O(n^2) key search and newline strip).
printf '{"session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$HOME/work/repo/big.txt" "$BODY" > "$TMP/big1.json"
bounded "P-H1 512 KB benign Write" "$BIG_BOUND" "$TMP/big1.json"
assert_allow "P-H1: 512 KB benign Write answered in ${BD_EL}s" "$BD_OUT"
printf '{"session_id":"t","tool_name":"Write","tool_input":{"content":"%s","file_path":"%s"}}' "$BODY" "$HOME/.ssh/authorized_keys" > "$TMP/big2.json"
bounded "P-H1 512 KB Write into ~/.ssh, file_path after the content" "$BIG_BOUND" "$TMP/big2.json"
assert_deny "P-H1: 512 KB Write into ~/.ssh (file_path last) denied in ${BD_EL}s" "$BD_OUT" ssh

# SEC-C1: a payload whose here-string would be 65,537..~65,690 bytes hung on MSYS for good. The
# \u in file_path makes the builtin decode undecidable, so the full logic's jq fallback reads RAW.
sec_c1_payload() {  # sec_c1_payload TOTAL-BYTES OUT PREFIX SUFFIX: PREFIX + x-padding + SUFFIX, TOTAL bytes
  local pad=$(( $1 - ${#3} - ${#4} ))
  { printf '%s' "$3"; printf '%*s' "$pad" '' | tr ' ' x; printf '%s' "$4"; } > "$2"
}
sec_c1_payload 65600 "$TMP/c1.json" "{\"session_id\":\"t\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HOME/.ssh/\\u0061uthorized_keys\",\"content\":\"" '"}}'
[ "$(wc -c < "$TMP/c1.json" | tr -d ' ')" = 65600 ] || fail "SEC-C1 fixture: payload is not 65,600 bytes"
bounded "SEC-C1 65,600-byte payload (jq fallback)" 20 "$TMP/c1.json"
assert_deny "SEC-C1: a 65,600-byte payload through the jq fallback answers (${BD_EL}s)" "$BD_OUT" ssh

# SEC-C2: _sg_phys stat'ed and trimmed once per missing component — quadratic in the path (an
# a/../a/.. path of 3.7 KB took 5.8 s on the reviewer's box; 14.5 KB 4.2 s here). '..' and deep
# paths now go to the full logic's one realpath -m (0.2 s). The 14.5 KB path still fits the fast
# path's 16 KiB read, and this bound is tight on purpose: the old walk lands above it.
DOTS=$(i=0; while [ $i -lt 2900 ]; do printf 'a/../'; i=$((i + 1)); done)
printf '{"session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HOME/work/repo/$DOTS../../.ssh/id_rsa" > "$TMP/c2a.json"
bounded "SEC-C2 14.5 KB a/.. path into ~/.ssh" 30 "$TMP/c2a.json"
assert_deny "SEC-C2: 14.5 KB a/../ path into ~/.ssh denied in ${BD_EL}s" "$BD_OUT" ssh
[ "$BD_EL" -le 3 ] || fail "SEC-C2: a 14.5 KB a/../ path took ${BD_EL}s (bound 3 s) — the per-component walk is back"
DOTS=$(i=0; while [ $i -lt 1600 ]; do printf 'a/../'; i=$((i + 1)); done)
printf '{"session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HOME/work/repo/${DOTS}x.txt" > "$TMP/c2b.json"
bounded "SEC-C2 8 KB a/.. path in the project" "$BIG_BOUND" "$TMP/c2b.json"
# 3,201 components: past DA #2's 256-component cap, so the answer is an ask (too long to resolve),
# never a deny — this project path names no credential dir.
assert_allow "SEC-C2: 8 KB a/../ path inside the project answered in ${BD_MS} ms" "$BD_OUT"
printf '%s' "$BD_OUT" | grep -q 'too long to resolve' || fail "SEC-C2: an 8 KB a/../ path of 3,201 components must get DA #2's ask (got: $BD_OUT)"
DEEP=$(i=0; while [ $i -lt 100 ]; do printf 'd%s/' $i; i=$((i + 1)); done)
printf '{"session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HOME/.ssh/${DEEP}k" > "$TMP/c2c.json"
bounded "SEC-C2 100-component path under ~/.ssh" "$BIG_BOUND" "$TMP/c2c.json"
assert_deny "SEC-C2: a 100-component path under ~/.ssh denied in ${BD_EL}s" "$BD_OUT" ssh

# RR-CR1: a file_path ending in 50,000 CONSECUTIVE trailing newlines (P-H1/SEC-C2 above only cover
# interspersed text or 'a/../' runs). The full logic's _fp_clean used to strip them one at a time
# (`${v%"$_fp_nl"}` in a loop): O(N x length) for N trailing newlines, 40 s here past the 5 s
# timeout (a fail-open DoS). The verdict must be unchanged: Write into ~/.ssh still denies.
TRAIL50K=$(i=0; while [ $i -lt 50000 ]; do printf '\\n'; i=$((i + 1)); done)
printf '{"session_id":"cr1","tool_name":"Write","tool_input":{"file_path":"%s/.ssh/id_rsa%s","content":"x"}}' "$HOME" "$TRAIL50K" > "$TMP/cr1.json"
bounded "RR-CR1 50,000 consecutive trailing newlines, Write into ~/.ssh" "$BIG_BOUND" "$TMP/cr1.json"
within "RR-CR1 50,000 trailing newlines" "$HOOK_BOUND_MS"
assert_deny "RR-CR1: 50,000 consecutive trailing newlines into ~/.ssh denied in ${BD_MS} ms" "$BD_OUT" ssh

# F8 #1: the same run INSIDE the file_path, text after it. The `($_fp_nl+)$` regex the trim used
# was O(run^2) on glibc for this shape (39 s for this payload on Debian); on MSYS the path then
# went through realpath -m and three _fp_esc passes of 50,000 newlines (17 s) before DA #2.
printf '{"session_id":"cr1i","tool_name":"Write","tool_input":{"file_path":"%s/.ssh/id_rsa%s#","content":"x"}}' "$HOME" "$TRAIL50K" > "$TMP/cr1i.json"
bounded "F8 50,000 interior newlines, Write into ~/.ssh" "$BIG_BOUND" "$TMP/cr1i.json"
within "F8 50,000 interior newlines" "$HOOK_BOUND_MS"
assert_deny "F8: 50,000 newlines inside a ~/.ssh file_path denied in ${BD_MS} ms" "$BD_OUT" ssh

# DA #2: a file_path past the fast path's 16 KiB read reaches the full logic, which ran realpath -m
# before any credential match — quadratic in the components on MSYS (1,500: no answer in 100 s),
# so the Write into ~/.ssh got no verdict in time and RAN. The literal and lexical targets are
# matched first now; a path too long to resolve in time and naming no credential dir is asked about.
SEGS=$(i=0; while [ $i -lt 1500 ]; do printf '\303\25112345678/'; i=$((i + 1)); done)
printf '{"session_id":"da2a","tool_name":"Write","tool_input":{"file_path":"%s/.ssh/%sk","content":"x"}}' "$HOME" "$SEGS" > "$TMP/da2a.json"
bounded "DA #2 1,500-component path under ~/.ssh" "$BIG_BOUND" "$TMP/da2a.json"
within "DA #2 1,500-component path under ~/.ssh" "$HOOK_BOUND_MS"
assert_deny "DA #2: a 16 KB+ path of 1,500 components under ~/.ssh denied in ${BD_MS} ms" "$BD_OUT" ssh
UPS=$(i=0; while [ $i -lt 3500 ]; do printf 'a/'; i=$((i + 1)); done)
DNS=$(i=0; while [ $i -lt 3500 ]; do printf '../'; i=$((i + 1)); done)
printf '{"session_id":"da2b","tool_name":"Write","tool_input":{"file_path":"%s/.ssh/%s%sauthorized_keys","content":"x"}}' "$HOME" "$UPS" "$DNS" > "$TMP/da2b.json"
bounded "DA #2 ~/.ssh/(a/)^3500(../)^3500/authorized_keys" "$BIG_BOUND" "$TMP/da2b.json"
within "DA #2 (a/)^3500(../)^3500 under ~/.ssh" "$HOOK_BOUND_MS"
assert_deny "DA #2: ~/.ssh/(a/)^3500(../)^3500/authorized_keys (17.5 KB) denied in ${BD_MS} ms" "$BD_OUT" ssh
# Outside every credential dir, a path too long to resolve asks (its ancestors could be links).
printf '{"session_id":"da2c","tool_name":"Write","tool_input":{"file_path":"%s/work/repo/%sk","content":"x"}}' "$HOME" "$SEGS" > "$TMP/da2c.json"
rm -f "$HOME/.second-brain/audit-log.jsonl"
bounded "DA #2 1,500-component path in the project" "$BIG_BOUND" "$TMP/da2c.json"
within "DA #2 1,500-component path in the project" "$HOOK_BOUND_MS"
[ -n "$BD_OUT" ] && printf '%s' "$BD_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | test("too long to resolve"))' >/dev/null \
  || fail "DA #2: a 1,500-component path outside the credential dirs must ask (too long to resolve), got: $BD_OUT"
grep -q '"rule":"path-too-long"' "$HOME/.second-brain/audit-log.jsonl" || fail "DA #2: the path-too-long ask was not audit-logged"
pass "DA #2: a 1,500-component path outside the credential dirs asks in ${BD_MS} ms"
# F8 item 18: the same shapes in Windows drive form (C:\…), which the full logic hands to cygpath -u
# — a spawn whose argument conversion took 5.1 s for a 50,000-newline path on MSYS. The literal
# match and the cap now come before it. Windows hosts only (a C:\ path names nothing under HOME
# elsewhere).
if command -v cygpath >/dev/null 2>&1; then
  WHE=$(cygpath -w "$HOME"); WHE=${WHE//\\/\\\\}
  WSEG=$(i=0; while [ $i -lt 1500 ]; do printf 'e12345678\\\\'; i=$((i + 1)); done)
  printf '{"session_id":"i18a","tool_name":"Write","tool_input":{"file_path":"%s\\\\.ssh\\\\%sk","content":"x"}}' "$WHE" "$WSEG" > "$TMP/i18a.json"
  bounded "item 18: 1,500-component drive-form path under ~/.ssh" "$BIG_BOUND" "$TMP/i18a.json"
  assert_deny "item 18: a C:\\ path of 1,500 components under ~/.ssh denied in ${BD_MS} ms" "$BD_OUT" ssh
  # With newlines in it the path never reaches cygpath past the cap (seconds of argument conversion),
  # so the credential match is the lexical one: HOME is given in the drive form a real profile has
  # (this sandbox's /tmp is an MSYS mount whose C:\ spelling no lexical rule can map).
  printf '{"session_id":"i18b","tool_name":"Write","tool_input":{"file_path":"%s\\\\.ssh\\\\id_rsa%s#","content":"x"}}' "$WHE" "$TRAIL50K" > "$TMP/i18b.json"
  bounded "item 18: drive-form ~/.ssh path with 50,000 newlines" "$BIG_BOUND" "$TMP/i18b.json" HOME="$(cygpath -w "$HOME")"
  assert_deny "item 18: a C:\\ ~/.ssh path holding 50,000 newlines denied in ${BD_MS} ms" "$BD_OUT" ssh
else
  echo "SKIP: item 18 drive-form long paths — cygpath not on PATH (Windows hosts only)"
fi
# Under both limits a deep project path still resolves and passes (the cap is not a blanket ask).
D200=$(i=0; while [ $i -lt 200 ]; do printf 'd%s/' $i; i=$((i + 1)); done)
printf '{"session_id":"da2d","tool_name":"Write","tool_input":{"file_path":"%s/work/repo/%sk","content":"x"}}' "$HOME" "$D200" > "$TMP/da2d.json"
bounded "DA #2 200-component project path" "$BIG_BOUND" "$TMP/da2d.json"
within "DA #2 200-component project path" "$HOOK_BOUND_MS"
assert_allow "DA #2: a 200-component project path is still resolved and allowed (${BD_MS} ms)" "$BD_OUT"

g1_rep() { local i=0; while [ $i -lt "$2" ]; do printf '%s' "$1"; i=$((i + 1)); done; }
# T2 (final review): each half of the cap asks on its own — a project path of 300 real components in
# ~700 characters, and one of 20 components in ~5,000. Either half could be deleted with every
# other case still green.
for t2 in "a:$(g1_rep a/ 300)" "b:$(g1_rep "$(g1_rep b 250)/" 20)"; do
  printf '{"session_id":"t2","tool_name":"Write","tool_input":{"file_path":"%s/work/repo/%sk","content":"x"}}' "$HOME" "${t2#?:}" > "$TMP/t2.json"
  rm -f "$HOME/.second-brain/audit-log.jsonl"
  bounded "T2 cap half ${t2%%:*}" "$BIG_BOUND" "$TMP/t2.json"
  [ -n "$BD_OUT" ] && printf '%s' "$BD_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | test("too long to resolve"))' >/dev/null \
    && grep -q '"rule":"path-too-long"' "$HOME/.second-brain/audit-log.jsonl" \
    || fail "T2: cap half ${t2%%:*} (a: 300 components, b: 5,000 characters) must ask, too long to resolve, with a path-too-long row (got: $BD_OUT)"
done
pass "T2: each half of the cap asks on its own (300 real components; 5,000 characters)"

# G1 (0.54.1 final review, HIGH regression): DA #2's 256-component cap counted empty and '.' fields,
# which cost realpath -m nothing (2,048 of them: ~60 ms on MSYS, against ~2 s for 256 real ones), so
# a Write through a link into ~/.ssh spelled with a run of './' or '//' went over the cap and got an
# ask where it had been denied. Only real components count now, and past either limit the guard still
# resolves the lexically folded path when that one is under both: a long './' or 'a/../' run through
# the link is denied too. A wrapper logs every argument realpath, greadlink, readlink and cygpath get:
# none may pass 4096 characters (a payload-sized one costs seconds; cygpath cuts its answer at 32,767).
if dir_link "$HOME/.ssh" "$HOME/work/repo/keys"; then
  G1BIN=$(mktemp -d); : > "$G1BIN/args.log"
  cat > "$G1BIN/wrap" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "${#a}" >> "$G1_LOG"; done
PATH=$G1_PATH; export PATH
exec "${0##*/}" "$@"
EOF
  for t in realpath greadlink readlink cygpath; do
    command -v "$t" >/dev/null 2>&1 && cp "$G1BIN/wrap" "$G1BIN/$t" && chmod +x "$G1BIN/$t"
  done
  g1() {  # g1 NAME PATH: a Write to PATH, every resolver argument logged
    printf '{"session_id":"g1","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$2" > "$TMP/g1-$1.json"
    bounded "G1 $1" "$BIG_BOUND" "$TMP/g1-$1.json" PATH="$G1BIN:$PATH" G1_PATH="$PATH" G1_LOG="$G1BIN/args.log"
  }
  g1 dots "$HOME/work/repo/keys/$(g1_rep ./ 300)id_rsa"
  assert_deny "G1: a link into ~/.ssh spelled with 300 './' denied in ${BD_MS} ms" "$BD_OUT" ssh
  g1 slashes "$HOME/work/repo/keys$(g1_rep / 300)id_rsa"
  assert_deny "G1: a link into ~/.ssh spelled with 300 '/' denied in ${BD_MS} ms" "$BD_OUT" ssh
  g1 updown "$HOME/work/repo/keys/$(g1_rep a/../ 600)id_rsa"
  assert_deny "G1: a link into ~/.ssh behind 600 'a/../' (over by components) denied in ${BD_MS} ms" "$BD_OUT" ssh
  g1 longdots "$HOME/work/repo/keys/$(g1_rep ./ 3000)id_rsa"
  assert_deny "G1: a link into ~/.ssh behind 3,000 './' (over by length) denied in ${BD_MS} ms" "$BD_OUT" ssh
  # Isolate the real-component count from the fold-and-resolve path (test-review gap 2): with the '.'
  # run BEFORE the link and a '..' AFTER it, realpath follows keys -> ~/.ssh and only THEN applies '..'
  # (-> ~/.ssh is the parent's child again); the lexical fold instead cancels keys/.. first and loses
  # the link. So this denies only when the path stays OUT of the over-cap branch — i.e. only when '.'
  # fields are not counted. Counting them (the regression) sends it over the cap and the fold asks.
  g1 linkup "$HOME/work/repo/$(g1_rep ./ 300)keys/../.ssh/id_rsa"
  assert_deny "G1: './'-run then keys/../.ssh resolves through the link and denies in ${BD_MS} ms" "$BD_OUT" ssh
  # The matching benign case: a './'-padded project path must still ALLOW (counting '.' would push it
  # over the cap and ask "too long").
  g1 benign "$HOME/work/repo/$(g1_rep ./ 300)x.txt"
  assert_allow "G1: a './'-padded project path is resolved and allowed in ${BD_MS} ms" "$BD_OUT"
  printf '%s' "$BD_OUT" | grep -q 'too long' && fail "G1: a './'-padded project path must not hit the path-too-long ask (got: $BD_OUT)"
  # G4 class (test-review gap 3): a drive-form target past the cap must reach cygpath only through the
  # SHORT folded spelling, never raw. 3,000 './' in C:\ form is > 4096 chars (over by length); the fold
  # collapses to a short path that resolves through the link and denies. Windows only (needs cygpath).
  if command -v cygpath >/dev/null 2>&1; then
    g1 drivedots "$(cygpath -m "$HOME")/work/repo/keys/$(g1_rep ./ 3000)id_rsa"
    assert_deny "G1: a drive-form link path of 3,000 './' denied in ${BD_MS} ms" "$BD_OUT" ssh
    # Finding C: a '..' at the drive root folds the drive component out of the collapsed lex form, so
    # the drive-form fold must reattach the whole collapsed path, not slice off its (missing) drive. A
    # C:/../<HOME-under-C:>/.ssh link path (Windows clamps C:\.. to C:\) must still deny.
    HREL=$(cygpath -m "$HOME" | cut -c3-)
    g1 driveroot "C:/..${HREL}/work/repo/keys/$(g1_rep ./ 3000)id_rsa"
    assert_deny "G1: a drive-root '..' link path denied in ${BD_MS} ms" "$BD_OUT" ssh
    # Mutation k / F-D: a target under an MSYS mount (/etc is the Git root's etc) past the cap must be
    # mapped by cygpath -u on the SHORT folded spelling and denied — HEAD mapped it by running cygpath
    # on the raw target, which this guard no longer does. 300 real components (> 256) so the resolve is
    # skipped; only the mapped-fold credential match catches it.
    g1 etcroot "$(cygpath -m /)/etc/$(g1_rep a/ 300)k"
    assert_deny "G1: an /etc path under the MSYS root past the cap denied in ${BD_MS} ms" "$BD_OUT" etc
    # F-E: HOME spelled in its /c/ drive form while it lies UNDER the /tmp mount. realpath returns the
    # /tmp spelling of the resolved target, which no /c/ HOME prefix matches; _sg_homes (full) must add
    # HOME's mount spelling via the cygpath round trip. Without the fix this ALLOWS a write through the
    # link into ~/.ssh. HC is HOME's drive-letter POSIX form (/c/…/Temp/…), not the /tmp alias.
    HC=$(cygpath -m "$HOME"); HC="/$(printf '%s' "${HC:0:1}" | tr 'A-Z' 'a-z')${HC:2}"
    printf '{"session_id":"g1fe","tool_name":"Write","tool_input":{"file_path":"%s/work/repo/keys/id_rsa","content":"x"}}' "$HC" > "$TMP/g1fe.json"
    FEOUT=$(env HOME="$HC" BRAIN_DIR="$TMP/feb" bash "$SCRIPT" < "$TMP/g1fe.json" 2>/dev/null)
    assert_deny "G1/F-E: a link into ~/.ssh with HOME in /c drive form under the mount denies" "$FEOUT" ssh
  fi
  # Mutation j: the fold's own `${#_sg_fp} <= 4096` bound. A ~5 KB path of real components (no './' to
  # collapse away) stays over 4096 after folding; with the bound it is asked about without touching a
  # resolver, so no resolver argument exceeds 4096. Dropping the bound hands realpath the 5 KB path.
  g1 foldbound "$HOME/work/repo/$(g1_rep "$(g1_rep b 250)/" 20)k"
  printf '%s' "$BD_OUT" | grep -q 'too long to resolve' || fail "G1: a 5 KB real-component path must ask (too long to resolve), got: $BD_OUT"
  [ -s "$G1BIN/args.log" ] || fail "G1: the wrappers logged nothing — the resolution these cases need never ran"
  G1_MAX=$(sort -n "$G1BIN/args.log" | tail -1)
  [ "$G1_MAX" -le 4096 ] || fail "G1: a resolver was handed a ${G1_MAX}-character argument — every one must stay within 4096"
  pass "G1: no resolver argument past 4096 characters (longest: $G1_MAX)"
  # Finding A / F-A+F-B time lock (test-review gap 6): a ~300 KB './' run through the link into ~/.ssh
  # must DENY inside the hook budget. On HEAD and the pre-fix diff this answered at 7–8 s (past the 5 s
  # timeout → the Write ran); the fix denies in ~2–3 s. bounded() fails the test if it exceeds
  # HOOK_BOUND_MS, so this is the regression lock for the whole over-cap path, at a real payload size.
  printf '{"session_id":"g1big","tool_name":"Write","tool_input":{"file_path":"%s/work/repo/keys/%sid_rsa","content":"x"}}' "$HOME" "$(g1_rep ./ 150000)" > "$TMP/g1big.json"
  bounded "G1: 300 KB './' run through the link into ~/.ssh" "$BIG_BOUND" "$TMP/g1big.json"
  assert_deny "G1: a 300 KB './' link path denied inside the hook budget (${BD_MS} ms)" "$BD_OUT" ssh
  dir_unlink "$HOME/work/repo/keys"
  rm -rf "$G1BIN"
else
  echo "SKIP: G1 — no directory link can be made here (no real symlinks, no node junction)"
fi

# --- GX6 (R3B): the credential stores beyond the first eight ------------------------------------
# ~/.git-credentials, ~/.npmrc, ~/.docker/config.json, ~/.kube/config, ~/.pypirc, ~/.config/gcloud
# and ~/.azure hold tokens as surely as ~/.netrc; on Windows so do %APPDATA%\GitHub CLI\hosts.yml and
# %APPDATA%\gcloud, and the native tools keep theirs under %USERPROFILE% when HOME points elsewhere.
for f in .git-credentials .npmrc .docker/config.json .kube/config .pypirc .config/gcloud/credentials.db .azure/msal_token_cache.json; do
  OUT=$(run_guard Write "$HOME/$f"); assert_deny "GX6: write to ~/$f" "$OUT" "credential"
done
OUT=$(run_guard Write "$HOME/.docker/daemon.json"); assert_allow "GX6: ~/.docker/daemon.json is no credential store" "$OUT"
OUT=$(USERPROFILE="$TMP/profile" run_guard Write "$TMP/profile/.claude/.credentials.json")
assert_deny "GX6: write to USERPROFILE's .claude/.credentials.json (HOME elsewhere)" "$OUT" "credential"
OUT=$(USERPROFILE="$TMP/profile" run_guard Edit "$TMP/profile/.ssh/authorized_keys")
assert_deny "GX6: edit of USERPROFILE's .ssh/authorized_keys (HOME elsewhere)" "$OUT" "credential"
OUT=$(APPDATA="$TMP/appdata" run_guard Write "$TMP/appdata/GitHub CLI/hosts.yml")
assert_deny "GX6: write to %APPDATA%/GitHub CLI/hosts.yml" "$OUT" "credential"
OUT=$(APPDATA="$TMP/appdata" run_guard Write "$TMP/appdata/gcloud/credentials.db")
assert_deny "GX6: write into %APPDATA%/gcloud" "$OUT" "credential"
OUT=$(APPDATA="$TMP/appdata" run_guard Write "$TMP/appdata/Code/settings.json")
assert_allow "GX6: other %APPDATA% files are no credential store" "$OUT"

# Mutation i (source-scan): the `_sg_segs SG_SEGS` count must stay gated by the length cap. Without the
# gate, a 300 KB run of '/' spends ~1.6 s splitting into ~300k fields for a count that is moot past the
# character cap. The whole guard still answers over the 4 s bound on that input with or without the
# gate, so no time-bound test can see it — this is the only pin.
grep -Eq '\[ *"\$SG_LEN" *-le *4096 *\] *&& *_sg_segs SG_SEGS' "$SCRIPT" \
  || fail "source-scan: _sg_segs SG_SEGS must stay gated by [ \"\$SG_LEN\" -le 4096 ] (mutation i)"
pass "source-scan: the SG_SEGS count is gated by the 4096-character cap"

echo
echo "ALL PASS"
