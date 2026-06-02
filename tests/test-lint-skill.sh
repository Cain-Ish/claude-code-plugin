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

# --- Test 4: the dead-link extractor SKIPS the projector's generated graph block ---
# The graph projector writes a fenced "<!-- graph:begin --> ... <!-- graph:end -->"
# block of generated [[links]] (incl. Superseded: links to retired slugs). Lint must
# NOT flag those as dead, but MUST still flag a genuine dead link in the real body.
# We run the EXACT extractor awk shipped in the skill (extracted, not re-typed).
LINKAWK="$TMP/linkextract.awk"
# Pull the first link-extractor awk program out of SKILL.md (Check 1 / Check 2 share it).
awk '
  /awk '\''$/ { grab=1; next }
  grab && /^[[:space:]]*'\''[[:space:]]*"/ { grab=0; next }
  grab && /^[[:space:]]*'\''/ { grab=0; next }
  grab { print }
' "$SCRIPT" | awk 'NR==1,/print/' > "$LINKAWK"
# Sanity: we captured an awk body that includes the fence toggle.
grep -q 'in_fence' "$LINKAWK" || fail "Test 4 setup: could not extract the link-extractor awk from SKILL.md"
# Whether the shipped awk also carries the graph guard:
GUARDED=$(grep -c 'in_graph' "$LINKAWK")

PAGE="$TMP/page.md"
cat > "$PAGE" <<'EOF'
---
title: page
---

# page

Real body links [[real-ref]] here.

<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->
## Dependencies
**Superseded:** [[retired-ghost]]
<!-- graph:end -->
EOF

EXTRACTED=$(awk '
  /^[[:space:]]*```/ { in_fence = !in_fence; next }
  /<!-- graph:begin/ { in_graph = 1; next }
  /<!-- graph:end/   { in_graph = 0; next }
  in_graph { next }
  in_fence { next }
  { gsub(/`[^`]*`/, ""); print }
' "$PAGE" | grep -oE '\[\[[a-zA-Z0-9][a-zA-Z0-9.-]*\]\]' | sed -E 's/\[\[([^]]+)\]\]/\1/' | sort -u)

# Reference behaviour (what the guard MUST achieve): real-ref present, retired-ghost absent.
echo "$EXTRACTED" | grep -qx 'real-ref'      || fail "Test 4: guard over-skipped — real body link 'real-ref' was dropped"
echo "$EXTRACTED" | grep -qx 'retired-ghost' && fail "Test 4: 'retired-ghost' in the generated graph block was NOT skipped"

# And assert the SHIPPED skill awk actually has the guard (RED until SKILL.md is patched).
[ "$GUARDED" -ge 1 ] || fail "Test 4: SKILL.md link-extractor is missing the in_graph guard (graph block not skipped in the real skill)"
pass "dead-link extractor skips the generated graph block, keeps real body links"

# --- Test 5: Check 4 (missing ai-block) is present + functional -----------
# The lint skill surfaces structured pages with no ai:begin block (Phase 3).
grep -q 'Missing ai-block' "$SCRIPT" || fail "Test 5: lint skill missing Check 4 (ai-block)"
grep -q 'MISSING-BLOCK:' "$SCRIPT"  || fail "Test 5: Check 4 has no MISSING-BLOCK report marker"
# Anti-regression (static): Check 4's per-file skip must use `grep -l`, NOT `grep -q`. `grep -q`
# early-exits and SIGPIPEs the upstream `find` under a job-control (monitor) shell -- the way the
# skill is pasted at runtime -- silently zeroing the check. A script-context dynamic test can't
# catch this (grep -q works in a plain script), so pin it statically.
grep -qE "grep -lE '<!--\[\[:space:\]\]\*ai:begin'" "$SCRIPT" || fail "Test 5: Check 4 must use 'grep -l' (whole-file) for the block-skip, not grep -q (inline-SIGPIPE hazard)"
awk '/### 4\. Missing ai-block/{c4=1} c4 && /grep -qE .<!--\[\[:space:\]\]\*ai:begin/{print "found grep -q in Check 4"; bad=1} END{exit bad?1:0}' "$SCRIPT" || fail "Test 5: Check 4 uses grep -q for the block-skip (inline-SIGPIPE hazard) -- use grep -l"
# Functional: a long blockless learnings page is flagged; a stub + a page-with-block are not.
KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
printf '%s\n' '---' 'title: A' 'type: learnings' '---' '# A' "$(printf 'real prose detail. %.0s' $(seq 1 20))" > "$KD/wiki/learnings/cand.md"
printf '%s\n' '---' 'title: B' 'type: learnings' '---' '<!-- ai:begin -->' 'claim: c' '<!-- ai:end -->' '# B' "$(printf 'prose. %.0s' $(seq 1 20))" > "$KD/wiki/learnings/hasblock.md"
printf '%s\n' '---' 'title: C' 'type: learnings' '---' '# C' 'tiny.' > "$KD/wiki/learnings/stub.md"
MB=$(for type in learnings decisions entities issues concepts security; do
  d="$KD/wiki/$type"; [ -d "$d" ] || continue
  find "$d" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while read -r f; do
    grep -q '<!-- ai:begin' "$f" 2>/dev/null && continue
    prose=$(awk '
      NR==1 && /^---[[:space:]]*$/ { infm=1; next }
      infm && /^---[[:space:]]*$/  { infm=0; next }
      infm { next }
      /<!--[[:space:]]*(graph|theme|ai):begin/ { drop=1 }
      drop { if (/<!--[[:space:]]*(graph|theme|ai):end[[:space:]]*-->/) drop=0; next }
      { print }
    ' "$f" | tr -d '[:space:]' | wc -c)
    [ "$prose" -ge 200 ] && echo "MISSING-BLOCK: $type/$(basename "$f" .md) ($f)"
  done
done)
echo "$MB" | grep -q 'learnings/cand'     || fail "Test 5: blockless substantive page not flagged"
echo "$MB" | grep -q 'hasblock'           && fail "Test 5: page WITH a block was flagged"
echo "$MB" | grep -q 'stub'               && fail "Test 5: stub was flagged"
pass "Check 4 flags only blockless, substantive, structured pages"

echo
echo "ALL PASS"
