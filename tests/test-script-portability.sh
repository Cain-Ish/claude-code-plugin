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

# 12. No `$(basename …)` / `$(dirname …)` inside a `while … read` loop body in a HOT-PATH
#     script. On MSYS each external process costs ~30-60ms (vs ~1ms on Linux), so a per-item
#     spawn in a loop over hundreds of files is seconds on the dev platform and invisible on
#     CI. Measured 2026-08-23: sb_prune_transcripts (runs on EVERY Stop hook) spent ~2 spawns
#     per archived transcript — test-transcript-archive 258s on Windows vs 8s on Linux, and the
#     local suite could never go green (ec=124 on 9-11 tests). Both have zero-cost builtins:
#     "${x##*/}" for basename, "${x%/*}" for dirname. Scoped to the scripts that run per hook
#     tick or per drainer tick; a one-off setup script may still spawn freely.
#     Hot path = every script wired into hooks/hooks.json (runs per tool call / per session
#     event) plus the drainer tick chain. Derived from hooks.json so the list cannot drift,
#     and so this file never spells out hook-script names as data (test-real-kb-isolation
#     greps test files for mentions of the capture-hook scripts and would flag this one).
HOT=$(jq -r '.. | .command? // empty' "$REPO/hooks/hooks.json" 2>/dev/null \
  | grep -oE 'scripts/[a-z0-9-]+\.sh' | sort -u)
