#!/bin/bash
# Tests for sb_normalize_path (scripts/lib.sh) — the Windows path-form funnel
# that re-armed the PreToolUse guards (symlink / persona-tool / wiki-write) on
# Windows. cygpath is STUBBED so the Windows drive-letter behavior is exercised
# on Linux/BSD CI too (where cygpath is otherwise absent, and the bug that
# silently disarmed the guards would never surface).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
# aeq EXPECTED ACTUAL LABEL
aeq() { [ "$2" = "$1" ] || fail "$3 — expected '$1', got '$2'"; pass "$3"; }

# Stub cygpath: emulate `cygpath -u 'C:/x/y'` -> '/c/x/y' (lowercase the drive,
# drop the colon). Real git-bash cygpath does exactly this against the MSYS
# mount table; the stub makes the mapping deterministic on any platform. Only
# transforms a drive-letter argument — everything else passes through, so
# sourcing lib.sh (which cygpaths BRAIN_DIR at load time) is unaffected.
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/cygpath" <<'EOF'
#!/bin/sh
p="$2"
case "$p" in
  [A-Za-z]:/*)
    drive=$(printf '%s' "$p" | cut -c1 | tr 'A-Z' 'a-z')
    rest=$(printf '%s' "$p" | cut -c3-)
    printf '/%s%s\n' "$drive" "$rest" ;;
  *) printf '%s\n' "$p" ;;
esac
EOF
chmod +x "$STUB/cygpath"

# Source WITHOUT the stub on PATH so lib.sh's own load-time BRAIN_DIR
# normalization runs against the real environment, then add the stub.
source "$ROOT/scripts/lib.sh" 2>/dev/null || fail "could not source lib.sh"
command -v sb_normalize_path >/dev/null 2>&1 || fail "sb_normalize_path not defined by lib.sh"

export PATH="$STUB:$PATH"

# 1. backslash drive path -> /c/ POSIX (the shape Claude Code sends on Windows)
got=$(sb_normalize_path 'C:\Users\me\.ssh\authorized_keys')
aeq "/c/Users/me/.ssh/authorized_keys" "$got" "backslash drive path -> /c POSIX (cygpath present)"

# 2. forward-slash drive path -> /c/ POSIX (realpath -m emits this form)
got=$(sb_normalize_path 'C:/Users/me/.ssh/authorized_keys')
aeq "/c/Users/me/.ssh/authorized_keys" "$got" "forward drive path -> /c POSIX (cygpath present)"

# 3. genuine POSIX path is untouched (Linux/macOS no-op)
got=$(sb_normalize_path '/home/u/proj/src/main.py')
aeq "/home/u/proj/src/main.py" "$got" "POSIX path unchanged"

# 4. empty in -> empty out (guards short-circuit before calling, but be safe)
got=$(sb_normalize_path '')
aeq "" "$got" "empty in -> empty out"

# 5. idempotent: normalizing an already-normalized path is a no-op
once=$(sb_normalize_path 'C:\Users\me\x')
twice=$(sb_normalize_path "$once")
aeq "$once" "$twice" "idempotent (normalize of normalized == normalized)"

# 6. FALLBACK BRANCH: no cygpath (Linux/BSD, or a broken PATH). Backslashes are
# still converted, but the drive letter is kept as-is (nothing to map it with).
# Exercising this branch is the house rule: test the resolution path with the
# tool ABSENT, not only the fixture-forced present case.
got=$( PATH=""; sb_normalize_path 'C:\Users\me\x' )
aeq "C:/Users/me/x" "$got" "no cygpath -> backslash converted, drive kept (fallback branch)"

# 7. Windows extended-length prefix \\?\C:\… — an evasion/long-path form that
# previously fell through every guard's drive-letter case entirely.
got=$(sb_normalize_path '\\?\C:\Users\me\.ssh\authorized_keys')
aeq "/c/Users/me/.ssh/authorized_keys" "$got" "\\\\?\\ extended-length prefix stripped -> /c POSIX"

# 8. Loopback admin-share UNC — the same local drive in disguise.
got=$(sb_normalize_path '\\localhost\c$\Users\me\.ssh\id_rsa')
aeq "/c/Users/me/.ssh/id_rsa" "$got" "\\\\localhost\\c\$ admin share -> /c POSIX"
got=$(sb_normalize_path '\\127.0.0.1\c$\Users\me\x')
aeq "/c/Users/me/x" "$got" "\\\\127.0.0.1\\c\$ admin share -> /c POSIX"

# 9. Non-loopback UNC passes through unchanged (documented limit — cannot be
# resolved locally; must NOT be mangled into something that looks local).
got=$(sb_normalize_path '\\fileserver\share\doc.md')
aeq "//fileserver/share/doc.md" "$got" "other-host UNC passes through (slashes only)"

echo
echo "ALL PASS"
