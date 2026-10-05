#!/bin/bash
# pins: SB_SUITE_REAL_HOME_PATH — the G3 suite guard is the subject: set to a fake home to prove it trips (and is inert unset)
# pins: SB_SUITE_GUARD_MARKER — the guard's trip marker is the subject: pointed at a scratch file to prove it is written
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

# (3) G3 suite guard: with SB_SUITE_REAL_HOME_PATH set, a BRAIN_DIR resolving to EXACTLY
# <real home>/.second-brain, or a knowledge dir resolving to <real home>/knowledge, trips the guard.
# A trip NEVER exits the sourcing script (an `exit 1` from lib.sh killed the PreToolUse guard that
# sourced it: rc=1, no verdict, the tool ran) and never leaves an empty path (callers reached
# `mkdir -p /wiki/...`). Instead: a loud stderr line, the SB_SUITE_GUARD_MARKER file is written
# (run-all fails the whole run on it), and the dir variable points at a quarantine dir next to the
# marker, so nothing touches the real dir. Any other dir, even one under the real home, and the
# variable unset, pass untouched.
fakehome=$(mktemp -d); qroot=$(mktemp -d); marker="$qroot/guard-tripped"
guarded(){ env -u KNOWLEDGE_DIR -u CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR BRAIN_DIR="$1" SB_SUITE_REAL_HOME_PATH="$2" SB_SUITE_GUARD_MARKER="$marker" HOME="$tmp" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"; echo "SOURCED BRAIN_DIR=$BRAIN_DIR"' 2>&1; }
out=$(guarded "$fakehome/.second-brain" "$fakehome"); rc=$?
case "$out" in *"suite guard"*) ;; *) fail "suite guard did not fire for the real <home>/.second-brain ($out)" ;; esac
case "$out" in *SOURCED*) ;; *) fail "the suite guard stopped the sourcing script (rc=$rc) — a guard that sources lib.sh would lose its verdict ($out)" ;; esac
case "$out" in *"SOURCED BRAIN_DIR=$marker.quarantine/brain"*) ;; *) fail "the tripped BRAIN_DIR does not point at the quarantine next to the marker ($out)" ;; esac
[ -s "$marker" ] || fail "the suite guard trip did not write SB_SUITE_GUARD_MARKER ($marker)"
[ -d "$marker.quarantine/brain" ] || fail "the quarantine brain dir was not created"
[ ! -e "$fakehome/.second-brain" ] || fail "the real-looking brain dir was created"
pass "suite guard: a real brain dir is quarantined (loud line, marker written, sourcing continues)"
rm -f "$marker"
if command -v cygpath >/dev/null 2>&1; then
  out=$(guarded "$fakehome/.second-brain/" "$(cygpath -w "$fakehome")")
  case "$out" in *"suite guard"*"SOURCED BRAIN_DIR=$marker.quarantine/brain"*) pass "suite guard matches across Windows-form real home + trailing slash" ;; *) fail "suite guard missed a Windows-form real home ($out)" ;; esac
  rm -f "$marker"
