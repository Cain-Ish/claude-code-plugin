#!/bin/bash
# Cross-platform portability guard for scripts/ — keeps the plugin runnable on macOS
# (/bin/bash is 3.2; BSD coreutils) and under Git Bash on Windows, not just Linux/GNU.
# Static checks (no bash 3.2 / BSD host available in CI) for the construct classes that
# silently break off-Linux. Surfaced by the 2026-06-02 cross-platform audit.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)/scripts"
fail(){ echo "FAIL: $1"; printf '%s\n' "$2" | sed 's/^/    /'; exit 1; }
pass(){ echo "PASS: $1"; }
# Drop pure-comment matches (file:line:<ws>#...) — a portability linter checks code, not the
# comments that legitimately discuss these constructs.
nocomment(){ grep -vE ':[0-9]+:[[:space:]]*#'; }

# 1. No bash-4 array builtins (macOS /bin/bash is 3.2). Match actual usage `mapfile -`/`readarray -`,
#    not prose mentions.
h=$(grep -rnE '(mapfile|readarray)[[:space:]]+-' "$ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no mapfile/readarray usage (bash 4+)" || fail "bash-4 mapfile/readarray usage" "$h"

# 2. No other bash-4 isms: associative arrays / case-modification expansions.
h=$(grep -rnE 'declare[[:space:]]+-A|local[[:space:]]+-A|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' "$ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no assoc-arrays / \${x^^}\${x,,} (bash 4+)" || fail "bash-4 expansion" "$h"

# 3. No PCRE `grep -P` (BSD/macOS grep lacks it). Match literal `grep -P`/`grep -qP` usage in code.
h=$(grep -rnE 'grep[[:space:]]+-[A-Za-z]*P([[:space:]]|$)' "$ROOT" 2>/dev/null | nocomment || true)
[ -z "$h" ] && pass "no grep -P (PCRE; use -F/-E)" || fail "grep -P usage (not on BSD/macOS)" "$h"

# 4. GNU `stat -c` must always have a BSD `stat -f` (or other) fallback on the SAME line.
h=$(grep -rn 'stat -c' "$ROOT" 2>/dev/null | grep -v 'stat -f' || true)
[ -z "$h" ] && pass "every 'stat -c' is paired with a 'stat -f' fallback" || fail "unpaired GNU stat -c" "$h"

# 5. GNU `date -d` must have a BSD `date -v` fallback (anywhere in the same file).
for f in $(grep -rlE 'date[[:space:]]+(-d|--date)' "$ROOT" 2>/dev/null || true); do
  grep -qE 'date[[:space:]]+-v' "$f" || fail "GNU date -d without a BSD date -v fallback" "$f"
done
pass "every 'date -d' file also has a 'date -v' fallback"

# 6. GNU `find -printf` must have a stat-based fallback in the same file.
for f in $(grep -rlE 'find[^|]*-printf' "$ROOT" 2>/dev/null || true); do
  grep -qE 'stat (-f|-c)' "$f" || grep -q 'NOT GNU' "$f" || fail "find -printf without a stat fallback" "$f"
done
pass "every 'find -printf' file has a stat fallback (or documents avoidance)"

# 7. `timeout` usage must resolve gtimeout too (macOS coreutils-brew), not assume GNU-only.
h=$(grep -rn 'command -v timeout' "$ROOT" 2>/dev/null | grep -v 'gtimeout' || true)
[ -z "$h" ] && pass "timeout resolution includes gtimeout (macOS)" || fail "timeout without gtimeout fallback" "$h"

echo; echo "ALL PASS"
