#!/bin/bash
# Guard: USER.md (the human's global Never/Always rules — stated priority 1) must ALWAYS land in
# the SessionStart context, even when the conditional banners have already consumed the byte budget.
# Regression: USER.md was appended after ~9 banners under the shared budget, so a degraded
# multi-banner state could silently drop it. sb_append now honors a `force` arg that bypasses the
# budget; the USER.md call passes it.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

# 1. the live USER.md append must pass `force`
# force + a finite cap: always lands (priority-1) but bounded so a huge USER.md can't breach the hook cap.
grep -qE 'sb_append "\$USER_CONTENT" "USER.md" [0-9]+ force' "$SL" \
  || fail "the USER.md sb_append does not pass the force arg (would be budget-starvable)"
grep -qE 'sb_append "\$USER_CONTENT" "USER.md" 0 force' "$SL" \
  && fail "USER.md is forced but UNCAPPED (max=0) — a huge USER.md could breach the ~10K hook cap"
pass "session-load forces the USER.md section past the budget"

# 1b. SP-E: the PROJECT.md append must ALSO pass force + a finite cap — the sibling bug.
# PROJECT.md is the project hot tier, appended AFTER ~9 banners, so it was budget-starvable
# and could be silently dropped (losing the project's whole context).
grep -qE 'sb_append "\$PROJ_CONTENT" "PROJECT.md" [0-9]+ force' "$SL" \
  || fail "the PROJECT.md sb_append does not pass force (the project hot tier is budget-starvable)"
grep -qE 'sb_append "\$PROJ_CONTENT" "PROJECT.md" 0 force' "$SL" \
  && fail "PROJECT.md is forced but UNCAPPED (max=0) — a huge PROJECT.md could breach the ~10K hook cap"
pass "session-load forces the PROJECT.md section past the budget (SP-E sibling fix)"

# 2. functional: extract the real sb_append and prove force bypasses the budget, non-force doesn't
TMP=$(mktemp); awk '/^sb_append\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SL" > "$TMP"
sb_log_error(){ :; }                      # no-op stub for the extracted function
OUT=$(mktemp); OUTPUT_FILE="$OUT"; BYTE_BUDGET=100; USED=95
BIG="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # 49 chars → 95+49 > 100
. "$TMP"
: > "$OUT"; USED=95
if sb_append "$BIG" "banner" 0; then fail "non-forced over-budget section should be skipped (return 1)"; fi
[ ! -s "$OUT" ] || fail "skipped section must not be written"
pass "non-forced section over budget is skipped (prior behaviour preserved)"
: > "$OUT"; USED=95
sb_append "${BIG//x/u}" "USER.md" 0 force || fail "forced USER.md should append (return 0)"
grep -q 'uuuu' "$OUT" || fail "forced USER.md was NOT written despite being over budget"
pass "forced USER.md lands even when the budget is already spent"
# 3. audit H4: the per-section byte cap keeps WHOLE lines, ends with a newline, logs the cut.
# Run under a C locale (bytes == chars) with a multibyte rule line straddling the cap.
LOGF=$(mktemp)
sb_log_error(){ echo "$2" >> "$LOGF"; }
export LC_ALL=C
BIGU=""; i=0
while [ $i -lt 120 ]; do BIGU="${BIGU}- Never do thing number $i é ü ñ in this repo please"$'\n'; i=$((i+1)); done
: > "$OUT"; USED=0; BYTE_BUDGET=100000
sb_append "$BIGU" "USER.md" 6000 force || fail "capped USER.md should append"
[ "$(tail -c1 "$OUT" | od -An -c | tr -d ' ')" = '\n' ] || fail "capped output must end with a newline"
LASTL=$(tail -n1 "$OUT")
case "$LASTL" in *please) ;; *) fail "last line torn: [$LASTL]";; esac
iconv -f UTF-8 -t UTF-8 "$OUT" >/dev/null 2>&1 || fail "capped output is not valid UTF-8"
[ "$(wc -c < "$OUT")" -le 6001 ] || fail "capped output exceeds cap"
grep -q 'gate=byte-budget USER.md truncated' "$LOGF" || fail "truncation was not logged"
pass "H4: capped section keeps whole lines, ends with newline, logs truncation"
: > "$OUT"; sb_append "$(printf 'heading\nbody\n\n')" "banner" 0 || fail "append failed"
[ "$(tail -c1 "$OUT" | od -An -c | tr -d ' ')" = '\n' ] || fail "uncapped banner lost its trailing newline"
pass "H9: uncapped banner ends with a newline"
# 4. audit N1: the session counter + cadence banner are gone end to end.
grep -rlE 'sb_(increment|get|reset)_session_count|dream-cadence-banner|SB_DREAM_CADENCE' "$ROOT/scripts" "$ROOT/hooks" \
  && fail "N1: session-counter / dream-cadence code still present"
