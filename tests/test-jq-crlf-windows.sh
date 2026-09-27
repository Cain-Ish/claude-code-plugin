#!/bin/bash
# 0.30.0: the Windows (Git-Bash) jq build emits CRLF in -r output even when the input is clean LF.
# So every `$(jq -r …)` value, every `jq -r … | grep`, and every config read is \r-contaminated on
# Windows — silently breaking comparisons, arithmetic, grep patterns, and path building. We can't run
# Windows here, so this test STUBS jq to reproduce the exact CRLF behavior on Linux, then runs the real
# scripts and asserts they survive. ORACLE: real script behavior under the faulty jq, not a re-impl.
# pins: SB_BUDDY_COLS — width fixture so the buddy renderer draws the thought-cloud row the steam-colour check reads
# run-all-timeout: 180   (validate-plugin.sh + several full session-load.sh/merge invocations
# under the jq-CRLF stub by design; measured 90s alone on MSYS under load)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; echo; echo "ALL PASS"; exit 0; }

REALJQ=$(command -v jq)
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
# Faithful Windows-jq stub: append \r to every line of -r/-j (raw) output, like the CRLF build.
# IDEMPOTENT by construction (strip any trailing CR, then add exactly one back): on the real
# windows-latest runner jq is already the native CRLF build (F8), so a blind `sed 's/$/\r/'`
# risks a doubled \r\r that a single ${v%$'\r'}-style strip in production code would not remove.
cat > "$STUB/jq" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in -r|--raw-output|-j|-rs|-rc|-rn|-nr) raw=1;; esac; done
if [ "\${raw:-0}" = 1 ]; then "$REALJQ" "\$@" | awk '{sub(/\r\$/,""); printf "%s\r\n", \$0}'; else "$REALJQ" "\$@"; fi
EOF
chmod +x "$STUB/jq"
RUN(){ PATH="$STUB:$PATH" "$@"; }

# Sanity: the stub really emits CRLF (a CR byte in -r output of a CR-free input).
# Use od-based detection: Git-Bash grep reads pipes in text mode and strips \r from CRLF pairs,
# so `grep -q $'\r'` always exits 1 even when \r is present. od is binary-safe.
printf '{"a":"x"}' | "$STUB/jq" -r '.a' | od -An -tx1 | grep -q ' 0d' \
  || fail "stub jq does not emit CRLF — test would be vacuous"
pass "stub reproduces Windows jq CRLF (-r output carries \\r)"

# 1. The validator's version-drift loop builds cache paths from @tsv jq output — a \r turned
#    them into "…/\r/.claude-plugin/plugin.json" → spurious FAIL (the user's reported 0.30 error).
RUN bash "$ROOT/scripts/validate-plugin.sh" >/tmp/_jqcrlf_val.out 2>&1
ec=$?
grep -qiE 'invalid arithmetic|syntax error' /tmp/_jqcrlf_val.out && fail "validator hit a CRLF arithmetic/syntax error under Windows jq"
[ "$ec" -eq 0 ] || fail "validate-plugin.sh FAILED under Windows jq (exit $ec) — drift/hook CRLF not handled: $(grep -i fail /tmp/_jqcrlf_val.out | head -1)"
pass "validate-plugin.sh passes under Windows jq (drift loop + hook counts CR-safe)"
rm -f /tmp/_jqcrlf_val.out

# 2. The config reader is the highest-leverage jq site: `auto_improve: true` must read 'on', not
#    fall through to the default because the value came back "true\r".
T=$(mktemp -d); printf '{"auto_improve": true}\n' > "$T/config.json"
r=$(RUN bash -c "source '$ROOT/scripts/lib.sh'; BRAIN_DIR='$T' sb_config_bool .auto_improve off")
[ "$r" = "on" ] || fail "config reader mis-read true as '$r' under Windows jq (whole automation-config system would break)"
pass "sb_config_bool reads true→on under Windows jq (config system CR-safe)"
r=$(RUN bash -c "source '$ROOT/scripts/lib.sh'; printf '{\"auto_accept\":\"safe\"}\n' > '$T/config.json'; BRAIN_DIR='$T' sb_config_get .auto_accept off")
[ "$r" = "safe" ] || fail "sb_config_get returned '$r' (CR leaked into a string value)"
pass "sb_config_get returns a clean string under Windows jq"
rm -rf "$T"

# 3. 0.51.0 (thought-cloud redesign 2026-09-26): the buddy renderer reads its US-joined fields from
#    ONE `jq -rn` line; a CR lands in the LAST field (mood — parsed but unused by the redesign) and
#    used to poison the mood-eyes case match. The steam-dot colour now keys off KIND instead, one
#    field earlier in the same read: still worth locking under the Windows-CRLF stub, without colour.
T=$(mktemp -d); mkdir -p "$T/.buddy"
printf '{"name":"probe"}\n' > "$T/buddy.json"
printf '{"ts":%s,"kind":"gate","mood":"alert","line":"Verify gate fired","ttl_s":900}\n' "$(date +%s)" > "$T/.buddy/s1.json"
out=$(printf '{"session_id":"s1"}' | RUN env BRAIN_DIR="$T" SB_BUDDY_COLS=120 bash "$ROOT/scripts/buddy-statusline.sh")
printf '%s' "$out" | grep -q 'Verify gate fired' || fail "buddy renderer lost the event under Windows jq: $out"
printf '%s' "$out" | grep -qF $'\e[38;2;245;158;11m○' || fail "the gate's warn-tinted steam dot was lost under Windows jq (CR contamination in the US-joined read): $out"
printf '%s' "$out" | grep -q 'probe' && fail "the configured name must never render in the statusline (thought-cloud redesign)"
pass "buddy-statusline.sh event + steam colour survive Windows jq"
rm -rf "$T"

