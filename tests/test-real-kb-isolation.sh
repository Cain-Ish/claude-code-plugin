#!/bin/bash
# Guard (0.24.32): a test that invokes a script which writes under $BRAIN_DIR/projects/
# (merge-project-update.sh / stop-extract.sh / pre-compact.sh) or calls sb_inc_wiki_writes
# MUST isolate BRAIN_DIR (or HOME, since BRAIN_DIR defaults to $HOME/.second-brain) away from
# the real ~/.second-brain — else a side-effect (e.g. the per-project .wiki-writes counter)
# pollutes the user's home dir. The 0.24.31 live deep-test found 4 tests dropping
# projects/tmp.XXXX/ into the real KB on every suite run. This guard makes the class
# unshippable: it fails at authoring time instead of silently in ~/.second-brain.
#
# Failure modes it catches:
#   (1) invokes the script but sets NO BRAIN_DIR and NO temp HOME → defaults to the real KB.
#   (2) sets BRAIN_DIR="$HOME/.second-brain" (the real path) without redirecting HOME to a temp.
# Safe patterns (NOT flagged): BRAIN_DIR set to any non-real path (a temp var / mktemp result),
#   or HOME redirected to a temp dir before BRAIN_DIR defaults off it.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; T="$ROOT/tests"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
self="$(basename "${BASH_SOURCE[0]:-$0}")"

# Static source scanners read these scripts' TEXT and never run them: test-script-portability.sh
# names stop-extract.sh in its hook-entry list (check 17 greps each for `<<<`) and in a comment,
# which tripped this guard in run-all (F8). Exempt by name — and only while the file still never
# RUNS one: no non-comment line that executes (bash/sh/source/exec …NAME.sh), assigns a path
# ending in one to a variable (the `SCRIPT=…; bash "$SCRIPT"` idiom), or calls sb_inc_wiki_writes.
STATIC_SCANNERS="test-script-portability.sh"
# The run patterns, one alternative per way a test can execute a writer:
#   (1) `bash|sh|source|exec …NAME.sh`           (2) `VAR=…NAME.sh` (the SCRIPT=…; bash "$SCRIPT" idiom)
#   (3) a DIRECT call at command position — `"$ROOT/scripts/stop-extract.sh" <in`, `… | "$S/pre-compact.sh"`,
#       `$(… "$ROOT/…/merge-project-update.sh" …)`: no interpreter word, so (1) never saw it and a
#       static scanner that started calling a writer directly stayed exempt.   (4) sb_inc_wiki_writes.
# (3) needs the path at the START of a command: line start or after ; & | ( $( — so `grep -q NAME.sh`,
# `[ -f "$ROOT/…/NAME.sh" ]` and `for f in …NAME.sh` (the path is an argument there) stay unflagged.
RUN_RE='(^|[^A-Za-z0-9_./-])(bash|sh|source|exec)[[:space:]]+[^[:space:];|&]*(merge-project-update|stop-extract|pre-compact)\.sh|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*(merge-project-update|stop-extract|pre-compact)\.sh|(^|[;&|(])[[:space:]]*"?[^[:space:]";|&()]*(merge-project-update|stop-extract|pre-compact)\.sh"?([[:space:]]|$|<|>)|sb_inc_wiki_writes'
bad=""; checked=0

# scan_file <path>: append a finding to $bad and bump $checked, exactly as the real scan does.
scan_file() {
  local f="$1" b
  b=$(basename "$f")
  grep -qE 'merge-project-update\.sh|stop-extract\.sh|pre-compact\.sh|sb_inc_wiki_writes' "$f" || return 0
  case " $STATIC_SCANNERS " in
    *" $b "*)
      if grep -vE '^[[:space:]]*#' "$f" | grep -qE "$RUN_RE"; then
        bad="$bad $b(listed-as-static-scanner-but-runs-a-projects-writer)"
      fi
      return 0 ;;
  esac
  checked=$((checked+1))
  local has_braindir real_braindir home_temp
  has_braindir=$(grep -cE '(^|[; ])(export +)?BRAIN_DIR=' "$f")
  real_braindir=$(grep -cE 'BRAIN_DIR="?\$\{?HOME\}?/\.second-brain' "$f")
  home_temp=$(grep -cE '(export +)?HOME=.*(\$\{?(TMP|T|TMPDIR|BD|SB|SANDBOX)\b|mktemp|/tmp/)' "$f")
  if [ "$has_braindir" -eq 0 ]; then
    [ "$home_temp" -gt 0 ] || bad="$bad $b(no-BRAIN_DIR,no-temp-HOME)"
  elif [ "$real_braindir" -gt 0 ] && [ "$home_temp" -eq 0 ]; then
    bad="$bad $b(BRAIN_DIR=real,no-HOME-redirect)"
  fi
}

# --- Canary: the detector must FLAG an unisolated direct call, or a green run proves nothing -------
# Fixture tests are built in a temp dir and scanned with the real scan_file. The names match the
# live STATIC_SCANNERS entry for the static-scanner cases (scan_file keys on the basename).
CAN=$(mktemp -d); trap 'rm -rf "$CAN"' EXIT
canary() {   # canary <basename> <expect: flag|clean> <body…> — scan a one-file fixture, compare the verdict
  local name="$1" expect="$2" body="$3" got
  printf '%s\n' "$body" > "$CAN/$name"
  bad=""; checked=0
  scan_file "$CAN/$name"
  if [ -n "$bad" ]; then got=flag; else got=clean; fi
  [ "$got" = "$expect" ] || fail "canary $name: expected $expect, detector said $got ($bad) for: $body"
}
# An ordinary test that calls a writer directly with NO BRAIN_DIR / temp HOME is flagged …
canary test-canary-direct.sh flag '"$ROOT/scripts/stop-extract.sh" < "$IN"'
canary test-canary-direct-pipe.sh flag 'printf x | "$ROOT/scripts/pre-compact.sh"'
# … and is clean once it isolates.
canary test-canary-isolated.sh clean 'BRAIN_DIR="$TMP/b" "$ROOT/scripts/stop-extract.sh" < "$IN"'
# A listed static scanner that only NAMES writers stays exempt; one that calls them directly is flagged.
canary test-script-portability.sh clean 'for s in stop-extract.sh pre-compact.sh; do grep -q "<<<" "$ROOT/scripts/$s"; done'
canary test-script-portability.sh flag '"$ROOT/scripts/stop-extract.sh" < "$IN"'
canary test-script-portability.sh flag 'out=$("$ROOT/scripts/merge-project-update.sh" x)'
canary test-script-portability.sh flag 'cat in | $ROOT/scripts/pre-compact.sh'
canary test-script-portability.sh flag 'bash "$ROOT/scripts/stop-extract.sh"'
canary test-script-portability.sh clean '[ -f "$ROOT/scripts/stop-extract.sh" ] && grep -c x stop-extract.sh'
pass "canary: the detector flags unisolated direct calls and leaves name-only scanners alone"
bad=""; checked=0

for f in "$T"/test-*.sh; do
  [ "$(basename "$f")" = "$self" ] && continue
  scan_file "$f"
done

[ -n "$bad" ] && fail "test(s) write under projects/ without isolating BRAIN_DIR/HOME from the real ~/.second-brain:$bad"
pass "all $checked tests touching merge/stop/pre-compact/sb_inc_wiki_writes isolate BRAIN_DIR/HOME from the real KB"
echo; echo "ALL PASS"
