#!/bin/bash
# Cross-platform portability guard for scripts/ — keeps the plugin runnable on macOS
# (/bin/bash is 3.2; BSD coreutils) and under Git Bash on Windows, not just Linux/GNU.
# Static checks (no bash 3.2 / BSD host available in CI) for the construct classes that
# silently break off-Linux. Surfaced by the 2026-06-02 cross-platform audit.
# Scans ALL shipped shell (0.45.4 — previously only scripts/, while the header claimed
# "both dirs"): root scripts/, bin/ (including the extensionless `sb` launcher, the
# user-facing CLI), and the devdocs skills' helper scripts. Deliberately NOT
# .claude/worktrees/ (untracked agent worktrees would re-introduce deleted files into
# the scan) and NOT tests/ (host-side, never shipped).
set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
ROOT="$REPO/scripts"
fail(){ echo "FAIL: $1"; printf '%s\n' "$2" | sed 's/^/    /'; exit 1; }
pass(){ echo "PASS: $1"; }
# Drop pure-comment matches (file:line:<ws>#...) — a portability linter checks code, not the
# comments that legitimately discuss these constructs.
nocomment(){ grep -vE ':[0-9]+:[[:space:]]*#'; }

# One file list, shared by every check. Repo file names contain no whitespace (the
# unquoted expansions below already rely on that, as does the awk xargs at check 8).
# ≥2 files always, so grep emits file: prefixes unconditionally.
ALL_SH=$(find "$ROOT" "$REPO/bin" "$REPO/.claude/skills" \( -name '*.sh' -o -name 'sb' \) -type f 2>/dev/null || true)

# Fail LOUD on an empty list. Every check below expands $ALL_SH unquoted as grep's file
# arguments; with no files grep falls back to STDIN and the gate HANGS (or, under a
# redirect, reports a vacuous pass) instead of failing — a scan that silently covers
# nothing is the exact "guard that cannot go red" class this suite exists to catch.
[ -n "$ALL_SH" ] || fail "no shell files found to scan" "ROOT=$ROOT REPO=$REPO"