fi
out=$(guarded "$fakehome/sandbox/.second-brain" "$fakehome")
case "$out" in *"SOURCED BRAIN_DIR=$fakehome/sandbox/.second-brain") pass "suite guard leaves other dirs under the real home alone" ;; *) fail "suite guard tripped on a non-exact dir ($out)" ;; esac
out=$(guarded "$fakehome/.second-brain" "")
case "$out" in *"SOURCED BRAIN_DIR=$fakehome/.second-brain") pass "suite guard is inert when SB_SUITE_REAL_HOME_PATH is unset/empty" ;; *) fail "suite guard fired with the var empty ($out)" ;; esac
[ ! -e "$marker" ] || fail "an untripped guard wrote the marker"
# Knowledge dir, checked at SOURCE time (not only inside sb_knowledge_dir, whose "" used to vanish in
# a caller's $(...)): the variables point at the quarantine right after sourcing, and
# sb_knowledge_dir returns it, non-empty, rc 0.
out=$(env -u CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR KNOWLEDGE_DIR="$fakehome/knowledge" BRAIN_DIR="$tmp" HOME="$tmp" SB_SUITE_REAL_HOME_PATH="$fakehome" SB_SUITE_GUARD_MARKER="$marker" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"; echo "KD=$KNOWLEDGE_DIR"; d=$(sb_knowledge_dir); echo "rc=$? got=$d"' 2>&1)
case "$out" in *"suite guard"*) ;; *) fail "knowledge guard did not fire at source time ($out)" ;; esac
case "$out" in *"KD=$marker.quarantine/knowledge"*) ;; *) fail "KNOWLEDGE_DIR was not pointed at the quarantine at source time ($out)" ;; esac
case "$out" in *"rc=0 got=$marker.quarantine/knowledge"*) ;; *) fail "sb_knowledge_dir did not return the quarantine path (rc 0, non-empty) ($out)" ;; esac
[ -s "$marker" ] || fail "the knowledge guard trip did not write the marker"
[ ! -e "$fakehome/knowledge" ] || fail "the real-looking knowledge dir was created"
pass "knowledge guard runs at source time: quarantine path, marker written, sb_knowledge_dir never empty"
# No marker variable (a test run by hand with SB_SUITE_REAL_HOME_PATH set): still quarantined, never the real dir.
out=$(env -u SB_SUITE_GUARD_MARKER -u KNOWLEDGE_DIR -u CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR BRAIN_DIR="$fakehome/.second-brain" HOME="$tmp" SB_SUITE_REAL_HOME_PATH="$fakehome" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"; echo "SOURCED BRAIN_DIR=$BRAIN_DIR"' 2>&1)
case "$out" in *"SOURCED BRAIN_DIR="*"sb-suite-guard.quarantine/brain"*) pass "with no marker variable the guard still quarantines (never the real dir)" ;; *) fail "unset marker: the guard did not fall back to a quarantine ($out)" ;; esac
rm -rf "$qroot"

# (4) G3 USERPROFILE sandbox: native Windows node reads USERPROFILE, not HOME, for os.homedir(). Inside
# run-all (SB_SUITE_REAL_HOME_PATH inherited from the runner), node's home must NOT be the real home.
# Path forms are normalized (backslashes, drive letter -> MSYS form, case) before comparing.
if [ -n "${SB_SUITE_REAL_HOME_PATH:-}" ] && command -v node >/dev/null 2>&1; then
  nh=$(node -e 'console.log(require("os").homedir())' | tr -d '\r')
  # norm PATH: lib.sh's own sb_normalize_path (backslash, drive letter -> MSYS form), no trailing
  # slash, lowercased where cygpath exists (case-insensitive Windows paths).
  norm(){ BRAIN_DIR="$tmp" bash -c 'source "$1/scripts/lib.sh"; p=$(sb_normalize_path "$2"); p="${p%/}"; if command -v cygpath >/dev/null 2>&1; then printf "%s" "$p" | tr "A-Z" "a-z"; else printf "%s" "$p"; fi' _ "$ROOT" "$1"; }
  [ -n "$nh" ] || fail "USERPROFILE sandbox: node printed no homedir"
  [ "$(norm "$nh")" != "$(norm "$SB_SUITE_REAL_HOME_PATH")" ] \
    || fail "USERPROFILE sandbox: node's os.homedir() ($nh) is the REAL home ($SB_SUITE_REAL_HOME_PATH) — run-all did not sandbox USERPROFILE"
  pass "USERPROFILE sandbox: node's os.homedir() ($nh) is not the real home"
elif [ -z "${SB_SUITE_REAL_HOME_PATH:-}" ]; then
  echo "SKIP: USERPROFILE sandbox check NOT RUN — SB_SUITE_REAL_HOME_PATH is unset (only tests/run-all.sh sets it); this is not a pass"
else
  echo "SKIP: USERPROFILE sandbox check NOT RUN — node is not on PATH; this is not a pass"
fi
rm -rf "$fakehome"
rm -rf "$tmp"
echo; echo "ALL PASS"