pass "N1: session counter and cadence banner removed"
# 5. audit H5: rules-gap banner compares USER.md with $BRAIN_DIR/persona-rules.json (not the shipped default).
GB=$(mktemp -d); BRAIN_DIR="$GB"; USER_FILE="$GB/USER.md"
printf '## Never\n- a\n- b\n## Always\n- c\n' > "$USER_FILE"
RGBLOCK=$(awk '/^if \[ "\$\{SB_RULES_GAP_BANNER/{f=1} f{print} f&&/^fi$/{exit}' "$SL")
[ -n "$RGBLOCK" ] || fail "H5: could not extract rules-gap block"
sb_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
sb_append() { printf '%s' "$1" >> "$GB/out"; }
run_rg() { : > "$GB/out"; eval "$RGBLOCK"; cat "$GB/out"; }
run_rg | grep -q "$GB/persona-rules.json" || fail "H5: missing rules file must fire the banner naming it"
touch -d '2001-01-01' "$USER_FILE"; echo '{"rules":[]}' > "$GB/persona-rules.json"
[ -z "$(run_rg)" ] || fail "H5: rules file newer than USER.md must stay quiet"
touch -d '2002-01-01' "$USER_FILE"; touch -d '2001-01-01' "$GB/persona-rules.json"
run_rg | grep -q "persona-rules.json" || fail "H5: rules file older than USER.md must fire"
pass "H5: rules-gap compares against the brain dir's persona-rules.json"
# IMP-R3: USER.md with no Never/Always bullets has nothing to enforce -> no banner even with rules file missing.
printf '# notes\nno rules here\n' > "$USER_FILE"; rm -f "$GB/persona-rules.json"
[ -z "$(run_rg)" ] || fail "IMP-R3: USER.md without rules must not fire the rules-gap banner"
pass "IMP-R3: rules-gap banner skipped when USER.md has no rules"
# PORT-R5: torn-line check must be linear. The old ${text#"$cut"...} compare was O(cap^2): measured
# on MSYS 2026-10-11 at a cap just inside the last line, 25 KB 0.7 s, 50 KB 2.5 s, 100 KB 10.3 s; the
# linear form 46 ms at 100 KB. At ~100 KB the whole-second bound (2 s) cannot miss the quadratic form.
eval "$(awk '/^sb_append\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SL")"
sb_log_error(){ :; }
BIG100=""; i=0; while [ $i -lt 32 ]; do BIG100="${BIG100}- Never do thing number $i in this repo please ok"$'\n'; i=$((i+1)); done
i=0; while [ $i -lt 6 ]; do BIG100="$BIG100$BIG100"; i=$((i+1)); done   # 2048 lines, ~100 KB
T0=$(date +%s); : > "$OUT"; USED=0; BYTE_BUDGET=10000000
sb_append "$BIG100" "perf" $(( ${#BIG100} - 20 )) force
[ $(( $(date +%s) - T0 )) -le 2 ] || fail "PORT-R5: 100 KB sb_append cap too slow (quadratic torn-line check?)"
case "$(tail -n1 "$OUT")" in *please\ ok) ;; *) fail "PORT-R5: last line torn";; esac
[ "$(wc -l < "$OUT" | tr -d ' ')" = 2047 ] || fail "PORT-R5: the torn last line must be the only one dropped"
grep -v '^[[:space:]]*#' "$SL" | grep -qF '${text#"$cut"' && fail "PORT-R5: the quadratic \${text#\"\$cut\"...} compare is back in sb_append"
pass "PORT-R5: 100 KB capped sb_append is fast and keeps whole lines"
rm -f "$TMP" "$OUT" "$LOGF"
echo; echo "ALL PASS"