# 4. 0.53.0: persona-context's two-way [buddy: ] line is TWO jq -rn output lines (feed cursor, then
#    the line). A CR left in either would poison the memo cursor (fromjson on "…}\r") or the context.
T=$(mktemp -d); mkdir -p "$T/.buddy" "$T/.injected"
printf '{"react":true}' > "$T/buddy.json"; : > "$T/.buddy/s2.seen"
printf '{"goal":"g","goal_kw":"g","prompts":2,"t0":%s}' "$(( $(date +%s) - 600 ))" > "$T/.injected/s2.json"
printf '{"ts":%s,"kind":"remembered","mood":"pleased","line":"Filed to memory: crlf probe","source":"stop-extract","ttl_s":900}\n' "$(( $(date +%s) - 5 ))" > "$T/.buddy/s2.log.jsonl"
raw=$(printf '{"session_id":"s2","prompt":"now implement the crlf probe for the buddy line"}' \
  | RUN env BRAIN_DIR="$T" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/persona-context.sh" 2>/dev/null)
ctx=$(printf '%s' "$raw" | "$REALJQ" -r '.hookSpecificOutput.additionalContext // ""')
printf '%s' "$ctx" | grep -q '^\[buddy: Kapi\]' || fail "buddy line missing under Windows jq: $ctx"
printf '%s' "$ctx" | grep -qF 'crlf probe' || fail "fed event missing under Windows jq: $ctx"
# Checked in the JSON itself (a real Windows jq -r would add its own CR on the way out): no byte 13
# in any line of the buddy block.
printf '%s' "$raw" | "$REALJQ" -e '.hookSpecificOutput.additionalContext | split("\n")
  | map(select(startswith("[buddy: ") or startswith("Filed to memory") or startswith("[End untrusted")))
  | length >= 3 and (map(explode | index(13)) | all(. == null))' >/dev/null \
  || fail "a CR reached Claude's context from the buddy block"
"$REALJQ" -e '(.buddy_fed | type) == "number" and (.buddy_fed_k | type) == "array"' "$T/.injected/s2.json" >/dev/null \
  || fail "feed cursor not recorded under Windows jq (CR in the cursor line?): $(cat "$T/.injected/s2.json")"
pass "persona-context two-way line + feed cursor survive Windows jq"
rm -rf "$T"

# 5. Slice 1 continuity (0.54.0): session-load.sh --compact under the Windows-jq CRLF stub.
#    The lean card's own stdin decode + Plan-line awk are jq-adjacent; a CR that survived
#    the `${v%$'\r'}` idiom would either poison the JSON parse or land inside a rendered
#    Plan line. The no-CR check stays INSIDE one jq -e (explode/index(13), like case 4's
#    buddy-block check above) rather than decoding via `jq -r` + od/grep: on the real
#    windows-latest runner jq is ALREADY the native CRLF build (F8) — `jq -r` itself adds a
#    trailing \r to every line there, so an od/grep-on-decoded-text oracle would flag a CR
#    that is native-jq's own -r behaviour, not a session-load.sh regression.
T=$(mktemp -d); mkdir -p "$T/.injected" "$T/projects/proj5"
cat > "$T/projects/proj5/PROJECT.md" <<'EOF'
# PROJECT: proj5

## Goal
GOAL-5

## Handoff
written: t=1789000000 session=abcdef12 branch=main head=abc1234
HANDOFF-5

## Plan
- [ ] item-one
- [ ] item-two

## Conventions
EOF
printf '%s' "proj5" > "$T/.injected/sid5.slug"
WORK5="$T/work5"; mkdir -p "$WORK5"
out=$(printf '{"session_id":"sid5","cwd":"%s","source":"compact"}' "$WORK5" \
  | RUN env BRAIN_DIR="$T" HOME="$T/home5" bash "$ROOT/scripts/session-load.sh" --compact)
printf '%s' "$out" | "$REALJQ" -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  || fail "case5: --compact output is not valid JSON with hookEventName==SessionStart under Windows jq (got: $out)"
ctx=$(printf '%s' "$out" | "$REALJQ" -r '.hookSpecificOutput.additionalContext')
item_n=$(printf '%s' "$ctx" | awk '/^Plan — unfinished/{f=1;next} f&&/^- /{c++} f&&!/^- /{exit} END{print c+0}')
[ "$item_n" = "2" ] || fail "case5: expected 2 rendered Plan item lines, got $item_n (ctx: $ctx)"
printf '%s' "$out" | "$REALJQ" -e '.hookSpecificOutput.additionalContext | explode | index(13) == null' >/dev/null 2>&1 \
  || fail "case5: a CR reached the compact-reinject card's additionalContext"
plan_field=$(grep -o 'gate=compact-reinject[^"]*plan=[0-9]*' "$T/audit-log.jsonl" 2>/dev/null | grep -o 'plan=[0-9]*' | tail -1 | cut -d= -f2)
case "${plan_field:-x}" in ''|*[!0-9]*) fail "case5: the audit row's plan= field did not parse as an integer (audit-log: $(cat "$T/audit-log.jsonl" 2>/dev/null))" ;; esac
pass "session-load.sh --compact renders 2 Plan items with no CR under Windows jq; gate row plan= is an integer"
rm -rf "$T"

