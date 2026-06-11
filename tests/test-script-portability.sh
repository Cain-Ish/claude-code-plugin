#!/bin/bash
# Cross-platform portability guard for scripts/ — keeps the plugin runnable on macOS
# (/bin/bash is 3.2; BSD coreutils) and under Git Bash on Windows, not just Linux/GNU.
# Static checks (no bash 3.2 / BSD host available in CI) for the construct classes that
# silently break off-Linux. Surfaced by the 2026-06-02 cross-platform audit.
# Extended to cover cost-router/scripts/ in addition to root scripts/.
set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
ROOT="$REPO/scripts"
CR_ROOT="$REPO/cost-router/scripts"
fail(){ echo "FAIL: $1"; printf '%s\n' "$2" | sed 's/^/    /'; exit 1; }
pass(){ echo "PASS: $1"; }
# Drop pure-comment matches (file:line:<ws>#...) — a portability linter checks code, not the
# comments that legitimately discuss these constructs.
nocomment(){ grep -vE ':[0-9]+:[[:space:]]*#'; }

# Collect all .sh files from both dirs for checks that need a file list.
ALL_SH=$(find "$ROOT" "$CR_ROOT" -name '*.sh' 2>/dev/null || true)

# 1. No bash-4 array builtins (macOS /bin/bash is 3.2). Match actual usage `mapfile -`/`readarray -`,
#    not prose mentions.
h=$(grep -rnE '(mapfile|readarray)[[:space:]]+-' "$ROOT" "$CR_ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no mapfile/readarray usage (bash 4+)" || fail "bash-4 mapfile/readarray usage" "$h"

# 2. No other bash-4 isms: associative arrays / case-modification expansions.
h=$(grep -rnE 'declare[[:space:]]+-A|local[[:space:]]+-A|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' "$ROOT" "$CR_ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no assoc-arrays / \${x^^}\${x,,} (bash 4+)" || fail "bash-4 expansion" "$h"

# 3. No PCRE `grep -P` (BSD/macOS grep lacks it). Match literal `grep -P`/`grep -qP` usage in code.
h=$(grep -rnE 'grep[[:space:]]+-[A-Za-z]*P([[:space:]]|$)' "$ROOT" "$CR_ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no grep -P (PCRE; use -F/-E)" || fail "grep -P usage (not on BSD/macOS)" "$h"

# 4. GNU `stat -c` must always have a BSD `stat -f` (or other) fallback on the SAME line.
h=$(grep -rn 'stat -c' "$ROOT" "$CR_ROOT" 2>/dev/null | grep -v 'stat -f' || true)
[ -z "$h" ] && pass "every 'stat -c' is paired with a 'stat -f' fallback" || fail "unpaired GNU stat -c" "$h"

# 5. GNU `date -d` must have a BSD fallback in the same file. Accepted BSD
#    forms: `date -v` (arithmetic), `date -r <epoch>` (epoch render), or
#    `date -j -f` (parse) — all legitimate pairings depending on the use.
#    Detection also covers `date -u -d` (R4: the old regex missed the -u
#    variant and let unpaired uses slip through unscanned).
#    Use grep -rnE | nocomment to exclude comment-only mentions.
for f in $(grep -rnE 'date[[:space:]]+(-u[[:space:]]+)?(-d|--date)' "$ROOT" "$CR_ROOT" 2>/dev/null | nocomment | cut -d: -f1 | sort -u || true); do
  grep -qE 'date[[:space:]]+(-u[[:space:]]+)?(-v|-r|-j)' "$f" \
    || fail "GNU date -d without a BSD fallback (-v/-r/-j)" "$f"
done
pass "every 'date -d' file also has a BSD date fallback (-v/-r/-j)"

# 6. GNU `find -printf` must have a stat-based fallback in the same file.
for f in $(grep -rlE 'find[^|]*-printf' "$ROOT" "$CR_ROOT" 2>/dev/null || true); do
  grep -qE 'stat (-f|-c)' "$f" || grep -q 'NOT GNU' "$f" || fail "find -printf without a stat fallback" "$f"
done
pass "every 'find -printf' file has a stat fallback (or documents avoidance)"

# 7. `timeout` usage must resolve gtimeout too (macOS coreutils-brew), not assume GNU-only.
h=$(grep -rn 'command -v timeout' "$ROOT" "$CR_ROOT" 2>/dev/null | grep -v 'gtimeout' || true)
[ -z "$h" ] && pass "timeout resolution includes gtimeout (macOS)" || fail "timeout without gtimeout fallback" "$h"

# 8. No `case` statement inside a $(...) command substitution. macOS /bin/bash is 3.2, whose
#    parser extracts the comsub body by naive paren-matching and mis-counts the `)` that closes
#    each case pattern as the `$(` terminator -> a hard "syntax error" at LOAD time, so the WHOLE
#    script fails to parse (not just the scan that uses it). Fixed by the bash 4.0 parser rewrite,
#    so it is NOT reproducible with `bash -n` on a 4+/5.x CI host -- this static depth-scanner is
#    the only guard that catches it. Fix: use `[[ "$x" == pat* ]]` glob-match inside the comsub,
#    or lift the `case` out of the $(...). Depth is tracked by counting `$(` opens vs `)` closes;
#    a `case` keyword seen while a comsub is still open (carried in from a prior line) -- or an
#    inline `$(case ...)` -- is the hazard. Verified to flag only a real case-in-comsub (the common
#    one-line `case "$x" in ''|*[!0-9]*) x=N ;; esac` numeric guard sits at depth 0, never flagged).
#    The depth model is a HEURISTIC, not a bash parser: it can't see quoting, so a literal `$(` in a
#    string could over-open, and naive `)`-counting could under/over-close. It is exact for the
#    house style here (every comsub opens and closes deterministically); it is a tripwire for the
#    real hazard, not a proof. Keep comsubs balanced per line and it stays sound.
h=$(printf '%s\n' $ALL_SH | xargs awk '
  FNR==1 { depth=0 }
  {
    line=$0; pre=depth
    inline = (line ~ /\$\([ \t]*case[ \t]/)
    kw = (line ~ /(^|[ \t;&|])case[ \t]/) && line !~ /^[[:space:]]*#/
    if ((pre>0 && kw) || inline) print FILENAME":"FNR":"line
    o=line; ocnt=gsub(/\$\(/,"",o)
    c=line; ccnt=gsub(/\)/,"",c)
    depth += ocnt - ccnt
    if (depth<0) depth=0
  }
' 2>/dev/null || true)
[ -z "$h" ] && pass "no case-in-\$() comsub (bash 3.2 parser hazard)" || fail "case inside \$(...) command substitution — breaks bash 3.2 (macOS /bin/bash); use [[ ]] glob-match or lift the case out" "$h"

echo; echo "ALL PASS"
