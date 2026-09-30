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
RUN_RE='(^|[^A-Za-z0-9_./-])(bash|sh|source|exec)[[:space:]]+[^[:space:];|&]*(merge-project-update|stop-extract|pre-compact)\.sh|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*(merge-project-update|stop-extract|pre-compact)\.sh|sb_inc_wiki_writes'
bad=""; checked=0
for f in "$T"/test-*.sh; do
  b=$(basename "$f"); [ "$b" = "$self" ] && continue
  grep -qE 'merge-project-update\.sh|stop-extract\.sh|pre-compact\.sh|sb_inc_wiki_writes' "$f" || continue
  case " $STATIC_SCANNERS " in
    *" $b "*)
      if grep -vE '^[[:space:]]*#' "$f" | grep -qE "$RUN_RE"; then
        bad="$bad $b(listed-as-static-scanner-but-runs-a-projects-writer)"
      fi
      continue ;;
  esac
  checked=$((checked+1))
  has_braindir=$(grep -cE '(^|[; ])(export +)?BRAIN_DIR=' "$f")
  real_braindir=$(grep -cE 'BRAIN_DIR="?\$\{?HOME\}?/\.second-brain' "$f")
  home_temp=$(grep -cE '(export +)?HOME=.*(\$\{?(TMP|T|TMPDIR|BD|SB|SANDBOX)\b|mktemp|/tmp/)' "$f")
  if [ "$has_braindir" -eq 0 ]; then
    [ "$home_temp" -gt 0 ] || bad="$bad $b(no-BRAIN_DIR,no-temp-HOME)"
  elif [ "$real_braindir" -gt 0 ] && [ "$home_temp" -eq 0 ]; then
    bad="$bad $b(BRAIN_DIR=real,no-HOME-redirect)"
  fi
done

[ -n "$bad" ] && fail "test(s) write under projects/ without isolating BRAIN_DIR/HOME from the real ~/.second-brain:$bad"
pass "all $checked tests touching merge/stop/pre-compact/sb_inc_wiki_writes isolate BRAIN_DIR/HOME from the real KB"
echo; echo "ALL PASS"
