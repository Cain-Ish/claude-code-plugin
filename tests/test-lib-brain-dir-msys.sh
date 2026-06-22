#!/bin/bash
# lib.sh MSYS-normalizes an inherited BRAIN_DIR so GNU tar/rsync/ln (which mis-handle a leading Windows
# drive letter — the dream_accept bug class, 0.33.10) always see a /c/... path. cygpath exists only on
# git-bash/Cygwin; on POSIX the normalize is a no-op, so an already-MSYS/POSIX path MUST pass through
# unchanged. Behavioral: actually source lib.sh with an inherited BRAIN_DIR and read what it resolves to.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

# What does lib.sh resolve BRAIN_DIR to, given an inherited value? (subshell; print the result)
resolved(){ BRAIN_DIR="$1" bash -c 'source "'"$ROOT"'/scripts/lib.sh"; printf "%s" "$BRAIN_DIR"'; }

# (1) No-op path (runs everywhere incl. Linux/macOS CI): an already-MSYS/POSIX path is unchanged.
tmp=$(mktemp -d)
got=$(resolved "$tmp")
[ "$got" = "$tmp" ] || fail "lib.sh altered an already-normalized BRAIN_DIR ($tmp -> $got)"
pass "lib.sh leaves an already-MSYS/POSIX BRAIN_DIR unchanged (no-op on POSIX)"

# (2) Windows conversion (only meaningful where cygpath + drive-letter paths exist → git-bash).
if command -v cygpath >/dev/null 2>&1; then
  win=$(cygpath -w "$tmp")               # the SAME directory in Windows form (C:\...)
  got=$(resolved "$win")
  case "$got" in
    *\\*) fail "lib.sh did NOT strip backslashes from a Windows-form BRAIN_DIR ($win -> $got)" ;;
    /*)   pass "lib.sh normalized a Windows-form BRAIN_DIR to MSYS form ($win -> $got)" ;;
    *)    fail "lib.sh produced an unexpected BRAIN_DIR ($win -> $got)" ;;
  esac
  [ "$got" = "$tmp" ] || fail "normalized BRAIN_DIR no longer points at the original dir ($got != $tmp)"
  pass "normalized Windows-form BRAIN_DIR round-trips to the original directory"
else
  pass "Windows-form normalization (skipped — no cygpath; the no-op path is verified above)"
fi
rm -rf "$tmp"
echo; echo "ALL PASS"