HOT="$HOT
scripts/lib.sh
scripts/extract-drain.sh
scripts/sb-prune-archives.sh
scripts/kb-project-backfill.sh
scripts/maintain-deterministic.sh
scripts/brain-os-run.sh"
h=""
for f in $HOT; do
  [ -f "$REPO/$f" ] || continue
  # Track `while … read` nesting with awk: flag a $(basename|dirname …) seen while depth>0.
  m=$(awk -v F="$f" '
    /^[[:space:]]*#/ { next }
    /while[[:space:]].*read[[:space:]]/ { depth++ }
    depth>0 && /\$\((basename|dirname)[[:space:]]/ { printf "%s:%d:%s\n", F, NR, $0 }
    depth>0 && /^[[:space:]]*done([[:space:]]|$|<)/ { depth-- }
  ' "$REPO/$f")
  [ -n "$m" ] && h="${h}${m}"$'\n'
done
[ -z "$h" ] && pass "no \$(basename/dirname) spawn inside a while-read loop in hot-path scripts (MSYS spawn tax)" \
  || fail "per-item basename/dirname spawn inside a while-read loop in a hot-path script — use \"\${x##*/}\" / \"\${x%/*}\" (each spawn is ~30-60ms on MSYS; this class made the local suite un-runnable)" "$h"

# 13. jq must never append DIRECTLY to a *.jsonl file via `>>` (the D120 class):
#     the native jq.exe on Windows inherits a plain end-of-file handle rather than
#     an O_APPEND one, so two concurrent writers race at the same offset and a
#     shorter record overwrites the head of a longer one — a torn JSONL line.
#     Only bash's own `printf`/`echo` of an already-built line may append; a
#     jq call may still be used to ESCAPE fields, but only as a $(...) argument
#     to that printf/echo, never as the command whose own stdout is redirected.
#     Heuristic (not a parser, same doctrine as checks 8-12): collect every
#     variable in the file assigned a value ending in .jsonl" (handling an
#     optional `local ` prefix), then flag any line where `jq` itself — not a
#     $(jq ...) substitution nested inside another command — is redirected with
#     `>>` into that variable. No literal-jsonl-path form is whitelisted.
h=""
for f in $ALL_SH; do
  for jvar in $(grep -oE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*\.jsonl"' "$f" 2>/dev/null \
                 | sed -E 's/^[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' | sort -u); do
    bad=$(grep -nE "^[[:space:]]*jq[[:space:]].*>>[[:space:]]*\"?\\\$\{?${jvar}\}?\"?" "$f" 2>/dev/null || true)
    [ -n "$bad" ] && h="$h
$f: jq appends DIRECTLY to \$$jvar (a *.jsonl path) via >> — not atomic on Windows: $bad"
  done
done
[ -z "$h" ] && pass "no jq output appended DIRECTLY (>>) to a *.jsonl path (D120 class)" \
  || fail "jq's own stdout redirected DIRECTLY (>>) into a *.jsonl path — build the line first (jq -c into a var) and append it with printf/echo instead" "$h"

# 14. No heredoc opened INSIDE a $(...) command substitution (issue #100). bash 3.2's
#     $(...) parser scans the body by naive quote matching and does not honour the
#     heredoc boundary, so any unbalanced quote in the heredoc body (a `'` inside an
#     awk character class was the live case) swallows the closing `)` and the script
#     fails to PARSE on macOS /bin/bash — a SessionStart hook silently dead on every
#     Mac. `bash -n` on a 4.x/5.x host cannot see it. Use `IFS= read -r -d '' VAR <<'EOF'`
#     (no comsub) or a function that prints the text instead.
h=""
for f in $ALL_SH; do
  bad=$(grep -nE '\$\([^)]*<<-?[[:space:]]*['"'"'"]?[A-Za-z_]+' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  [ -n "$bad" ] && h="$h
$f: heredoc opened inside \$(...) — unparseable on bash 3.2 when the body has an unbalanced quote: $bad"
done
[ -z "$h" ] && pass "no heredoc inside a \$(...) command substitution (bash 3.2 parse hazard, issue #100)" \
  || fail "heredoc opened inside \$(...) — use IFS= read -r -d '' VAR <<'EOF' instead" "$h"

# 15. The suite must invoke node tooling through the LOCAL .bin shim, never `npx`.
# npx is an npm wrapper with its own failure modes ahead of the tool: on npm
# 11.17.0 / node 24 it dies with "Class extends value undefined is not a
# constructor or null" before vitest starts, and run-all scores that as
# `FAIL vitest (mcp)` — an 837-test green suite reported as a red lane, which is
# worse than no signal because it trains everyone to ignore the lane.
# $ROOT is scripts/; this guard deliberately reaches into tests/ instead, so the
# path is spelled from $REPO. A missing file would make the grep vacuously pass,
# so the file's existence is asserted first.
RA="$REPO/tests/run-all.sh"
[ -f "$RA" ] || fail "tests/run-all.sh missing — the npx guard below cannot hold" "$RA"
# -H so the output carries a file: prefix and nocomment can recognise it — the
# comment in run-all.sh explaining this very rule must not trip the rule.
n=$(grep -HnE '(^|[[:space:]])npx([[:space:]]|$)' "$RA" | nocomment || true)
[ -z "$n" ] && pass "run-all.sh invokes node tooling via ./node_modules/.bin, not npx" \
  || fail "run-all.sh calls npx — an npm wrapper failure will read as a test failure; use ./node_modules/.bin/<tool>" "$n"

# 16. No read of stdin through the /dev/stdin (or /dev/fd/0) PATH. Opening that path is a fresh
#     open(2) of whatever fd 0 is, and Claude Code spawns hooks from Node, whose stdio pipes are
#     socketpairs on Linux (open -> ENXIO "No such device or address") and non-Cygwin named pipes
#     on native Windows (Git-Bash: "/dev/stdin: No such file or directory"). `RAW=$(</dev/stdin)`
#     therefore read NOTHING under a real session while every bash-piped test stayed green (P-H3:
#     protocol-guard.sh card/pre exited silently, SubagentStart logged bad-payload per dispatch).
#     Read fd 0 itself: `IFS= read -r -d '' VAR` / `read -N` (no spawn) or `$(cat)`. awk's
#     `getline < "/dev/stdin"` is exempt: gawk, mawk and BSD awk map that name to fd 0 internally.
h=$(grep -nE '/dev/(stdin|fd/0)' $ALL_SH 2>/dev/null | nocomment | grep -v 'getline' || true)
[ -z "$h" ] && pass "no stdin read through the /dev/stdin or /dev/fd/0 path (empty under Node-spawned hooks)" \
  || fail "stdin read through the /dev/stdin path — Node's hook pipes (Linux socketpairs, Windows named pipes) cannot be reopened; use IFS= read -r -d '' VAR or \$(cat)" "$h"

# 17. Every remaining `<<<` here-string in a HOOK-ENTRY script (the 4 PreToolUse guards,
#     protocol-guard.sh, stop-verify-gate.sh, stop-extract.sh, subagent-capture.sh) must be either
#     one of the size-gated feed helpers' own lines — matched as the WHOLE line, listed below (the
#     guards' _fp_feed, protocol-guard's pg_feed, and the pre-existing _SPINE_TXT/_SPINE_SPANS
#     reads test-guard-wiring.sh's SEC-C1 lock caps at 8192 chars) — or carry an inline
#     `# <<<-bounded: <why the text is < 8 KiB>` annotation on the SAME line, or in the comment
#     immediately above it (wrapped over at most two more comment lines). RR-SF1/RR-SF2 (0.54.1): a
#     bare `<<<` on payload/session/transcript-derived text hangs for good on MSYS at
#     65,536..~65,650 bytes — past the hook's timeout, a fail-open, not just slow. F8: the
#     exemption used to be a token ANYWHERE on the line (`x <<< "$BIG"; : "$_pf_t"` passed), an
#     annotation on any code line exempted the next line too, and one annotation carried through
#     any number of comment lines; awk's errors went to /dev/null with its status unread (a scan
#     that cannot run passed); and the scripts were a hand-kept list that had missed
#     session-load.sh's 13 bare here-strings. HOOK_ENTRY is now every script a hooks/hooks.json
#     command runs, plus what those scripts `source` (lib.sh, and kb-schema.sh through it).
#     Round 2: the scan now ALSO covers (a) merge-project-update.sh and
#     merge-persona-signals.sh — children of stop-extract.sh/pre-compact.sh, not hooks.json
#     entries, so the derivation above cannot see them (C17_CHILDREN below) — and (b) EXPANDED
#     heredocs (`<<WORD` / `<<-WORD`, unquoted, so the body expands variables), which block in the
#     same 65,537..65,651-byte window on MSYS. `<<'WORD'`, `<<"WORD"` and `<<\WORD` bodies never
#     expand, so they are exempt. An expanded heredoc carries the SAME `# <<<-bounded: <why>`
#     annotation (same line or the comment above) naming the real cap on what it expands.
C17T=$(mktemp -d) || fail "check 17: mktemp -d failed" ""
trap 'rm -rf "$C17T"' EXIT
HJ_FILE="$REPO/hooks/hooks.json"
[ -f "$HJ_FILE" ] || fail "check 17: hooks/hooks.json missing — the hook-entry list cannot be derived" "$HJ_FILE"
HOOK_ENTRY=$(grep -oE 'scripts/[A-Za-z0-9_.-]+\.sh' "$HJ_FILE" | sed 's|^scripts/||' | sort -u)
# One level of `source`/`.` per round, twice: hook script -> lib.sh -> kb-schema.sh.
for _c17_round in 1 2; do
  for f in $HOOK_ENTRY; do
    [ -f "$ROOT/$f" ] || continue
    grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$ROOT/$f" | grep -oE '[A-Za-z0-9_.-]+\.sh' || true
  done > "$C17T/sourced" 2>/dev/null
  HOOK_ENTRY=$( { printf '%s\n' $HOOK_ENTRY; cat "$C17T/sourced"; } | while IFS= read -r f; do [ -f "$ROOT/$f" ] && printf '%s\n' "$f"; done | sort -u)
done
# Children spawned by hook-entry scripts (stop-extract.sh / pre-compact.sh run them with session
# text on stdin), so they sit in the same timeout and get the same scan. A missing one is a loud
# failure below (the scan loop reports a listed-but-absent file), not a silent skip.
# (Stems, `.sh` added here: tests/test-real-kb-isolation.sh greps this file's non-comment lines for
# `VAR=...<script>.sh` and would read a full-name assignment as a script RUN.)
C17_CHILDREN="merge-project-update merge-persona-signals"
HOOK_ENTRY=$( { printf '%s\n' $HOOK_ENTRY; printf '%s.sh\n' $C17_CHILDREN; } | sort -u)
for f in persona-tool-guard.sh protocol-guard.sh stop-extract.sh stop-verify-gate.sh session-load.sh lib.sh; do
  case " $(echo $HOOK_ENTRY) " in *" $f "*) ;; *) fail "check 17: the hook-entry list derived from hooks/hooks.json lacks $f — the derivation broke" "$(echo $HOOK_ENTRY)" ;; esac
done
cat > "$C17T/exempt" <<'EOF'
if [ "${#_fd_t}" -le 8192 ]; then "$@" <<< "$_fd_t"; else "$@" < <(printf '%s\n' "$_fd_t"); fi
if [ "${#_pf_t}" -le 8192 ]; then "$@" <<< "$_pf_t"; else "$@" < <(printf '%s\n' "$_pf_t"); fi
IFS='"' read -ra _SPINE_QSEG <<< "$_SPINE_TXT"
IFS="'" read -ra _SPINE_QSEG <<< "$_SPINE_TXT"
done <<< "$_SPINE_SPANS"
EOF
# c17_scan FILE: print FILE:LINE:text for every un-gated here-string. POSIX awk only (the macOS
# lane runs the BSD one-true-awk). A pure-comment line holding the annotation arms it; up to two
# more comment lines may continue it; the first code line consumes it, here-string or not.
c17_scan() {
  awk -v exf="$C17T/exempt" '
    BEGIN { while ((getline l < exf) > 0) ex[l] = 1; close(exf); pending = 0; gap = 0 }
    {
      iscomment = ($0 ~ /^[[:space:]]*#/)
      annotated = ($0 ~ /<<<-bounded:/)
      if (iscomment) {
        if (annotated) { pending = 1; gap = 0 }
        else if (pending) { gap++; if (gap > 2) pending = 0 }
        next
      }
      if ($0 ~ /<<</) {
        s = $0; sub(/^[[:space:]]+/, "", s)
        if (!(annotated || pending || (s in ex))) print FILENAME ":" FNR ":" $0
      } else if ($0 ~ /(^|[^<])<<-?[[:space:]]*[A-Za-z_]/) {
        # An unquoted heredoc word: the body expands variables (quoted or backslashed words never match).
        if (!(annotated || pending)) print FILENAME ":" FNR ":" $0
      }
      pending = 0
    }
  ' "$1"
}
# Self-test: the scan must flag exactly the bare and the spoofed lines of this canary.
cat > "$C17T/canary.sh" <<'EOF'
jq . <<< "$BIG"
jq . <<< "$SMALL"   # <<<-bounded: canary, same line
# <<<-bounded: canary, line above
jq . <<< "$SMALL"
# <<<-bounded: canary, wrapped over
# a second comment line
jq . <<< "$SMALL"
jq . <<< "$BIG"; : "$_pf_t"
x=1   # <<<-bounded: canary, on a code line that is not a here-string
jq . <<< "$BIG"
# <<<-bounded: canary, too far above
# one
# two
# three
jq . <<< "$BIG"
  if [ "${#_pf_t}" -le 8192 ]; then "$@" <<< "$_pf_t"; else "$@" < <(printf '%s\n' "$_pf_t"); fi
cat > "$f" <<TMPL
cat > "$f" <<'TMPL'
cat > "$f" <<"TMPL"
cat <<-EOF
cat > "$f" <<TMPL   # <<<-bounded: canary, heredoc annotated on the same line
cat <<\EOF
x=$((1<<2))
  done <<EOF_X
# <<<-bounded: canary, heredoc annotated on the line above
cat > "$f" <<TMPL
EOF
c17_scan "$C17T/canary.sh" > "$C17T/canary.out" 2> "$C17T/err"; c17_rc=$?
[ "$c17_rc" -eq 0 ] || fail "check 17 self-test: awk exited $c17_rc" "$(cat "$C17T/err")"
c17_got=$(cut -d: -f2 "$C17T/canary.out" | tr '\n' ' ')
[ "$c17_got" = "1 8 10 15 17 20 24 " ] \
  || fail "check 17 self-test: the scan must flag exactly canary lines 1 8 10 15 17 20 24 (bare, spoofed token, annotation on a non-here-string line, annotation 4 lines up, bare expanded heredocs <<W / <<-W / done <<W; quoted/backslashed/annotated heredocs and 1<<2 pass)" "got: [$c17_got]"
h=""
for f in $HOOK_ENTRY; do
  [ -f "$ROOT/$f" ] || { h="$h
$f: hook-entry script listed in check 17 is missing"; continue; }
  bad=$(c17_scan "$ROOT/$f" 2> "$C17T/err"); rc=$?
  [ "$rc" -eq 0 ] || fail "check 17: awk failed (rc=$rc) scanning $f — a scan that cannot run must not pass" "$(cat "$C17T/err")"
  [ -n "$bad" ] && h="$h
$bad"
done
[ -z "$h" ] && pass "every hook-entry <<< here-string is size-gated or annotated <<<-bounded (RR-SF1/RR-SF2: MSYS 64 KiB hang)" \
  || fail "un-gated <<< here-string OR expanded heredoc (<<WORD whose body expands variables) in a hook-entry script — MSYS blocks for good at 65,536..~65,650 bytes past the hook timeout; route through the size-gated feed helper or < <(printf '%s\\n' \"\$X\"), cap the text, or add an inline # <<<-bounded: <why> annotation" "$h"

# 17b. A `jq --arg NAME "$X"` / `--argjson NAME "$X"` whose value is a PAYLOAD-derived variable (the
#     hook's stdin JSON, the prompt, the command, a transcript/assistant message) must be
#     length-capped in place (`"${X:0:N}"`) or carry `# arg-bounded: <why it is short or cannot be
#     cut>` on the same line or the comment above. Windows-native programs (jq.exe) take their
#     arguments through a ~32 KB command line and SILENTLY drop what does not fit: measured on
#     this Windows Git-Bash box, a jq called with a larger --arg produces no output and no error
#     text, which a `|| true` hook then reads as "nothing to say" — a fail-open on exactly the
#     big-payload input an attacker controls. Payload text that can be big goes in through stdin,
#     `--rawfile`, or a cap. Scope: the same scripts check 17 scans. The name list is a
#     heuristic, not a taint analysis: extend it when a hook starts reading a new payload field.
C17B_NAMES='RAW|RAW_INPUT|INPUT|PAYLOAD|PROMPT|USER_PROMPT|TOOL_INPUT|TOOL_RESPONSE|CMD|COMMAND|NEW_CMD|LAST_MSG|LAST_MESSAGE|LAST_ASSISTANT|ASSISTANT_MSG|TRANSCRIPT_TEXT|MSG|TEXT|BODY|CONTENT|EXISTING|NEW_SIGNALS|NEW_CANDIDATES'
c17b_scan() {
  awk -v names="$C17B_NAMES" '
    BEGIN { re = "--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\"[$]\\{?(" names ")\\}?\""; pending = 0; gap = 0 }
    {
      iscomment = ($0 ~ /^[[:space:]]*#/)
      annotated = ($0 ~ /arg-bounded:/)
      if (iscomment) {
        if (annotated) { pending = 1; gap = 0 }
        else if (pending) { gap++; if (gap > 2) pending = 0 }
        next
      }
      if ($0 ~ re && !(annotated || pending)) print FILENAME ":" FNR ":" $0
      pending = 0
    }
  ' "$1"
}
cat > "$C17T/canary17b.sh" <<'EOF'
jq -nc --arg p "$PROMPT" '.'
jq -nc --arg p "${PROMPT:0:4000}" '.'
jq -nc --arg p "$PROMPT" '.'   # arg-bounded: canary, same line
# arg-bounded: canary, line above
  --argjson r "$RAW" \
jq -nc --arg id "$SESSION_ID" '.'
x=1   # arg-bounded: canary, on a code line that is not an --arg line
jq -nc --arg c "$NEW_CMD" '.'
jq -nc --arg c "${NEW_CMD}" '.'
jq -nc --argjson existing "$EXISTING" --argjson new_sigs "$NEW_SIGNALS" '.'
jq -nc --slurpfile existing "$TMP_E" '.'
EOF
c17b_scan "$C17T/canary17b.sh" > "$C17T/c17b.out" 2> "$C17T/err"; c17b_rc=$?
[ "$c17b_rc" -eq 0 ] || fail "check 17b self-test: awk exited $c17b_rc" "$(cat "$C17T/err")"
c17b_got=$(cut -d: -f2 "$C17T/c17b.out" | tr '\n' ' ')
[ "$c17b_got" = "1 8 9 10 " ] \
  || fail "check 17b self-test: the scan must flag exactly canary lines 1 8 9 10 (bare payload --arg, annotation consumed by a non-arg code line, braced bare name); capped, annotated and non-payload names pass" "got: [$c17b_got]"
h=""
for f in $HOOK_ENTRY; do
  [ -f "$ROOT/$f" ] || continue
  bad=$(c17b_scan "$ROOT/$f" 2> "$C17T/err"); rc=$?
  [ "$rc" -eq 0 ] || fail "check 17b: awk failed (rc=$rc) scanning $f — a scan that cannot run must not pass" "$(cat "$C17T/err")"
  [ -n "$bad" ] && h="$h
$bad"
done
[ -z "$h" ] && pass "no hook-entry jq --arg/--argjson takes an uncapped payload-derived variable (jq.exe drops a >32 KB command line silently)" \
  || fail "uncapped payload-derived jq --arg in a hook-entry script — cap it (\"\${X:0:N}\"), pass it by stdin/--rawfile, or add an inline # arg-bounded: <why> annotation" "$h"

# 18. No \001 (CTLESC) or \177 (CTLNUL) in an IFS value. bash 3.2 (macOS /bin/bash, the CI
#     floor) uses both bytes as internal quoting markers and does not split on them: an
#     IFS=$'\x01' read put a whole stop-extract.sh gate=hook-cancelled row into its first field
#     (hook=a\u0001b\u0001..., script= kind= count= empty) on the macOS lane while bash 5 split it
#     fine. Use a printable delimiter the fields cannot contain, or US ($'\037').
#     T4: the scan used to be `grep … 2>/dev/null | nocomment || true`, so a grep that
#     ERRORED (rc 2: unreadable file, bad regex) looked exactly like a clean scan, and it missed
#     the command-substitution spelling `IFS=$(printf '\001')` (and `IFS="$(printf '\x7f')"`).
#     grep's status is now read (0 = hits, 1 = none, anything else fails loud) and the canary
#     below proves both spellings are caught.
C18_RE="IFS=(\\\$'[^']*[\\\\](x01|001|x7[fF]|177)|\"?\\\$\\(printf[[:space:]]+[^)]*[\\\\](x01|001|x7[fF]|177))"
printf '%s\n' \
  "IFS=\$'\\001' read -r a b <<< \"\$x\"" \
  "IFS=\$'\\x7f' read -r a b" \
  "IFS=\$(printf '\\001') read -r a b" \
  "IFS=\"\$(printf '\\x01')\" read -r a b" \
  "IFS=\$'\\037' read -r a b" \
  "IFS=\$(printf '\\037') read -r a b" > "$C17T/c18.canary"
grep -nE "$C18_RE" "$C17T/c18.canary" > "$C17T/c18.out" 2> "$C17T/err"; c18_rc=$?
[ "$c18_rc" -eq 0 ] || fail "check 18 self-test: grep exited $c18_rc (0 expected: the canary holds hits)" "$(cat "$C17T/err")"
c18_got=$(cut -d: -f1 "$C17T/c18.out" | tr '\n' ' ')
[ "$c18_got" = "1 2 3 4 " ] \
  || fail "check 18 self-test: must flag exactly canary lines 1 2 3 4 (\$'\\001', \$'\\x7f', \$(printf '\\001'), \"\$(printf '\\x01')\"); \\037 must pass" "got: [$c18_got]"
h=$(grep -nE "$C18_RE" $ALL_SH 2> "$C17T/err"); c18_rc=$?
[ "$c18_rc" -le 1 ] || fail "check 18: grep failed (rc=$c18_rc) — a scan that cannot run must not pass" "$(cat "$C17T/err")"
h=$(printf '%s\n' "$h" | nocomment || true)
[ -z "$h" ] && pass "no \001 or \177 byte in an IFS value (bash 3.2 never splits on CTLESC/CTLNUL)" \
  || fail "IFS holds \001 or \177 - bash 3.2 (macOS) never splits on its internal quoting bytes; use a printable delimiter or \$'\037'" "$h"

# 19. No `=~` against an UNANCHORED trailing-run regex — `(X+)$`, `X*$`, `(X*)\$` with no leading
#     `^`, inline or through a variable. glibc's regexec retries the match from every start
#     position, so a run of N X's followed by any other text costs O(N^2): the guards' trim regex
#     `($_fp_nl+)$` took 22-39 s per guard on Debian for `rm -rf ~/proj` + 50,000 newlines + `#`
#     (F8, 0.54.1) — past the 5 s hook timeout, a fail-open. MSYS's engine is linear there, so no
#     Windows run could see it. Trim runs without a regex (the guards' _fp_trimnl). A regex only
#     ever matched against a short bounded slice may stay, with an inline `# =~-bounded: <why>` on
#     its definition line (same line only).
# c19_scan FILE…: print FILE:LINE: token for every such regex. Names are the variables used as
# `=~ $NAME` anywhere in FILE…; a definition is NAME='…', NAME="…" or a bare NAME=word. POSIX awk.
c19_scan() {
  local names
  names=$(grep -ohE '=~[[:space:]]*"?[$][{]?[A-Za-z_][A-Za-z0-9_]*' "$@" | sed -E 's/.*[$][{]?//' | sort -u | tr '\n' ' ')
  awk -v names="$names" '
    function run(t) { return (t !~ /^\^/ && t ~ /[+*][)]?\\?[$]$/) }
    BEGIN { n = split(names, nm, " "); q = sprintf("%c", 39) }
    /^[[:space:]]*#/ { next }
    /# =~-bounded:/ { next }
    {
      s = $0
      while (match(s, /=~[[:space:]]*[^[:space:]$"]/)) {
        r = substr(s, RSTART + RLENGTH - 1)
        if (substr(r, 1, 1) == q) { s = substr(s, RSTART + RLENGTH); continue }
        match(r, /^[^[:space:]]*/); t = substr(r, 1, RLENGTH)
        if (run(t)) print FILENAME ":" FNR ": =~ " t
        s = substr(r, RLENGTH + 1)
      }
      for (i = 1; i <= n; i++) {
        s = $0
        while (match(s, nm[i] "=")) {
          pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
          r = substr(s, RSTART + RLENGTH); s = r
          if (pre ~ /[A-Za-z0-9_]/) continue
          c = substr(r, 1, 1)
          if (c == q) { if (!match(r, "^" q "[^" q "]*" q)) continue; t = substr(r, 2, RLENGTH - 2) }
          else if (c == "\"") { if (!match(r, /^"[^"]*"/)) continue; t = substr(r, 2, RLENGTH - 2) }
          else { match(r, /^[^[:space:];]*/); t = substr(r, 1, RLENGTH) }
          if (run(t)) print FILENAME ":" FNR ": " nm[i] "=" t
        }
      }
    }
  ' "$@"
}
# Self-test: exactly the unanchored trailing-run regexes of this canary, nothing else.
cat > "$C17T/c19.sh" <<'EOF'
_c19_a="($_c19_nl+)\$"
[[ $x =~ $_c19_a ]]
_c19_b='(\\+)$'   # =~-bounded: canary, a bounded slice
[[ $x =~ $_c19_b ]]
[[ $x =~ ([a-z]+)$ ]]
[[ $x =~ ^[0-9]+$ ]]
_c19_c='^[[:space:]]*:[[:space:]]*$'
[[ $x =~ $_c19_c ]]
_c19_d='x+$'
# _c19_a="(y+)$"
local _c19_e='(a*)$'
[[ $x =~ ${_c19_e} ]]
EOF
c19_scan "$C17T/c19.sh" > "$C17T/c19.out" 2> "$C17T/err"; c19_rc=$?
[ "$c19_rc" -eq 0 ] || fail "check 19 self-test: awk exited $c19_rc" "$(cat "$C17T/err")"
c19_got=$(cut -d: -f2 "$C17T/c19.out" | tr '\n' ' ')
[ "$c19_got" = "1 5 11 " ] \
  || fail "check 19 self-test: the scan must flag exactly canary lines 1 5 11 (a variable, an inline and a local regex of the trailing-run shape)" "got: [$c19_got] $(cat "$C17T/c19.out")"
h=$(c19_scan $ALL_SH 2> "$C17T/err"); rc=$?
[ "$rc" -eq 0 ] || fail "check 19: the scan failed (rc=$rc) — a scan that cannot run must not pass" "$(cat "$C17T/err")"
[ -z "$h" ] && pass "no =~ against an unanchored trailing-run regex like (X+)\$ (glibc O(run^2): F8 fail-open)" \
  || fail "=~ against an unanchored trailing-run regex — O(run^2) on glibc for a run followed by other text; trim/measure without a regex, or annotate a bounded slice with # =~-bounded: <why>" "$h"

echo; echo "ALL PASS"