# 1. No bash-4 array builtins (macOS /bin/bash is 3.2). Match actual usage `mapfile -`/`readarray -`,
#    not prose mentions.
h=$(grep -nE '(mapfile|readarray)[[:space:]]+-' $ALL_SH 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no mapfile/readarray usage (bash 4+)" || fail "bash-4 mapfile/readarray usage" "$h"

# 2. No other bash-4 isms: associative arrays / case-modification expansions.
h=$(grep -nE 'declare[[:space:]]+-A|local[[:space:]]+-A|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' $ALL_SH 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no assoc-arrays / \${x^^}\${x,,} (bash 4+)" || fail "bash-4 expansion" "$h"

# 3. No PCRE `grep -P` (BSD/macOS grep lacks it). Match literal `grep -P`/`grep -qP` usage in code.
h=$(grep -nE 'grep[[:space:]]+-[A-Za-z]*P([[:space:]]|$)' $ALL_SH 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no grep -P (PCRE; use -F/-E)" || fail "grep -P usage (not on BSD/macOS)" "$h"

# 4. GNU `stat -c` must always have a BSD `stat -f` (or other) fallback on the SAME line.
h=$(grep -n 'stat -c' $ALL_SH 2>/dev/null | grep -v 'stat -f' || true)
[ -z "$h" ] && pass "every 'stat -c' is paired with a 'stat -f' fallback" || fail "unpaired GNU stat -c" "$h"

# 5. GNU `date -d` must have a BSD fallback in the same file. Accepted BSD
#    forms: `date -v` (arithmetic), `date -r <epoch>` (epoch render), or
#    `date -j -f` (parse) — all legitimate pairings depending on the use.
#    Detection also covers `date -u -d` (R4: the old regex missed the -u
#    variant and let unpaired uses slip through unscanned).
#    Use grep -rnE | nocomment to exclude comment-only mentions.
for f in $(grep -nE 'date[[:space:]]+(-u[[:space:]]+)?(-d|--date)' $ALL_SH 2>/dev/null | nocomment | cut -d: -f1 | sort -u || true); do
  grep -qE 'date[[:space:]]+(-u[[:space:]]+)?(-v|-r|-j)' "$f" \
    || fail "GNU date -d without a BSD fallback (-v/-r/-j)" "$f"
done
pass "every 'date -d' file also has a BSD date fallback (-v/-r/-j)"

# 6. GNU `find -printf` must have a stat-based fallback in the same file.
for f in $(grep -lE 'find[^|]*-printf' $ALL_SH 2>/dev/null || true); do
  grep -qE 'stat (-f|-c)' "$f" || grep -q 'NOT GNU' "$f" || fail "find -printf without a stat fallback" "$f"
done
pass "every 'find -printf' file has a stat fallback (or documents avoidance)"

# 7. `timeout` usage must resolve gtimeout too (macOS coreutils-brew), not assume GNU-only.
h=$(grep -n 'command -v timeout' $ALL_SH 2>/dev/null | grep -v 'gtimeout' || true)
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

# 9. Possibly-empty array expansion under set -u (bash 3.2/4.0-4.3 hazard).
#    `"${ARR[@]}"` on an EMPTY array errors "unbound variable" under set -u on
#    bash < 4.4 — macOS /bin/bash is 3.2, so the subshell dies rc=1 with empty
#    stderr (the R8 macOS-CI stop-extract failure: WRAP_PREFIX=() expanded
#    bare at the claude invocation killed every Backend-1 extraction).
#    Rule: for every array initialized EMPTY (`NAME=()`) in a file, a bare
#    `"${NAME[@]}"` expansion is flagged unless (a) the line uses the portable
#    guard idiom `${NAME[@]+"${NAME[@]}"}`, or (b) the file length-checks
#    `${#NAME[@]}` (the other established guard shape). Heuristic tripwire,
#    not a parser — same doctrine as check 8.
h=""
for f in $ALL_SH; do
  for name in $(grep -oE '^[[:space:]]*(local -a )?[A-Za-z_][A-Za-z0-9_]*=\(\)' "$f" 2>/dev/null \
                 | sed 's/local -a //; s/^[[:space:]]*//; s/=()//' | sort -u); do
    grep -qF "\${#$name[@]}" "$f" && continue
    bad=$( { grep -nF "\"\${$name[@]}\"" "$f"; grep -nF "\"\${$name[*]}\"" "$f"; } 2>/dev/null \
           | grep -vF "[@]+\"" || true)
    [ -n "$bad" ] && h="$h
$f: array $name=() expanded bare: $bad"
  done
done
[ -z "$h" ] && pass "no bare empty-array expansion under set -u (bash <4.4 hazard)" \
  || fail "bare \"\${ARR[@]}\" on a possibly-empty array — use \${ARR[@]+\"\${ARR[@]}\"} or a \${#ARR[@]} guard" "$h"

# 10. No DUPLICATE top-level function definitions within a single script. A second
#     `name() {` silently SHADOWS the first in bash (last def wins) — the 0.24.48
#     sb_validate_wiki regression: a count-returning def was added above a
#     pre-existing silent one, so the active function returned nothing and the
#     telemetry that depended on it was dead, with every test still green.
h=""
for f in $ALL_SH; do
  dups=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$f" 2>/dev/null | sort | uniq -d)
  [ -n "$dups" ] && h="$h
$f: duplicated function def(s): $(printf '%s' "$dups" | tr '\n' ' ')"
done
[ -z "$h" ] && pass "no duplicated function definitions (shadowing hazard)" \
  || fail "duplicate function definition — the second silently shadows the first (last-def-wins)" "$h"

# 11. No GNU-only regex escapes (\b \w \s \d, and \xNN hex) inside a sed/grep
#     PROGRAM. BSD/macOS sed & grep treat each as the LITERAL char, so the pattern
#     silently matches NOTHING (the 0.28.2 sb_strip_ansi + verify-gate bugs: ANSI
#     not stripped; the test/vague-word gates never fired). Portable forms: build
#     a literal byte in bash ($'\xNN'), use a POSIX class ([[:alnum:]_] /
#     [[:space:]] / [[:digit:]]), or `grep -w` instead of \b…\b. The leading
#     boundary keeps "parsed"/"used" from matching the sed/grep word.
h=$(grep -nE '(\||;|^|[[:space:]])(sed|grep)[[:space:]]' $ALL_SH 2>/dev/null | nocomment \
  | grep -E '\\[bwsdx]' | grep -vF "\$'" | grep -v 'NOT GNU' || true)
[ -z "$h" ] && pass "no GNU-only regex escapes (\\b \\w \\s \\d \\x) in sed/grep programs" \
  || fail "GNU-only regex escape in a sed/grep program (BSD matches nothing) — use a literal byte / POSIX class / grep -w" "$h"

echo; echo "ALL PASS"
