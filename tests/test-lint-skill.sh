#!/bin/bash
# Tests for skills/lint/SKILL.md awk blocks. Closes the test-gap finding from
# the v0.21.4 deep code review (code-review-unit-reviewer Finding 1).
#
# The lint skill is a markdown file whose bash code blocks are pasted verbatim
# into shells when /second-brain:lint runs. The awk inside those blocks must
# parse on strict-mode awk (gawk default, mawk, busybox awk) — historically
# the Check 1 + Check 3 blocks used `in` as a variable name, which is reserved
# in `for (x in arr)` / `(elem in arr)` grammar contexts and silently
# syntax-errored on Pi OS / Debian gawk.
#
# This test extracts every `awk '...'` block from the skill body and pipes it
# through `awk -- -h` (parse-only). If any block has a reserved-word collision
# or other parse error, awk emits "syntax error" and the test fails.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/skills/lint/SKILL.md"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "skills/lint/SKILL.md not found at $SCRIPT"

# --- Test 1: every awk block in SKILL.md parses without "syntax error" ----
# Extract awk programs: lines from `awk '` (start of single-quoted program) up
# to the matching closing `'` on its own indented line. The skill uses a
# consistent style — awk programs span multiple lines, terminated by a line
# whose first non-whitespace token is the closing single quote.
#
# Strategy: awk-extract the awk-program contents into separate files, then
# parse each with `awk --source` (gawk) or fall back to piping into awk and
# checking for "syntax error" on stderr.
PROGRAMS_DIR="$TMP/programs"
mkdir -p "$PROGRAMS_DIR"
awk -v dir="$PROGRAMS_DIR" '
  /awk '\''$/ { inside=1; n++; out = dir "/prog-" n ".awk"; next }
  inside && /^[[:space:]]*'\''[[:space:]]*"/ { inside=0; next }
  inside && /^[[:space:]]*'\'' / { inside=0; next }
  inside && /^[[:space:]]*'\''$/ { inside=0; next }
  inside { print > out }
' "$SCRIPT"

PROG_COUNT=$(ls "$PROGRAMS_DIR"/*.awk 2>/dev/null | wc -l | tr -d ' ')
[ "$PROG_COUNT" -ge 1 ] || fail "expected to extract at least 1 awk program, got $PROG_COUNT"

ERRORS=0
for prog in "$PROGRAMS_DIR"/*.awk; do
  # Parse-check: feed an empty stdin to the program; only parse errors will
  # produce "syntax error" output. A successful parse + empty input produces
  # no output and exit 0.
  ERR=$(awk -f "$prog" </dev/null 2>&1 || true)
  if printf '%s' "$ERR" | grep -qi "syntax error"; then
    echo "  awk parse FAILED in $(basename "$prog"):" >&2
    printf '%s\n' "$ERR" | sed 's/^/    /' >&2
    ERRORS=$((ERRORS + 1))
  fi
done
[ "$ERRORS" -eq 0 ] || fail "$ERRORS awk program(s) have parse errors (e.g. reserved-word collisions)"
pass "all $PROG_COUNT awk programs in skills/lint/SKILL.md parse without syntax error"

# --- Test 2: explicit reserved-word collision check ----------------------
# Belt-and-suspenders: even if the parse-test above misses something, this
# explicit grep catches the specific bug class we just fixed (`in=` as a
# bare assignment in awk). The match is restricted to inside an awk block
# to avoid false positives from the bash blocks around it.
#
# Two portability nits to keep in mind, both verified empirically on this Pi
# (mawk 1.3.4, the default `awk` on Debian/Pi OS — gawk not installed):
#   1. `\<word-boundary>` (gawk extension) is INERT on mawk — it matches the
#      literal `<` character. Use `(^|[^_a-zA-Z0-9])` instead.
#   2. The entry regex must match BOTH bare `  awk '` AND assignment forms
#      like `CROSS=$(awk '`. Anchor only on `awk '$` (line end), not on
#      leading whitespace, or the CROSS block (where the historical bug
#      lived) is silently skipped.
if awk '
  /awk '\''$/ { inside=1 }
  inside && /(^|[^_a-zA-Z0-9])in[[:space:]]*=/ { print NR": "$0; found=1 }
  inside && /^[[:space:]]*'\''/ { inside=0 }
  END { exit !found }
' "$SCRIPT" > "$TMP/hits.txt"; then
  echo "  reserved-word collision (`in=...`) inside awk block:" >&2
  cat "$TMP/hits.txt" >&2
  fail "lint skill awk block uses reserved word `in` as a variable"
fi
pass "no `in=...` reserved-word collisions inside awk blocks"

# --- Test 2b: re-inject bug + confirm Test 2 catches it (RED→GREEN guard) -
# Without this, a future edit could silently neuter the portability fixes
# above and Test 2 would always vacuously PASS again. We construct a copy
# of SKILL.md with `inside=1` reverted to `in=1` and assert Test 2 fires.
INJECT="$TMP/SKILL-injected.md"
sed 's|inside=1; next|in=1; next|' "$SCRIPT" > "$INJECT"
if awk '
  /awk '\''$/ { inside=1 }
  inside && /(^|[^_a-zA-Z0-9])in[[:space:]]*=/ { print NR": "$0; found=1 }
  inside && /^[[:space:]]*'\''/ { inside=0 }
  END { exit !found }
' "$INJECT" >/dev/null; then
  pass "Test 2 catches a re-injected `in=` bug (RED on injection)"
else
  fail "Test 2 DID NOT catch a re-injected `in=` bug — portability fix broken"
fi

# --- Test 3: the Cross-references awk pattern produces expected output ---
# Functional test of Check 1's CROSS extractor against a fixture PROJECT.md.
FIX="$TMP/PROJECT.md"
cat > "$FIX" <<'EOF'
# PROJECT: fixture

## Goal
test the awk.

## Recent decisions

## Cross-references
- alpha-page
- beta-page
- gamma-page

## Open blockers
- not-a-crossref
EOF

OUT=$(awk '
  /^## Cross-references/ { inside=1; next }
  /^## / && inside { inside=0 }
  inside && /^- / { sub(/^- */, ""); print }
' "$FIX")

EXPECTED="alpha-page
beta-page
gamma-page"
[ "$OUT" = "$EXPECTED" ] || fail "Cross-references extractor produced wrong output: got '$OUT' expected '$EXPECTED'"
pass "Cross-references extractor matches expected output on fixture"

echo
echo "ALL PASS"
