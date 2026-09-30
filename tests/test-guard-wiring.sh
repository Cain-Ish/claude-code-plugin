#!/bin/bash
# pins: SB_QUALITY_GATE — kill-switch test: asserts =off yields no envelope (D077)
# Behavioral guard (NOT a presence-grep): each PreToolUse safety guard must actually be REGISTERED
# in the real hooks/hooks.json with a matcher that COVERS every tool it protects. A guard that is
# unit-perfect but absent from hooks.json — or whose matcher silently drops a protected tool — is
# completely INERT in production (the persona-charter class: correct code that never reaches the
# harness). The per-guard unit tests pipe inputs straight to the script, bypassing this wiring, so
# without this test deleting a guard's hooks.json block (or narrowing its matcher) ships GREEN while
# the credential-exfil / wiki-frontmatter / secret-egress / tool-scope defense goes silently dead.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; HJ="$ROOT/hooks/hooks.json"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo; echo "ALL PASS"; exit 0; }
[ -f "$HJ" ] || fail "hooks/hooks.json missing"
jq -e . "$HJ" >/dev/null 2>&1 || fail "hooks/hooks.json is not valid JSON"

# matcher_for <guard.sh>: the PreToolUse matcher of the group that registers that guard (empty if none).
matcher_for(){ jq -r --arg g "$1" '.hooks.PreToolUse[]? | select([.hooks[]?.command]|join(" ")|test($g)) | .matcher' "$HJ" | head -1; }
# covers <guard.sh> <tool>: guard is registered AND its matcher matches the tool name EXACTLY.
covers(){ local m; m=$(matcher_for "$1"); [ -n "$m" ] || return 1; printf '%s' "$2" | grep -Eq "^(${m})\$"; }
check(){ local g="$1"; shift; [ -n "$(matcher_for "$g")" ] || fail "$g is NOT registered under PreToolUse in hooks.json (inert)"
  for t in "$@"; do covers "$g" "$t" || fail "$g matcher does not cover tool '$t' (matcher='$(matcher_for "$g")') — guard inert for $t"; done
  pass "$g wired under PreToolUse, matcher covers: $*"; }

# Each guard must cover every file/command-bearing tool it inspects.
check wiki-write-guard.sh    Write Edit MultiEdit
check symlink-guard.sh       Write Edit MultiEdit
check flow-guard.sh          Bash WebFetch WebSearch
check persona-tool-guard.sh  Bash Write Edit MultiEdit Read

# --- persona-tool-guard tool-scope REACHABILITY (the guard inspects per-tool inputs) ---
# The persona-tool-guard's matcher in the REAL hooks.json must be a SUPERSET of every
# file/command-bearing tool the guard actually reads input from. Grounded in the SOURCE
# (scripts/persona-tool-guard.sh), not a hand-maintained list, so a future guard edit that
# starts inspecting a new input field WITHOUT widening the matcher fails loudly here:
#   - tool_input.command   (Bash)               -> CMD=        line ~46
#   - tool_input.file_path (Write/Edit/...Read)  -> PATH_INPUT= line ~47
#   - tool_name allowlist  (every matched tool)  -> tool_scope  line ~63
# resource_scope.tools defaults (Write/Edit/MultiEdit/Read) are also command/file-bearing.
GUARD_SRC="$ROOT/scripts/persona-tool-guard.sh"
[ -f "$GUARD_SRC" ] || fail "scripts/persona-tool-guard.sh missing (cannot ground reachability)"

# 1. Derive the guard's DECLARED file/command-bearing intent from the source:
#    if the guard reads tool_input.command it must cover Bash; if it reads
#    tool_input.file_path it must cover the file tools it scopes. These are the
#    tools whose protection silently dies if the matcher narrows below them.
grep -q 'tool_input\.command'   "$GUARD_SRC" || fail "guard no longer reads tool_input.command — update the reachability contract"
grep -q 'tool_input\.file_path' "$GUARD_SRC" || fail "guard no longer reads tool_input.file_path — update the reachability contract"
PTG_INTENT="Bash Write Edit MultiEdit Read"
for t in $PTG_INTENT; do
  covers persona-tool-guard.sh "$t" \
    || fail "persona-tool-guard matcher is NOT a superset of its declared intent: missing '$t' (matcher='$(matcher_for persona-tool-guard.sh)') — guard inspects this tool's input but the matcher would never deliver it"
done
pass "persona-tool-guard matcher is a SUPERSET of its declared file/command-bearing intent ($PTG_INTENT)"

# 2. Pin the OUT-OF-SCOPE contract as a recorded decision (hooks.json _comment:
#    "MCP tools and read-only Glob/Grep/TodoWrite/BashOutput omitted to keep hook cost low").
#    These are deliberately NOT matched. If a future matcher edit accidentally pulls them in,
#    fail — so the exclusion stays an intentional decision, not silent scope creep.
not_covered(){ ! covers persona-tool-guard.sh "$1"; }
for t in mcp__example__do_thing Glob Grep NotebookEdit; do
  not_covered "$t" \
    || fail "persona-tool-guard matcher now MATCHES intentionally-out-of-scope tool '$t' (matcher='$(matcher_for persona-tool-guard.sh)') — out-of-scope contract broken; if intended, update this test + the hooks.json _comment"