# 5b. Same as case 5, but PROJECT.md itself is CRLF on disk (a Windows-authored or
# git-autocrlf-checked-out file, not just a Windows-jq artifact) — this is the fixture that
# actually exercises session-load.sh's own `_ccrlf` normalize-before-parse block (od-detects
# a 0d byte, tr -d '\r' into a scratch copy). Case 5's LF-only fixture never hits that branch
# at all, so removing the normalization entirely still passed case 5 — on MSYS, gawk's `##
# Plan$` line match tolerates a trailing \r anyway (it strips it internally), silently
# masking exactly the regression this fixture is meant to catch.
T5B=$(mktemp -d); mkdir -p "$T5B/.injected" "$T5B/projects/proj5b"
printf '%s\r\n' \
  '# PROJECT: proj5b' '' '## Goal' 'GOAL-5B' '' '## Handoff' \
  'written: t=1789000000 session=abcdef12 branch=main head=abc1234' 'HANDOFF-5B' '' \
  '## Plan' '- [ ] item-one' '- [ ] item-two' '' '## Conventions' \
  > "$T5B/projects/proj5b/PROJECT.md"
od -An -tx1 "$T5B/projects/proj5b/PROJECT.md" | grep -q ' 0d' \
  || fail "case5b: the CRLF fixture itself has no CR byte — test would be vacuous"
printf '%s' "proj5b" > "$T5B/.injected/sid5b.slug"
WORK5B="$T5B/work5b"; mkdir -p "$WORK5B"
out5b=$(printf '{"session_id":"sid5b","cwd":"%s","source":"compact"}' "$WORK5B" \
  | RUN env BRAIN_DIR="$T5B" HOME="$T5B/home5b" bash "$ROOT/scripts/session-load.sh" --compact)
[ -n "$out5b" ] && printf '%s' "$out5b" | "$REALJQ" -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  || fail "case5b: --compact on a CRLF PROJECT.md produced no/invalid output under Windows jq (got: $out5b)"
ctx5b=$(printf '%s' "$out5b" | "$REALJQ" -r '.hookSpecificOutput.additionalContext')
printf '%s' "$ctx5b" | grep -qF 'GOAL-5B' || fail "case5b: CRLF PROJECT.md's GOAL-5B missing from the card (ctx: $ctx5b)"
item5b_n=$(printf '%s' "$ctx5b" | awk '/^Plan — unfinished/{f=1;next} f&&/^- /{c++} f&&!/^- /{exit} END{print c+0}')
[ "$item5b_n" = "2" ] || fail "case5b: expected 2 rendered Plan item lines from a CRLF PROJECT.md, got $item5b_n (ctx: $ctx5b)"
grep -q 'reason=' "$T5B/audit-log.jsonl" "$T5B/error-log.jsonl" 2>/dev/null \
  && fail "case5b: a reason= (empty/no-project) row fired against a valid CRLF PROJECT.md"
pass "session-load.sh --compact normalizes a CRLF-on-disk PROJECT.md before parsing (GOAL-5B + 2 Plan items render)"
rm -rf "$T5B"

# 6'. compact_pending merged under the Windows-jq CRLF stub: the emitted Plan line is
#     add-only and PROJECT.md itself carries no \r (v2's open-work case 6 is dropped;
#     v3 reuses ## Plan -- Slice 1 spec v3 §6).
T=$(mktemp -d); mkdir -p "$T/projects/proj6" "$T/knowledge/wiki"
cat > "$T/projects/proj6/PROJECT.md" <<'EOF'
# PROJECT: proj6

## Plan

## Conventions
EOF
PROJ6="$T/projects/proj6/PROJECT.md"
printf '%s' '{"compact_pending":["x"]}' \
  | RUN env BRAIN_DIR="$T" bash "$ROOT/scripts/merge-project-update.sh" --project-md "$PROJ6" --knowledge-dir "$T/knowledge" >/dev/null 2>&1
grep -q '\[untrusted:compact' "$PROJ6" || fail "case6prime: compact_pending item was not merged under Windows jq (proj: $(cat "$PROJ6"))"
od -An -tx1 "$PROJ6" | grep -q ' 0d' && fail "case6prime: a CR leaked into PROJECT.md under Windows jq"
pass "compact_pending merge adds a Plan line with no CR in PROJECT.md under Windows jq"
rm -rf "$T"

echo; echo "ALL PASS"