done
pass "persona-tool-guard out-of-scope contract holds (mcp__*, Glob, Grep, NotebookEdit intentionally NOT matched)"

# --- B7: the dependency-free fast path is the SAME code in every deny/ask guard, and runs first ---
# A PreToolUse hook that answers after its timeout is cancelled and the tool RUNS (CLI 2.1.283
# probe, 2026-09-28), so each guard decides its dangerous cases in a shared builtin-only block
# before lib.sh or any spawn. The block is pasted, not sourced (sourcing is the dependency being
# avoided): this lock keeps the copies byte-identical, and keeps the block ahead of the first
# lib.sh source / jq spawn in each guard. Behavioral proof lives in each guard's own test (a
# sleeping lib.sh + sleeping PATH shims must not delay the dangerous-case verdict).
FP_GUARDS="persona-tool-guard.sh symlink-guard.sh wiki-write-guard.sh flow-guard.sh"
fp_block(){ sed -n '/^# >>> sb-guard-fastpath/,/^# <<< sb-guard-fastpath/p' "$ROOT/scripts/$1"; }
FP_REF=$(fp_block persona-tool-guard.sh)
[ -n "$FP_REF" ] || fail "persona-tool-guard.sh has no '# >>> sb-guard-fastpath' … '# <<< sb-guard-fastpath' block"
for g in $FP_GUARDS; do
  [ "$(fp_block "$g")" = "$FP_REF" ] \
    || fail "$g: sb-guard-fastpath block drifted from persona-tool-guard.sh's copy (keep the pasted copies byte-identical)"
  fp_at=$(grep -n '^# >>> sb-guard-fastpath' "$ROOT/scripts/$g" | head -1 | cut -d: -f1)
  dep_at=$(grep -nE '(source|\.) .*lib\.sh|(^|[^A-Za-z_])jq ' "$ROOT/scripts/$g" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
  [ -n "$dep_at" ] && [ "$fp_at" -lt "$dep_at" ] \
    || fail "$g: the fast-path block (line $fp_at) must precede the first lib.sh source / jq spawn (line ${dep_at:-none})"
done
pass "B7: sb-guard-fastpath block identical in $FP_GUARDS and ahead of lib.sh/jq in each"

# --- The block's helpers, loaded on their own (the block's one read gets EOF from /dev/null) ------
FPT=$(mktemp -d); trap 'rm -rf "$FPT"' EXIT
eval "$FP_REF" < /dev/null
# The wide-character cases below run under a UTF-8 locale, pinned here. DA #3 (0.54.1): the
# Windows lane starts `bash --noprofile --norc` with LANG unset — the C locale — where the 512 KB
# multibyte case read ${FPV:0:1} as the byte 0xC3, not 'é', and failed although the decode was
# byte-correct; and under C the wide-character slow path those bounds exist to lock never ran.
# C.UTF-8 first (MSYS, Linux), en_US.UTF-8 for a macOS without it; neither = a loud SKIP of the
# locale-bound assertions only, never a silent pass.
EACUTE=$'\303\251'
UTF8_LOC=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  # Probed by assignment in a subshell, the way this shell applies it below (a child bash reading
  # LC_ALL from its environment accepted a locale an assignment then refused, on MSYS).
  [ "$( (LC_ALL=$l; printf %s "${#EACUTE}") 2>/dev/null)" = 1 ] && { UTF8_LOC=$l; break; }
done
if [ -n "$UTF8_LOC" ]; then export LC_ALL="$UTF8_LOC"; echo "INFO: wide-character cases run under LC_ALL=$UTF8_LOC"
else echo "SKIP: no UTF-8 locale (C.UTF-8, en_US.UTF-8) — the character-count assertions below are skipped; byte assertions still run"; fi
# Milliseconds since a now_us stamp (bash 5's EPOCHREALTIME, digits only: its radix is locale's).
# Older bash has no clock builtin: whole seconds from `date`, so every bound is enforced on the
# macOS lane too (F8: a 0 there let a 447 s section pass a 3 s bound on bash 3.2).
now_us() { local n="${EPOCHREALTIME:-}"; n="${n//[!0-9]/}"; [ -n "$n" ] || n="$(date +%s)000000"; echo "$n"; }
ms_since() { local n; n=$(now_us); echo $(( (10#$n - 10#$1) / 1000 )); }
# nl_run VAR N: VAR = N newlines, built by tr — a ${v// /…} pass is O(matches x length^2) on
# bash < 4.3 (50,000 of them took minutes on 3.2); the '.' sentinel keeps $(…) from eating them.
nl_run() { local _nr; _nr=$(printf '%*s' "$2" '' | tr ' ' '\n'; printf .); printf -v "$1" '%s' "${_nr%.}"; }
fpstr() {  # fpstr KEY RAW [EOF=1] -> FPRC, FPV
  _FP_RAW="$2" _FP_EOF="${3:-1}"; _fp_str "$1"; FPRC=$?; FPV="$_FP"
}
# Item 17: below bash 4.3 (_fp_ob=1: macOS /bin/bash 3.2) _fp_at and _fp_str step aside and jq
# decides every key, as on main: there each case below must return 2, by design.
want_str() {  # want_str LABEL KEY RAW EXPECTED
  fpstr "$2" "$3"
  if [ "$_fp_ob" = 1 ]; then
    [ "$FPRC" = 2 ] || fail "_fp_str $1: bash < 4.3 must leave every key to jq (rc=$FPRC, want 2)"
    return 0
  fi
  [ "$FPRC" = 0 ] && [ "$FPV" = "$4" ] || fail "_fp_str $1: rc=$FPRC value=[$FPV] want [$4]"
}
want_rc() {  # want_rc LABEL KEY RAW RC [EOF]
  local want="$4"
  [ "$_fp_ob" = 1 ] && want=2
  fpstr "$2" "$3" "${5:-1}"
  [ "$FPRC" = "$want" ] || fail "_fp_str $1: rc=$FPRC want $want (value [$FPV])"
}
want_str "plain" file_path '{"tool_name":"Write","tool_input":{"file_path":"/a/b.txt","content":"x"}}' /a/b.txt
want_str "escaped quotes + backslash" content '{"tool_input":{"content":"say \"hi\" \\ back"}}' 'say "hi" \ back'
want_str "escaped backslash closes it" content '{"tool_input":{"content":"ends \\","k":"v"}}' 'ends \'
want_str "escaped quote at the end" content '{"tool_input":{"content":"q \"","k":"v"}}' 'q "'
want_str "odd run of backslashes" content '{"tool_input":{"content":"a \\\" b"}}' 'a \" b'
want_str "\\n \\t \\r \\/" content '{"tool_input":{"content":"l1\nl2\tt\rr\/s"}}' "l1"$'\n'"l2"$'\t'"t"$'\r'"r/s"
want_str "empty value" content '{"tool_input":{"content":""}}' ''
want_str "spaced separator" content '{"tool_input":{"content" :  "v"}}' v
want_str "leading escaped quote" content '{"tool_input":{"content":"\"x"}}' '"x'
want_rc "\\u escape left to jq" content '{"tool_input":{"content":"\u00e9"}}' 2
want_rc "non-string value" content '{"tool_input":{"content":5}}' 2
want_rc "duplicate key" content '{"tool_input":{"content":"a","content":"b"}}' 2
want_rc "key text also a value" file_path '{"x":"file_path","tool_input":{"file_path":"/ok"}}' 2
want_rc "absent" command '{"tool_input":{"file_path":"x"}}' 1
want_rc "absent, \\\\u is an escaped backslash" command '{"tool_input":{"file_path":"C:\\users\\x"}}' 1
want_rc "absent, the key may be \\u-spelled (SEC-L1)" file_path '{"tool_input":{"file\u005fpath":"/h/.ssh/x"}}' 2
want_rc "value runs past the read" content '{"tool_input":{"content":"abc' 2 0
want_str "value closes right at the read's end" content '{"tool_input":{"content":"abc"' abc
want_rc "absent, payload not all read" content '{"a":"b"' 2 0
pass "_fp_str decodes like jq, and returns 2 wherever jq must decide (escapes, duplicates, \\u-spelled keys)"

# P-M2: no ${v//…} pass decodes a value any more — one costs O(matches x length) (bash < 4.3 even
# in ASCII; every bash in a multibyte string). A value without a backslash returns as it is; an
# escaped one is cut at its backslashes.
# Item 17: the bash < 4.3 gate, emulated here on any bash (_fp_ob=1): every key is jq's, rc 2 —
# found, absent or big alike. The macOS lane runs the cases above and below with its real _fp_ob=1.
FP_OB_BASH=$_fp_ob   # this bash's own answer (1 below 4.3: the macOS lane), restored after the emulation
_fp_ob=1
fpstr file_path '{"tool_input":{"file_path":"/a"}}'; [ "$FPRC" = 2 ] || fail "bash < 4.3 gate: a plain value must be jq's (rc=$FPRC)"
fpstr command '{"tool_input":{"file_path":"x"}}'; [ "$FPRC" = 2 ] || fail "bash < 4.3 gate: an absent key must be jq's too (rc=$FPRC)"
_FP_RAW='{"a":"b"}' _FP_EOF=1; _fp_at a; [ $? = 2 ] || fail "bash < 4.3 gate: _fp_at must return 2"
_fp_ob=$FP_OB_BASH
V16=$(printf '%16000s' '' | tr ' ' a)
want_str "16000 chars, no escape (early return)" content "{\"content\":\"$V16\"}" "$V16"
# DA #1 (0.54.1): each escape costs one bash iteration (~110-120 us on MSYS), so _fp_str leaves a
# value with more than _fp_emax of them to jq (rc 2) — at the cap it decodes; one more is jq's.
[ "${_fp_emax:-0}" -ge 1000 ] || fail "_fp_emax (the escape cap) is missing from the fast-path block or below 1000"
ESCK=$(i=0; while [ $i -lt "$_fp_emax" ]; do printf 'a\\n'; i=$((i + 1)); done)
fpstr content "{\"content\":\"$ESCK\"}"
if [ "$_fp_ob" = 1 ]; then [ "$FPRC" = 2 ] || fail "_fp_str: bash < 4.3 must leave the cap case to jq (rc=$FPRC)"
else
  [ "$FPRC" = 0 ] && [ "${#FPV}" = $((2 * _fp_emax)) ] && [ "${FPV:0:4}" = "a"$'\n'"a"$'\n' ] \
    || fail "_fp_str: $_fp_emax escapes (the cap): rc=$FPRC length=${#FPV}"
fi
want_rc "one escape past the cap" content "{\"content\":\"${ESCK}a\\n\"}" 2
want_str "escapes of every kind" content '{"content":"a\nb\\c\"d\/e\tf\\\\ng"}' "a"$'\n'"b\\c\"d/e"$'\t'"f\\\\ng"
pass "P-M2: _fp_str returns a backslash-free value as it is, decodes escapes without substitution passes, up to _fp_emax=$_fp_emax"

# DA #1: a value past the cap is refused before any per-escape work — the refusal itself must stay
# linear. Escaped quotes (each one a '"' field the closing-quote search walks) and newline escapes
# (each one a '\' field the decode walks), 300 KB each, under the multibyte locale.
QD=$(printf '%100000s' '' | sed 's/ /\\"a/g')
NLD=$(printf '%150000s' '' | sed 's/ /a\\n/g')
t0=$(now_us)
fpstr command "{\"tool_input\":{\"command\":\"$EACUTE$QD rm -rf /x\"}}"; QRC=$FPRC
fpstr command "{\"tool_input\":{\"command\":\"$EACUTE$NLD rm -rf /x\"}}"; NRC=$FPRC
el=$(ms_since "$t0")
[ "$QRC" = 2 ] && [ "$NRC" = 2 ] || fail "DA #1: escape-dense values must be left to jq: 100k \\\" rc=$QRC, 150k \\n rc=$NRC (want 2, 2)"
[ "$el" -le 3000 ] || fail "DA #1: refusing two escape-dense 300-450 KB values took ${el} ms (bound 3000)"
pass "DA #1: 100k escaped quotes and 150k newline escapes are left to jq in ${el} ms"

# The multibyte shape that took 117 s: a 512 KB multi-line text holding one non-ASCII character,
# CRLF line ends, through _fp_nocr (the ~6,500-escape JSON value it used to arrive in is jq's now).
ML=$(printf '%524288s' '' | tr ' ' x | fold -w 80 | awk '{printf "%s\r\n", $0}')
ML="$EACUTE$ML"
t0=$(now_us)
_fp_nocr NOCR "$ML"
el=$(ms_since "$t0")
case "$NOCR" in *$'\r'*) fail "_fp_nocr left a CR" ;; esac
[ "${NOCR:0:2}" = "${EACUTE}x" ] || [ -z "$UTF8_LOC" ] || fail "_fp_nocr lost the leading multibyte character"
[ "$(printf '%s' "$NOCR" | LC_ALL=C wc -c | tr -d ' ')" = $(( $(printf '%s' "$ML" | LC_ALL=C wc -c | tr -d ' ') - $(printf '%s' "$ML" | tr -cd '\r' | LC_ALL=C wc -c | tr -d ' ') )) ] \
  || fail "_fp_nocr must drop exactly the CR bytes"
[ "$el" -le 5000 ] || fail "P-M2: CR-stripping a 512 KB multibyte text took ${el} ms (bound 5000)"
# Under the cap a multibyte value still decodes, character-exact (byte-exact without a UTF-8 locale).
MB=$(i=0; while [ $i -lt $((_fp_emax / 2)) ]; do printf 'x\\r\\n'; i=$((i + 1)); done)
fpstr command "{\"tool_input\":{\"command\":\"$EACUTE$MB\"}}"
if [ "$_fp_ob" = 1 ]; then
  [ "$FPRC" = 2 ] || fail "_fp_str: bash < 4.3 must leave a multibyte value to jq (rc=$FPRC)"
  FPV="$EACUTE"   # nothing decoded to check below
elif [ "$FPRC" != 0 ]; then fail "_fp_str: a multibyte value with $_fp_emax escapes must decode (rc=$FPRC)"
elif [ -n "$UTF8_LOC" ]; then
  [ "${FPV:0:1}" = "$EACUTE" ] && [ "${#FPV}" = $((1 + 3 * (_fp_emax / 2))) ] \
    || fail "_fp_str: multibyte decode: first [${FPV:0:1}] length ${#FPV} (want é, $((1 + 3 * (_fp_emax / 2))))"
fi
[ "$(LC_ALL=C; printf '%s' "${FPV:0:2}")" = "$EACUTE" ] || fail "_fp_str: multibyte decode: the first two bytes are not é"
pass "P-M2: a 512 KB multibyte CRLF text loses exactly its CRs in ${el} ms; multibyte values decode under the cap"

_fp_uesc 'a\u0041' || fail "_fp_uesc: \\u0041 is an escape"
_fp_uesc 'C:\\users' && fail "_fp_uesc: \\\\u (an escaped backslash, then u) is no escape"
_fp_uesc 'x\\\u0041' || fail "_fp_uesc: \\\\\\u0041 ends in an escape"
pass "_fp_uesc tells a \\u escape from an escaped backslash followed by u"

# P-H1: every helper is linear. A key behind 512 KB of content cost 144 s through ${RAW#*"KEY"}.
# F8 item 20: past 64 KiB the payload is jq's (rc 2) — every key cut the whole payload, five of
# them 1.2 s over a 1 MB Write of escaped quotes; a key behind ~60 KB is still read in place.
BIG=$(printf '%524288s' '' | tr ' ' x)
B60=${BIG:0:61440}
t0=$(now_us)
fpstr file_path "{\"tool_input\":{\"content\":\"$BIG\\\"q\\\\\",\"file_path\":\"/late/p\"}}"
[ "$FPRC" = 2 ] || fail "_fp_str: a payload past 64 KiB must be left to jq (rc=$FPRC, want 2)"
fpstr file_path "{\"tool_input\":{\"content\":\"$B60\\\"q\\\\\",\"file_path\":\"/late/p\"}}"
if [ "$_fp_ob" = 1 ]; then
  # bash < 4.3 (the macOS lane's 3.2): every key is jq's by design (item 17, see _fp_at).
  [ "$FPRC" = 2 ] || fail "_fp_str on bash < 4.3: a key after 60 KB must be left to jq (rc=$FPRC, want 2)"
else
  [ "$FPRC" = 0 ] && [ "$FPV" = /late/p ] || fail "_fp_str: key after 60 KB of content: rc=$FPRC value=[$FPV]"
  fpstr content "{\"tool_input\":{\"content\":\"$B60\\\"q\\\\\",\"file_path\":\"/late/p\"}}"
  [ "$FPRC" = 0 ] && [ "${#FPV}" = $(( ${#B60} + 3 )) ] || fail "_fp_str: 60 KB value: rc=$FPRC length=${#FPV}"
fi
RAW="$BIG"$'\n\n'; _FP_EOF=1 _FP_RAW="$RAW"; _fp_raw_all
[ "$RAW" = "$BIG" ] || fail "_fp_raw_all must strip trailing newlines"
el=$(ms_since "$t0")
[ "$el" -le 5000 ] || fail "P-H1: _fp_str/_fp_raw_all over 512 KB took ${el} ms (bound 5000) — quadratic again?"
pass "P-H1: _fp_str finds a key behind 60 KB, leaves a 512 KB payload to jq, and _fp_raw_all strips newlines in ${el} ms"

# RR-CR1 / F8 #1: the trailing-newline trims — the guards' _fp_trimnl and protocol-guard's
# pg_trimnl (extracted verbatim) — against the per-newline loop they replaced (O(N x length), but
# the reference semantics), byte for byte. The regex that sat between the two was O(run^2) on glibc
# for a run followed by any other text (`rm -rf ~/proj`, 50,000 newlines, `#`: 22-39 s per guard on
# Debian; MSYS's engine is linear, so only the timing below would catch it there — and the static
# lock in test-script-portability.sh check 19 keeps the regex out). Run in the UTF-8 locale and in
# C, and each trim must leave the caller's locale as it found it.
ref_trim() { local v="$2"; while case "$v" in *$'\n') true ;; *) false ;; esac; do v="${v%$'\n'}"; done; printf -v "$1" '%s' "$v"; }
PG_SRC="$ROOT/scripts/protocol-guard.sh"
PG_TRIM=$(awk '$0 == "pg_trimnl() {" { p = 1 } p { print } p && $0 == "}" { exit }' "$PG_SRC")
[ -n "$PG_TRIM" ] || fail "protocol-guard.sh has no 'pg_trimnl() {' … '}' function (its RAW trim must be the regex-free search)"
_pg_nl=$'\n'
eval "$PG_TRIM"
# trim_case FN LABEL TEXT: FN's result must equal ref_trim's, byte for byte.
trim_case() {
  local want got
  ref_trim want "$3"; "$1" got "$3"
  # [ = ] is strcmp: byte-exact, and no fork per case.
  [ "$want" = "$got" ] \
    || fail "$1 [$2]: got $(printf '%s' "$got" | od -An -tx1 | tr -d ' \n' | cut -c1-80) want $(printf '%s' "$want" | od -An -tx1 | tr -d ' \n' | cut -c1-80)"
}
trim_battery() {  # trim_battery FN: every edge shape against the reference
  local fn="$1" f s o i k r
  for f in '' '\n' '\n\n\n' 'a' 'a\n' 'a\n\n' '\r\n' 'a\r\n\n' 'a\r' 'a\n\nb' 'a\n\nb\n' 'a\n\nb\n\n' \
           '\303\251\n\n' '\342\202\254\n' '\360\237\230\200\n\n' '\377\n\n' '\342\202\n\n' '\303\n' \
           'a\303\n\303b\n' '\200\200\n' '\t\n\t\n' '\v\f\n' ' \n \n'; do
    printf -v s "$f"; trim_case "$fn" "$f" "$s"
  done
  for ((i = 1; i < 256; i++)); do printf -v o '%03o' "$i"; printf -v s "\\$o\n\n\n"; trim_case "$fn" "byte \\$o" "$s"; done
  for k in $(seq 1 33) 1023 1024 1025; do
    nl_run r "$k"
    trim_case "$fn" "x+${k}nl" "x$r"; trim_case "$fn" "${k}nl only" "$r"; trim_case "$fn" "é+${k}nl+y+${k}nl" "$EACUTE$r"y"$r"
  done
}
# trim_locale FN: the caller's LC_ALL — set, set to another value, or unset — survives the call.
trim_locale() {
  local fn="$1" x
  if [ -n "$UTF8_LOC" ]; then
    LC_ALL="$UTF8_LOC"; "$fn" x "$EACUTE"$'\n\n'
    [ "${LC_ALL-unset}" = "$UTF8_LOC" ] && [ "${#x}" = 1 ] && x="$EACUTE" && [ "${#x}" = 1 ] \
      || fail "$fn changed the caller's locale (LC_ALL=${LC_ALL-unset}, len(é)=${#x})"
  fi
  LC_ALL=C; "$fn" x $'a\n'; [ "${LC_ALL-unset}" = C ] || fail "$fn did not restore LC_ALL=C (got ${LC_ALL-unset})"
  unset LC_ALL; "$fn" x $'a\n'; [ "${LC_ALL-unset}" = unset ] || fail "$fn left LC_ALL set (${LC_ALL}) where the caller had none"
  [ -z "$UTF8_LOC" ] || export LC_ALL="$UTF8_LOC"
}
for fn in _fp_trimnl pg_trimnl; do
  LC_ALL=C; trim_battery "$fn"
  if [ -n "$UTF8_LOC" ]; then LC_ALL="$UTF8_LOC"; trim_battery "$fn"; fi
  trim_locale "$fn"
done
pass "RR-CR1: _fp_trimnl and pg_trimnl cut exactly the trailing newline run (330+ shapes, UTF-8 and C) and leave the caller's locale alone"
# 50,000 newlines: interior (the glibc O(run^2) shape), trailing, both — each FN, one bound.
nl_run r 50000
t0=$(now_us)
for fn in _fp_trimnl pg_trimnl; do
  "$fn" o "${EACUTE}rm -rf ~/proj$r#"; [ "$o" = "${EACUTE}rm -rf ~/proj$r#" ] || fail "$fn: 50,000 interior newlines must survive (len ${#o})"
  "$fn" o "${EACUTE}rm -rf ~/proj$r"; [ "$o" = "${EACUTE}rm -rf ~/proj" ] || fail "$fn: 50,000 trailing newlines must go (len ${#o})"
  "$fn" o "${EACUTE}rm$r#$r"; [ "$o" = "${EACUTE}rm$r#" ] || fail "$fn: interior + trailing 50,000-newline runs (len ${#o})"
done
el=$(ms_since "$t0")
[ "$el" -le 3000 ] || fail "RR-CR1: six 50,000-newline trims took ${el} ms (bound 3000) — a per-newline or O(run^2) trim is back?"
pass "RR-CR1: 50,000-newline interior/trailing/both runs trimmed by both functions in ${el} ms"

# F8 item 18: _fp_lower, byte for byte against `LC_ALL=C tr` over explicit A-Z/a-z lists (only ASCII
# capitals change; É, invalid UTF-8 and every other byte pass through), in the UTF-8 locale and in C,
# the caller's LC_ALL left as it was — and linear: its per-character loop took 1.8 s at 16 KB on
# MSYS and never finished wiki-write-guard's 50,000-character file_path (a fail-open).
ref_lower() { local t; t=$(printf '%s.' "$2" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz); printf -v "$1" '%s' "${t%.}"; }
lower_case() {  # lower_case LABEL TEXT: _fp_lower == ref_lower, and LC_ALL survives
  local want got before="${LC_ALL-unset}"
  ref_lower want "$2"; _fp_lower got "$2"
  [ "$want" = "$got" ] \
    || fail "_fp_lower [$1]: got $(printf '%s' "$got" | od -An -tx1 | tr -d ' \n' | cut -c1-80) want $(printf '%s' "$want" | od -An -tx1 | tr -d ' \n' | cut -c1-80)"
  [ "${LC_ALL-unset}" = "$before" ] || fail "_fp_lower [$1] changed the caller's LC_ALL ($before -> ${LC_ALL-unset})"
}
LSWEEP_FMT=""; for ((i = 1; i < 256; i++)); do printf -v o '\\%03o' "$i"; LSWEEP_FMT="$LSWEEP_FMT$o"; done
printf -v LSWEEP "$LSWEEP_FMT"
for loc in C ${UTF8_LOC:+"$UTF8_LOC"}; do
  LC_ALL=$loc
  for f in '' 'abc' 'ABC' 'Persona-Rules.JSON' 'C:/Users/Me/Project/X.md' 'aB' 'Ab' 'AA' 'A.' 'aB.' '.' \
           '\303\211A' '\303\251B\303\251' '\377A\342\202B' '%sA\\x%%' '*?[A]' 'a\nB\n' 'A B\tC' 'ZzYyXx'; do
    s=""; printf -v s "$f"; lower_case "$loc $f" "$s"   # bash 3.2 assigns nothing for an empty format
  done
  lower_case "$loc byte sweep 0x01-0xFF" "$LSWEEP"
done
export LC_ALL="${UTF8_LOC:-C}"; [ -n "$UTF8_LOC" ] || unset LC_ALL
nl_run r 50000
L50P="/X/Users/Me/knowledge/wiki/concepts/CR1${r}.MD"
L50U=$(printf '%50000s' '' | tr ' ' Q)
L50M=$(printf '%25000s' '' | sed 's/ /aZ/g')
t0=$(now_us)
_fp_lower o1 "$L50P"; _fp_lower o2 "$L50U"; _fp_lower o3 "$EACUTE$L50M"
el=$(ms_since "$t0")
ref_lower w1 "$L50P"; ref_lower w2 "$L50U"; ref_lower w3 "$EACUTE$L50M"
[ "$o1" = "$w1" ] && [ "$o2" = "$w2" ] && [ "$o3" = "$w3" ] || fail "_fp_lower: a 50,000-character text differs from tr's lowering"
[ "$el" -le 3000 ] || fail "item 18: _fp_lower over three 50,000-character texts took ${el} ms (bound 3000) — quadratic again?"
pass "item 18: _fp_lower == LC_ALL=C tr over 20 edge shapes and a 0x01-0xFF sweep (C and UTF-8); three 50,000-character texts in ${el} ms"

# SEC-H1: over 64 lines, _fp_lines answers 2 (undecidable: the full logic's grep decides).
_fp_lines 'rm -rf' $'ls\nrm -rf x'; [ $? = 0 ] || fail "_fp_lines: a matching second line must return 0"
L70=$(i=0; while [ $i -lt 70 ]; do printf 'line %s\n' $i; i=$((i+1)); done; printf 'rm -rf x')
_fp_lines 'rm -rf' "$L70"; [ $? = 2 ] || fail "_fp_lines: 71 lines must return 2 (undecidable)"
_fp_lines 'zzz' "$L70"; [ $? = 1 ] || fail "_fp_lines: no whole-text match must return 1 at any length"
_fp_lines 'rm -rf' 'rm -rf x'; [ $? = 0 ] || fail "_fp_lines: a one-line match must return 0"
pass "SEC-H1: _fp_lines decides up to 64 lines, returns 2 beyond"

_fp_collapse o /a/b/../../../c/./d//e; [ "$o" = /c/d/e ] || fail "_fp_collapse: got [$o]"
_fp_collapse o /; [ "$o" = / ] || fail "_fp_collapse root: got [$o]"
_fp_collapse o rel/../x; [ "$o" = rel/../x ] || fail "_fp_collapse must leave a relative path alone: got [$o]"
pass "_fp_collapse folds '.'/'..' of an absolute path lexically"

# SEC-C1: on MSYS, `cmd <<< "$X"` hangs for good when X+newline is 65,536..~65,690 bytes (bash
# writes the whole here-string into a pipe before starting the reader). _fp_feed must return for
# every size in that window. Run the sweep in the background with a watchdog: a hang must fail the
# test, not hang it (stdout to a file, so an orphaned writer cannot hold a pipe open).
fp_sweep() {
  local n x
  for n in 65530 65535 65536 65537 65544 65560 65584 65600 65616 65632 65648 65664 65680 65696 65712 70000; do
    x=$(printf "%${n}s" '' | tr ' ' a)
    _fp_feed "$x" grep -c a > "$FPT/c" || return 1
    [ "$(tr -d '\r' < "$FPT/c")" = 1 ] || return 1
  done
  echo done
}
fp_sweep > "$FPT/sweep" 2>&1 & SW=$!
i=0; while kill -0 "$SW" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$SW" 2>/dev/null; then kill "$SW" 2>/dev/null; fail "SEC-C1: _fp_feed did not return within 60 s for a 65,536..65,712-byte text (MSYS here-string hang)"; fi
wait "$SW"; [ "$(cat "$FPT/sweep")" = done ] || fail "SEC-C1: _fp_feed fed the wrong text in the 65,536..65,712-byte window ($(cat "$FPT/sweep"))"
pass "SEC-C1: _fp_feed returns and feeds the text intact across the 65,536..65,712-byte here-string window"

# No here-string of payload data outside _fp_feed in any guard (a static lock beside the behavioral one).
for g in $FP_GUARDS; do
  hs=$(grep -n '<<<' "$ROOT/scripts/$g" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vE '_fd_t"|_SPINE_(TXT|SPANS)"' || true)
  [ -z "$hs" ] || fail "$g: here-string outside _fp_feed (SEC-C1: hangs on MSYS at 64 KiB): $hs"
done
pass "SEC-C1: no guard feeds a here-string except through _fp_feed (the spine's are capped at 8192 chars)"

# --- PostToolUse output reachability (D158): plain stdout from a PostToolUse
# hook is only ever shown in transcript mode -- hookSpecificOutput.additionalContext
# JSON is the only path into model context (the pattern simplicity-gate.sh already
# uses). quality-gate.sh used to `echo` plain text, which never reached the model.
# Also locks its D077 kill switch.
QG="$ROOT/scripts/quality-gate.sh"
[ -f "$QG" ] || fail "scripts/quality-gate.sh missing"
QG_OUT=$(bash "$QG" 2>/dev/null)
[ -n "$QG_OUT" ] && printf '%s' "$QG_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 \
  || fail "quality-gate.sh does not emit a PostToolUse hookSpecificOutput envelope (got: $QG_OUT)"
[ -n "$QG_OUT" ] && printf '%s' "$QG_OUT" | jq -e '(.hookSpecificOutput.additionalContext | length) > 0' >/dev/null 2>&1 \
  || fail "quality-gate.sh envelope has no additionalContext text (got: $QG_OUT)"
pass "quality-gate.sh emits hookSpecificOutput.additionalContext (reaches model context)"
QG_OFF=$(SB_QUALITY_GATE=off bash "$QG" 2>/dev/null)
[ -z "$QG_OFF" ] || fail "SB_QUALITY_GATE=off must silence quality-gate.sh (got: $QG_OFF)"
pass "SB_QUALITY_GATE=off kill switch silences quality-gate.sh"

# review follow-up: a jq-less host must still emit the envelope (printf + a
# minimal escaper), not fall through `|| true` into silence. Filter every
# directory that carries a `jq`/`jq.exe` binary out of PATH — bash and the
# other real tools stay intact (a swapped-in standalone bash.exe/symlink loses
# its sibling DLLs on Windows and fails to launch at all), so `command -v jq`
# inside the script genuinely fails rather than merely shadowing the binary.
# Filtering PATH is not portable: on Linux jq shares /usr/bin with bash itself, so the
# filtered PATH cannot even launch the script. Shadow jq with a failing shim instead —
# the script's `jq … && exit 0` then falls through to the hand-built envelope exactly as
# it would on a host whose jq is missing or broken.
QG_NOJQ_DIR=$(mktemp -d)
printf '#!/bin/sh\nexit 127\n' > "$QG_NOJQ_DIR/jq"; chmod +x "$QG_NOJQ_DIR/jq"
QG_NOJQ=$(PATH="$QG_NOJQ_DIR:$PATH" bash "$QG" 2>/dev/null)
rm -rf "$QG_NOJQ_DIR"
[ -n "$QG_NOJQ" ] || fail "review follow-up: quality-gate.sh emitted NOTHING on a jq-less host (got empty)"
printf '%s' "$QG_NOJQ" | grep -q '"hookEventName":"PostToolUse"' \
  || fail "review follow-up: jq-less quality-gate.sh envelope missing hookEventName (got: $QG_NOJQ)"
printf '%s' "$QG_NOJQ" | grep -q '"additionalContext":"QUALITY GATE' \
  || fail "review follow-up: jq-less quality-gate.sh envelope missing additionalContext text (got: $QG_NOJQ)"
pass "review follow-up: quality-gate.sh emits the envelope by hand on a jq-less host"

# --- hooks.notes.md coverage (BIDIRECTIONAL) -------------------------------
# Hook rationale used to live as `_comment` keys inside hooks/hooks.json. Claude
# Code's hook-config schema rejects unknown keys and warned on all 13 of them, so
# the prose moved to hooks/hooks.notes.md. Prose that no gate checks rots, and a
# hook whose "why" is lost gets deleted by the next person who cannot see why it
# exists — so both directions are enforced here. The anchor is the SCRIPT NAME,
# never an array index: reordering hooks.json must not silently misalign a note.
NOTES="$ROOT/hooks/hooks.notes.md"
[ -f "$NOTES" ] || fail "hooks/hooks.notes.md missing — hook rationale has no home"
grep -q '"_comment"' "$HJ" \
  && fail "hooks/hooks.json carries a _comment key again — Claude Code's hook schema rejects unknown keys and drops them with a warning; put the prose in hooks/hooks.notes.md instead"

HN_TMP=$(mktemp -d)
# "### <Event> — <script.sh>" -> "<Event> <script.sh>". Space-separated on
# purpose: no event name or script name contains a space, and a literal tab in a
# sed replacement is not portable to BSD sed.
sed -n 's/^### \(.*\) — \(.*\)$/\1 \2/p' "$NOTES" > "$HN_TMP/notes.txt"
[ -s "$HN_TMP/notes.txt" ] \
  || { rm -rf "$HN_TMP"; fail "hooks.notes.md has no '### <Event> — <script.sh>' headings — the key format is broken, so neither direction below can hold"; }

# Direction 1 — no stale notes: every heading names a script that some hook under
# that event actually runs.
while read -r n_ev n_sc; do
  [ -n "$n_ev" ] && [ -n "$n_sc" ] || continue
  jq -e --arg ev "$n_ev" --arg sc "$n_sc" \
     '(.hooks[$ev]? // []) | map(.hooks[]?.command) | any(contains("/" + $sc))' "$HJ" >/dev/null 2>&1 \
    || { rm -rf "$HN_TMP"; fail "hooks.notes.md documents '$n_ev — $n_sc' but no $n_ev hook in hooks.json runs that script — stale note (hook removed or renamed?)"; }
done < "$HN_TMP/notes.txt"
pass "hooks.notes.md: all $(wc -l < "$HN_TMP/notes.txt" | tr -d ' ') headings resolve to live hooks.json commands"

# Direction 2 — no undocumented wiring: every hook GROUP is named by at least one
# heading. Wrappers (hook-timer.sh) share the command line with the real script;
# one match anywhere in the group is enough, so wrappers need no note of their own.
jq -r '.hooks | to_entries[] | .key as $ev | .value | to_entries[]
       | "\($ev) \(.key) \((.value.hooks // []) | map(.command) | join(" "))"' "$HJ" \
  | tr -d '\r' > "$HN_TMP/groups.txt"
while read -r g_ev g_idx g_cmds; do
  [ -n "$g_ev" ] || continue
  g_hit=0
  for g_sc in $(printf '%s' "$g_cmds" | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u); do
    grep -Fqx "$g_ev $g_sc" "$HN_TMP/notes.txt" && { g_hit=1; break; }
  done
  [ "$g_hit" = "1" ] \
    || { rm -rf "$HN_TMP"; fail "hooks.json $g_ev[$g_idx] is undocumented — add a '### $g_ev — <script.sh>' section to hooks/hooks.notes.md naming one of its scripts ($g_cmds)"; }
done < "$HN_TMP/groups.txt"
pass "hooks.notes.md: all $(wc -l < "$HN_TMP/groups.txt" | tr -d ' ') hooks.json groups are documented"
rm -rf "$HN_TMP"

echo; echo "ALL PASS"
