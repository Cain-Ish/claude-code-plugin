#!/bin/bash
# stop-verify-gate.sh — Stop hook verification gate
# Blocks completion when code was modified but no verification evidence exists.
# Returns {"decision":"block","reason":"..."} to force Claude to run checks.
#
# Kill switch: SB_VERIFY_GATE=off
# Safety valve: blocks at most 2 times per session (marker file).
# Fails open on missing data (no stdin/transcript → approve). Transcript scans parse
# per line: a torn or non-object line is skipped and counted in an error-log row. A
# scan that FAILS (jq rc != 0) is logged as gate=verify-<scan>-scan and fails CLOSED:
# one block per session, never a silent approve (policy at "Transcript scans" below).
# Evidence is a TOOL CALL issued after the last edit (B6): a passing check command
# run through Bash, or a Skill call named on VERIFY_SKILLS_JSON. Assistant prose is
# never evidence — it can name any skill without running it.
set -u

# Verification skills (B6): the ONLY Skill tool_use names that count as evidence,
# compared EXACTLY against input.skill (full string, plugin namespace included).
# No substring or namespace-stripped matching: `sb-validation-and-qa` is a reference
# skill, `ecc:security-scan` audits agent config, `second-brain:review` is a blocker
# dashboard — none of them checks a code change. `simplify` is off the list too: it
# refactors code, it verifies nothing (SEC-L2). Extend this list (and the B6 cases
# in tests/test-stop-verify-gate.sh) when a new verification skill ships.
VERIFY_SKILLS_JSON='[
  "review","security-review","code-review","verification-loop","devils-advocate",
  "engineering:code-review",
  "ecc:code-review","ecc:security-review","ecc:verification-loop","ecc:verify",
  "ecc:quality-gate","ecc:review-pr","ecc:orch-review",
  "ecc:python-review","ecc:go-review","ecc:rust-review","ecc:kotlin-review","ecc:cpp-review",
  "ecc:flutter-review","ecc:react-review","ecc:vue-review","ecc:fastapi-review"
]'
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

[ "${SB_VERIFY_GATE:-on}" = "off" ] && exit 0
[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_INTENT_SPINE:=off}" # hook-profile shim: this check runs before lib.sh's mapping (script is lib-less until the audit call)

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

TRANSCRIPT=$(printf '%s' "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
MARKER="$BRAIN_DIR/.verify-gate-blocks-$SESSION_ID"
# Dedicated anti-game scan window marker: records how far into the
# transcript the last anti-game evaluation scanned, so a historical test-deletion is
# not re-flagged every Stop (which burned both slots of the 2-block valve). This is
# a SEPARATE marker from stop-extract.sh's extraction marker — that one is owned by
# stop-extract.sh, which runs AFTER this hook; advancing it here would skip lines.
AG_MARKER="$BRAIN_DIR/.verify-gate-agseen-$SESSION_ID"

# Loud failure: a jq error in a transcript scan (bad regex on an older jq, a killed
# process) or a corrupt marker must leave a row, not silently weaken the gate.
_svg_scan_error() {  # message exit-code
  if ! command -v sb_log_error >/dev/null 2>&1; then
    if ! source "$(dirname "$0")/lib.sh" 2>/dev/null; then
      printf 'stop-verify-gate.sh: %s (rc=%s)\n' "$1" "$2" >&2
      return 0
    fi
  fi
  sb_log_error "stop-verify-gate.sh" "$1" "$2"
}

# Safety valve: max 2 blocks per session to prevent infinite loops.
# SEC-H3: the marker is DATA. Bash arithmetic evaluates a variable's value as an
# expression, so $((BLOCK_COUNT + 1)) on a marker holding `x[$(cmd)]` ran cmd. Only a
# plain number is accepted; anything else reads as 0 (the gate stays armed) and is logged.
BLOCK_COUNT=0
[ -f "$MARKER" ] && BLOCK_COUNT=$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')
case "$BLOCK_COUNT" in
  '') BLOCK_COUNT=0 ;;
  *[!0-9]*)
    BLOCK_COUNT=0
    _svg_scan_error "gate=verify-marker block-count marker $MARKER is not a number; treated as 0 (gate stays armed)" 1
    ;;
  *) BLOCK_COUNT=$((10#$BLOCK_COUNT)) ;;   # digits only; 10# so "08" is not read as octal
esac
if [ "$BLOCK_COUNT" -ge 2 ]; then
  exit 0
fi

# --- Transcript scans (SF-M2) -----------------------------------------------------
# Every scan reads the transcript FILE as raw lines (jq -nR ... inputs) and parses
# each line on its own (fromjson?):
#   - A torn/unparseable or non-object line costs only itself. A JSON-stream scan
#     stopped at the first bad line; before the first edit that emptied the
#     changed-file set and the gate approved without logging anything.
#   - Any real jq error aborts the scan with a non-zero rc. In jq's default
#     one-program-per-record mode the exit status reflects only the LAST record, so
#     an error mid-transcript used to exit 0.
#   - Windowed scans number lines themselves (foreach) instead of piping
#     `awk 'NR>s'` into jq: that MSYS pipe alone cost ~3 s per Stop on a 27 MB
#     transcript, and input_line_number reads one short on an unterminated last line.
# Record fields are type-guarded (?, objects, strings), so a valid line with the
# wrong shape is simply not a match and never raises an error.
#
# FAIL-CLOSED policy: a scan that exits non-zero is logged (gate=verify-<scan>-scan,
# jq's rc; jq's stderr goes to the hook's stderr) and makes the verdict UNTRUSTED.
# An untrusted verdict never approves before this session has been blocked once:
# the gate blocks ONCE, naming the failure (_svg_fail_closed). After that (block
# count >= 1) it approves and KEEPS the valve marker, so a persistent jq fault costs
# one block per session, not one per Stop. A scan failure never turns a block into
# an approve: with no evidence the normal block path runs as usual.
SCAN_FAILED=""   # comma list of scans that exited non-zero

# _svg_scan <name> <jq-program> [jq-args...]: one scan over the transcript. Output
# lands CR-stripped in SVG_OUT; a non-zero rc is logged and marks the verdict untrusted.
_svg_scan() {
  local name="$1" prog="$2" rc
  shift 2
  SVG_OUT=$(jq -nrR "$@" "$prog" "$TRANSCRIPT")
  rc=$?
  SVG_OUT=${SVG_OUT//$'\r'/}
  if [ "$rc" -ne 0 ]; then
    _svg_scan_error "gate=verify-$name-scan jq failed; verdict untrusted (fail closed)" "$rc"
    SCAN_FAILED="${SCAN_FAILED:+$SCAN_FAILED,}$name"
  fi
  return 0
}

# Untrusted verdict (policy above): block once per session, then approve without
# clearing the valve marker. Always exits. The block JSON is printf-built from fixed
# text so it survives a jq that cannot run at all.
_svg_fail_closed() {
  local cmd="run the project's checks (tests, lint, type-check)"
  [ -n "${VERIFY_CMD:-}" ] && cmd="run \`$VERIFY_CMD\` (discovered in this project)"
  if ! command -v sb_log_audit >/dev/null 2>&1; then
    source "$(dirname "$0")/lib.sh" 2>/dev/null || sb_log_audit() { :; }
  fi
  if [ "$BLOCK_COUNT" -ge 1 ]; then
    sb_log_audit "stop-verify-gate.sh" "allow" "gate-c-verify-scan-failed" "$SCAN_FAILED" "scan failed; block-once already spent this session, approving untrusted" "$SESSION_ID" 2>/dev/null || true
    exit 0
  fi
  mkdir -p "$BRAIN_DIR" 2>/dev/null
  echo "$((BLOCK_COUNT + 1))" > "$MARKER"
  sb_log_audit "stop-verify-gate.sh" "deny" "gate-c-verify-scan-failed" "$SCAN_FAILED" "scan failed; blocking once" "$SESSION_ID" 2>/dev/null || true
  printf '{"decision":"block","reason":"The verify gate could not scan this session transcript (failed scan: %s; see the error-log row gate=verify-<scan>-scan), so it cannot tell whether code changes were verified. Before completing: %s after your final edit, or call a verification skill through the Skill tool. This fail-closed block fires once per session."}\n' \
    "$SCAN_FAILED" "$cmd"
  exit 0
}

# --- Repo root and path classification (G1, R1 review) -----------------------------------------
# The root is CLAUDE_PROJECT_DIR first (the same precedence as sb_resolve_slug): the payload cwd
# MOVES during a session (one real transcript spent 3785 lines in one worktree, 210 in main and 191
# in another), and an Edit to the main checkout made while cwd sat in a worktree, another repo or a
# non-git dir used to read as "outside the root" and approve silently. Without it, the root is the
# git toplevel of the payload cwd, else the cwd itself. Each root is matched in every spelling a
# junction or symlink can produce: as given, its `pwd -P` form, git's resolved toplevel, and the
# logical toplevel (the cwd minus git's --show-prefix). Each spelling is its own --arg: MSYS turns
# a POSIX-looking argument into the Windows form native jq needs to match Windows tool paths.
CWD_DIR=$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
G1_ROOTS=()
_svg_root() { [ -n "$1" ] && G1_ROOTS+=("$1"); return 0; }
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  _svg_root "$CLAUDE_PROJECT_DIR"
  if [ -d "$CLAUDE_PROJECT_DIR" ]; then
    _svg_root "$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
    _svg_root "$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  fi
elif [ -n "$CWD_DIR" ] && [ -d "$CWD_DIR" ]; then
  _svg_gt=$(git -C "$CWD_DIR" rev-parse --show-toplevel --show-prefix 2>/dev/null | tr -d '\r')
  _svg_top=${_svg_gt%%$'\n'*}
  if [ -n "$_svg_top" ]; then
    _svg_root "$_svg_top"
    _svg_pre=""; case "$_svg_gt" in *$'\n'*) _svg_pre=${_svg_gt#*$'\n'}; _svg_pre=${_svg_pre%/} ;; esac
    _svg_log="${CWD_DIR//\\//}"; _svg_log=${_svg_log%/}
    if [ -n "$_svg_pre" ]; then
      case "$_svg_log" in *"/$_svg_pre") _svg_log=${_svg_log%"/$_svg_pre"} ;; *) _svg_log="" ;; esac
    fi
    _svg_root "$_svg_log"
  else
    _svg_root "$CWD_DIR"
    _svg_root "$(cd "$CWD_DIR" 2>/dev/null && pwd -P)"
  fi
fi
REPO_ROOT="${G1_ROOTS[0]:-}"
# Case-insensitive file systems (Git-Bash/MSYS, Cygwin, macOS): builtin $OSTYPE, no uname fork.
# Drive-letter paths compare case-insensitively everywhere.
case "${OSTYPE:-}" in msys*|cygwin*|darwin*) G1_CI=true ;; *) G1_CI=false ;; esac
G1_JQ_ARGS=(--arg root "$REPO_ROOT" --argjson ci "$G1_CI"
  --arg r0 "${G1_ROOTS[0]:-}" --arg r1 "${G1_ROOTS[1]:-}" --arg r2 "${G1_ROOTS[2]:-}")

# Two path tests share these defs.
#  - Write/Edit/MultiEdit (counts_as_src, G1): the path is canonicalized (\ -> /, the //?/ and //./
#    prefixes, MSYS /c/x -> c:/x, . and .. and repeated slashes collapsed), then placed against the
#    root spellings. INSIDE the root only docs/ (any depth) and the TOP-LEVEL tmp/ or scratch/ dirs
#    are exempt, so src/components/Sandbox.tsx, packages/sandbox/, src/tmp_parser.py and
#    src/temp-sensor.c all arm. OUTSIDE the root, or with no root at all, an edit ARMS unless the
#    path has an anchored temp segment (tmp, temp, scratch, scratchpad, sandbox; any case), which
#    keeps a Windows AppData/Local/Temp/.../scratchpad file exempt. A relative path is repo-relative.
#  - The Bash-edit heuristic (bash_counts_as_src) keeps the broader scratch match below: a shell
#    redirect into "$TMPDIR/x.sh" names no root at all, and that detector only moves the
#    last-edit line, it never arms the gate.
SRC_PATH_DEFS='
  def gnorm: explode | map(if . == 92 then 47 else . end) | implode
    | if test("^/[A-Za-z]/") then .[1:2] + ":" + .[2:] else . end;
  def repo_rel($root):
    gnorm as $p
    | if ($root == "" or ($p | test("^([A-Za-z]:)?/") | not)) then $p
      else ($root | gnorm | sub("/+$"; "")) as $r
        | (if ($r | test("^[A-Za-z]:"))
           then ($p | ascii_downcase | startswith(($r | ascii_downcase) + "/"))
           else ($p | startswith($r + "/")) end) as $in
        | if $in then $p[($r | length) + 1:] else null end
      end;
  def scratchy: test("(^|/)docs/")
    or test("(^|[/${])(tmp|temp|tmpdir|scratch|scratchpad|sandbox)([^[:alnum:]]|$)"; "i");
  def bash_counts_as_src: repo_rel($root) | . != null and (scratchy | not);
  def canon:
    explode | map(if . == 92 then 47 else . end) | implode
    | sub("^//[?.]/"; "")
    | if test("^/[A-Za-z](/|$)") then .[1:2] + ":" + .[2:] else . end
    | (if test("^[A-Za-z]:") then .[0:2] else "" end) as $drv
    | .[($drv | length):]
    | test("^/") as $abs
    | reduce (split("/")[] | select(. != "" and . != ".")) as $s ([];
        if $s != ".." then . + [$s]
        elif length > 0 and .[-1] != ".." then .[:-1]
        elif $abs or $drv != "" then .
        else . + [$s] end)
    | $drv + (if $abs then "/" else "" end) + join("/");
  def g1_roots: [$r0, $r1, $r2] | map(select(. != "") | canon | select(test("^([A-Za-z]:)?/?$") | not));
  def root_rel:
    canon as $p
    | if ($p | test("^([A-Za-z]:)?/") | not) then $p
      else ($ci or ($p | test("^[A-Za-z]:"))) as $fold
        | (if $fold then ($p | ascii_downcase) else $p end) as $pp
        | first(g1_roots[] as $r
                | (if $fold then ($r | ascii_downcase) else $r end) as $rr
                | select($pp == $rr or ($pp | startswith($rr + "/")))
                | $p[($r | length) + 1:]) // null
      end;
  def g1_class:
    root_rel as $rel
    | if $rel != null then {src: (($rel | test("(^|/)docs/") or test("^(tmp|scratch)/")) | not), outside: false}
      else {src: (canon | test("(^|/)(tmp|temp|scratch|scratchpad|sandbox)(/|$)"; "i") | not), outside: true} end;
  def counts_as_src: g1_class | .src;
'

# Check if code was modified (Write, Edit, or MultiEdit tool calls). Keep the
# FULL distinct changed-file set, not just the first hit — the block reason names
# what actually changed, and the critic offer keys on its size. This full pass also
# counts the lines every scan skips (blank lines excluded) and the edits placed OUTSIDE
# the root (G1). Output: line 1 skipped count, line 2 outside-root edits that arm, line 3
# outside-root edits exempt by a temp segment, line 4 the first outside-root path (or
# empty), then the sorted distinct changed paths.
CHANGED_SCAN_JQ='
  ([13] | implode) as $cr
  | reduce (inputs | select(length > 0 and . != $cr) | [fromjson? | objects]) as $r
      ({skipped: 0, files: {}, out_armed: {}, out_exempt: {}};
       if $r == [] then .skipped += 1
       else reduce ($r[0]
                    | select(.type == "assistant")
                    | .message.content?[]? | objects
                    | select(.type == "tool_use")
                    | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
                    | .input.file_path? | strings
                    | select(. != "")
                    | select((endswith(".md") or endswith(".markdown") or endswith(".txt")) | not)
                    | {p: ., c: g1_class}) as $e
              (.; (if $e.c.outside then (if $e.c.src then .out_armed[$e.p] = true else .out_exempt[$e.p] = true end) else . end)
                  | if $e.c.src then .files[$e.p] = true else . end)
       end)
  | (.skipped | tostring), (.out_armed | length | tostring), (.out_exempt | length | tostring),
    ((((.out_armed | keys) + (.out_exempt | keys)) | first) // ""), (.files | keys[])
'
_svg_scan changed "$SRC_PATH_DEFS$CHANGED_SCAN_JQ" "${G1_JQ_ARGS[@]}"
SKIPPED=${SVG_OUT%%$'\n'*}; _svg_rest=""
case "$SVG_OUT" in *$'\n'*) _svg_rest=${SVG_OUT#*$'\n'} ;; esac
OUT_ARMED=${_svg_rest%%$'\n'*}; case "$_svg_rest" in *$'\n'*) _svg_rest=${_svg_rest#*$'\n'} ;; *) _svg_rest="" ;; esac
OUT_EXEMPT=${_svg_rest%%$'\n'*}; case "$_svg_rest" in *$'\n'*) _svg_rest=${_svg_rest#*$'\n'} ;; *) _svg_rest="" ;; esac
OUT_FIRST=${_svg_rest%%$'\n'*}
CHANGED_FILES=""
case "$_svg_rest" in *$'\n'*) CHANGED_FILES=${_svg_rest#*$'\n'} ;; esac
case "$SKIPPED" in ''|*[!0-9]*) SKIPPED=0 ;; esac
case "$OUT_ARMED" in ''|*[!0-9]*) OUT_ARMED=0 ;; esac
case "$OUT_EXEMPT" in ''|*[!0-9]*) OUT_EXEMPT=0 ;; esac
# An outside-root classification is never silent (R1 review): one TRACE row on the audit channel
# per Stop that sees one, naming the counts, the root and the first such path.
if [ $((OUT_ARMED + OUT_EXEMPT)) -gt 0 ]; then
  _svg_scan_error "gate=verify-outside-root armed=$OUT_ARMED exempt=$OUT_EXEMPT root=${REPO_ROOT:-none} first=$OUT_FIRST" 0
fi
# A torn line is not an error of this hook, but it is data the gate could not see.
# Non-gate message + rc 0 keeps the row in the error-log (lib.sh torn-line precedent).
[ "$SKIPPED" -gt 0 ] && _svg_scan_error "verify-scan: skipped $SKIPPED unparseable or non-object transcript line(s) in $TRANSCRIPT; every scan ignores them and the verdict uses the rest" 0
CODE_MODIFIED=${CHANGED_FILES%%$'\n'*}
CHANGED_N=0
[ -n "$CHANGED_FILES" ] && CHANGED_N=$(printf '%s\n' "$CHANGED_FILES" | grep -c .)

# The changed-file scan failed: whether code changed at all is unknown.
[ -n "$SCAN_FAILED" ] && _svg_fail_closed

if [ -z "$CODE_MODIFIED" ]; then
  rm -f "$MARKER" "$AG_MARKER" 2>/dev/null
  exit 0
fi

# D181: verification evidence only counts if it ran AFTER the last code edit —
# a pre-edit test run or a stray `cat build.log` anywhere in the transcript
# used to satisfy the gate regardless of order. The scans count raw lines
# (foreach), and transcripts are strict one-object-per-line, so a line number
# is a record position (same numbering as awk's NR).
#
# B6 Bash-edit HEURISTIC: Write/Edit/MultiEdit are not the only way to change a
# file — Edit → tests → `sed -i` used to pass on stale tests. A Bash command also
# moves LAST_EDIT_LINE when one of its spans (split on && || ; | and newlines,
# after single-quoted text is blanked so sed/awk/jq programs cannot fake a match)
#   - runs sed/gsed/perl with -i/--in-place and names a source path, or is fed a
#     hidden file list (xargs, find -exec);
#   - redirects with > or >> into a source path; or
#   - is a tee into a source path.
# Source path = a code extension below, outside docs/ and outside tmp/temp/
# scratch/sandbox locations. NOT detected: data files (json/yaml/toml), mv/cp,
# git checkout/apply, patch — the worktree fingerprint (S1b) replaces this
# heuristic. A command that edits and then tests on one line counts as an edit
# whose own test does not count (conservative: one block). Bash edits only move
# LAST_EDIT_LINE; they never arm the gate on their own (CHANGED_FILES above).
EDIT_SCAN_JQ='
  def sq: [39] | implode;
  def srcpath:
    explode | map(select(. != 34 and . != 39)) | implode
    | test("[.](sh|bash|zsh|ps1|js|mjs|cjs|ts|mts|cts|tsx|jsx|py|rb|go|rs|java|kt|kts|swift|c|h|cc|cpp|hpp|cs|php|pl|pm|lua|sql|css|scss|html|vue|svelte)$")
      and bash_counts_as_src;
  def span_edits:
    ( test("(^|[[:space:]])(g?sed|perl)[[:space:]]")
      and test("[[:space:]](-[Enrszuplaw0]*i|--in-place)")
      and ( test("(^|[[:space:]])xargs[[:space:]]|[[:space:]]-exec[[:space:]]")
            or any(splits("[[:space:]]+"); srcpath) ) )
    or any(match("(^|[^=<>-])>>?[[:space:]]*([^[:space:]<>()&]+)"; "g") | .captures[1].string; srcpath)
    or ( test("^tee([[:space:]]|$)")
         and any(splits("[[:space:]]+") | select(. != "tee" and (test("^-") | not)); srcpath) );
  def bash_edits:
    gsub(sq + "[^" + sq + "]*" + sq; " ")
    | any(splits("&&|[|][|]|[;|" + ([10, 13] | implode) + "]")
          | sub("^[[:space:]]*[({]?[[:space:]]*"; "") | sub("^sudo[[:space:]]+"; "");
          span_edits);
  def is_edit:
    select(.type == "assistant")
    | .message.content?[]? | objects
    | select(.type == "tool_use")
    | select(((.name == "Write" or .name == "Edit" or .name == "MultiEdit")
              and ((.input.file_path? | strings) // "" | (endswith(".md") or endswith(".markdown") or endswith(".txt") or (counts_as_src | not)) | not))
             or (.name == "Bash" and ((.input.command? | strings) // "" | bash_edits)));
  reduce (foreach inputs as $line (0; . + 1; . as $n | $line | fromjson? | objects | is_edit | $n)) as $n (0; $n)
'
_svg_scan edit "$SRC_PATH_DEFS$EDIT_SCAN_JQ" "${G1_JQ_ARGS[@]}"
LAST_EDIT_LINE=$SVG_OUT
case "$LAST_EDIT_LINE" in ''|*[!0-9]*) LAST_EDIT_LINE=0 ;; esac

# Tool_use ids whose result came back an error — a Bash run that FAILED (tests
# red, build broke) must not count as verification evidence just because its
# command text matched the keyword list.
_svg_scan errored '
  inputs | fromjson? | objects
  | select(.type == "user")
  | .message.content?[]? | objects
  | select(.type == "tool_result" and ((.is_error // false) == true))
  | .tool_use_id // empty
'
ERRORED_IDS=$SVG_OUT
# True when tool_use id $1 came back an error. Shared by the Bash and Skill evidence
# checks; a bash pattern match, no per-candidate spawn. NOID (no id) never matches.
_svg_errored() {
  [ "$1" != "NOID" ] || return 1
  case $'\n'"$ERRORED_IDS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# Discover the project's EXACT verify command from cheap cwd probes, so the
# block says "run THIS" instead of a generic nag. NAMING ONLY — auto-running from a
# Stop hook was review-killed (blocks the turn for minutes; breaks the fail-open
# invariant). If/when the auto-team pinned-command resolver lands, reuse it here —
# do NOT grow these probes into a second resolver (single-source discipline).
VERIFY_CMD=""
if [ -n "$CWD_DIR" ] && [ -d "$CWD_DIR" ]; then
  if [ -f "$CWD_DIR/tests/run-all.sh" ]; then
    VERIFY_CMD="bash tests/run-all.sh"
  elif [ -f "$CWD_DIR/package.json" ] && jq -e '.scripts.test // empty' "$CWD_DIR/package.json" >/dev/null 2>&1; then
    VERIFY_CMD="npm test"
  elif [ -f "$CWD_DIR/Makefile" ] && grep -qE '^test:' "$CWD_DIR/Makefile" 2>/dev/null; then
    VERIFY_CMD="make test"
  fi
fi

# Code was modified — look for verification evidence.
# 1. Bash commands that look like test/lint/build/check runs, issued AFTER the
# last edit (D181), whose result (when the transcript carries one) didn't error.
# NOID placeholder (never a real tool_use id) instead of an empty first field:
# bash `read` with tab in IFS strips LEADING IFS whitespace before splitting, so
# an empty id followed by a real tab silently collapses into a one-field read
# (v_id got the whole "id<TAB>cmd" string, v_cmd came back empty) — every
# candidate then failed the command match and the gate blocked despite real
# verification evidence existing.
_svg_scan verify '
  foreach inputs as $line (0; . + 1;
    select(. > $from) | $line | fromjson? | objects
    | select(.type == "assistant")
    | .message.content?[]? | objects
    | select(.type == "tool_use" and .name == "Bash")
    | ((.id | strings) // "NOID") + "\t" + ((.input.command? | strings) // ""))
' --argjson from "$LAST_EDIT_LINE"
VERIFY_CANDIDATES=$SVG_OUT
VERIFY_CMDS=""
if [ -n "$VERIFY_CANDIDATES" ]; then
  while IFS=$'\t' read -r v_id v_cmd; do
    [ -n "$v_cmd" ] || continue
    printf '%s' "$v_cmd" | grep -iwE '(test|vitest|jest|pytest|mocha|lint|eslint|tsc|typecheck|type-check|build|check|prettier|biome)' >/dev/null 2>&1 || continue
    if _svg_errored "$v_id"; then
      continue   # this run's own result reported an error — not verification evidence
    fi
    VERIFY_CMDS="$v_cmd"
    break
  # Process substitution, not a `<<<` here-string: on MSYS a here-string of 65,536..~65,650 bytes
  # hangs past the reader's start (RR-SF2) — a session with enough post-edit Bash commands could
  # grow VERIFY_CANDIDATES past that width, hanging the Stop hook and forfeiting the gate's
  # evidence silently instead of just running it.
  done < <(printf '%s\n' "$VERIFY_CANDIDATES")
fi

# 2. Skill tool calls issued AFTER the last edit whose name is EXACTLY on
# VERIFY_SKILLS_JSON (B6). Assistant text is deliberately not read: prose such as
# "run /review before merging" or a URL ending in /reviews is not a review.
# SEC-L2: like a Bash run, a Skill call whose own result came back an error (unknown
# skill, a failed run) is not evidence. Same NOID placeholder as the Bash scan.
_svg_scan skill '
  foreach inputs as $line (0; . + 1;
    select(. > $from) | $line | fromjson? | objects
    | select(.type == "assistant")
    | .message.content?[]? | objects
    | select(.type == "tool_use" and .name == "Skill")
    | (.input.skill? // "") as $s
    | select(any($allow[]; . == $s))
    | ((.id | strings) // "NOID") + "\t" + $s)
' --argjson from "$LAST_EDIT_LINE" --argjson allow "$VERIFY_SKILLS_JSON"
SKILL_TOOL=""
if [ -n "$SVG_OUT" ]; then
  while IFS=$'\t' read -r s_id s_name; do
    [ -n "$s_name" ] || continue
    _svg_errored "$s_id" && continue
    SKILL_TOOL="$s_name"
    break
  # Process substitution, not `<<<` (RR-SF2): same MSYS 65,536..~65,650-byte here-string hang as
  # VERIFY_CANDIDATES above — a session with enough post-edit Skill calls could grow SVG_OUT past
  # that width.
  done < <(printf '%s\n' "$SVG_OUT")
fi

# Anti-gaming slice: verification evidence is SUSPECT when
# the same session DELETED a test file — the cheapest reward-hack in the catalog
# (delete the failing test, run the now-green suite, claim verified). TDD test EDITS
# are normal and never flagged; only rm / git rm of a test-shaped path. One pointed
# block through the same 2-block valve. Kill switch: SB_VERIFY_ANTIGAME=off.
# BSD-safe patterns only: [[:space:]] classes, no \b/\s/\w.
# WINDOW-scoped: scan only transcript lines a PRIOR Stop has not already scanned,
# so one historical deletion doesn't re-fire every Stop (same NR>s window as
# stop-extract.sh's slice, counted inside the scan, keyed on AG_MARKER — see its comment).
AG_LAST=0
[ -f "$AG_MARKER" ] && AG_LAST=$(cat "$AG_MARKER" 2>/dev/null | tr -d '[:space:]')
case "$AG_LAST" in ''|*[!0-9]*) AG_LAST=0 ;; esac

TEST_RM=""
if [ "${SB_VERIFY_ANTIGAME:-on}" != "off" ]; then
  # ARGUMENT-scoped: split each command on &&/;/| into spans and flag only a span
  # whose OWN first token is rm / git rm AND that references a test-shaped path.
  # The old line-level `grep rm-line | grep test-path` false-flagged an innocent
  # `bash tests/test-x.sh && rm -rf "$TMP"` (rm's argument is $TMP, not a test).
  # jq does the split so the SAME regex engine runs on BSD and GNU (no \b/\s/\w).
  _svg_scan antigame '
    foreach inputs as $line (0; . + 1;
      select(. > $from) | $line | fromjson? | objects
      | select(.type == "assistant")
      | .message.content?[]? | objects
      | select(.type == "tool_use" and .name == "Bash")
      | (.input.command? | strings)
      | select(. != "")
      | [ split("&&|[;|]"; "")[]
          | sub("^[[:space:]]*[({][[:space:]]*"; "") | sub("^[[:space:]]+"; "")
          | select(test("^(sudo[[:space:]]+)?(git[[:space:]]+)?rm([[:space:]]|$)"))
          | select(test("(tests?/|[._-]test\\.|[._-]spec\\.|/test_[a-z0-9_]+\\.py)")) ]
      | select(length > 0)
      | .[0])
  ' --argjson from "$AG_LAST"
  TEST_RM=${SVG_OUT%%$'\n'*}
fi

if [ -n "$VERIFY_CMDS" ] || [ -n "$SKILL_TOOL" ]; then
  # Evidence found, but a scan failed: the approve is untrusted (fail-closed policy
  # above). A found test deletion still takes its own, more specific block below.
  [ -n "$SCAN_FAILED" ] && [ -z "$TEST_RM" ] && _svg_fail_closed
  # Buddy: a verify gate that blocked earlier this session is now satisfied — clear its line.
  if [ -f "$MARKER" ] && [ "${SB_BUDDY:-on}" != "off" ]; then
    { command -v sb_buddy_event >/dev/null 2>&1 || source "$(dirname "$0")/lib.sh" 2>/dev/null; } || true
    command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$SESSION_ID" gate pleased "Verification ran — verify gate cleared." stop-verify-gate 120
  fi
  if [ -n "$TEST_RM" ]; then
    mkdir -p "$BRAIN_DIR" 2>/dev/null
    echo "$((BLOCK_COUNT + 1))" > "$MARKER"
    # Advance the anti-game window past this deletion so it can't re-flag next Stop.
    AG_TOTAL=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]'); echo "${AG_TOTAL:-0}" > "$AG_MARKER" 2>/dev/null || true
    jq -nc --arg cmd "$TEST_RM" '{
      decision: "block",
      reason: ("Verification evidence coincides with a test-file deletion in this session: `\($cmd)`. Deleting a test and then claiming green is the cheapest way to fake verification. Re-run the FULL suite and state explicitly why removing that test is correct (obsolete behavior? coverage superseded where?) — or restore it. Suppress this check: SB_VERIFY_ANTIGAME=off.")
    }'
    exit 0
  fi
  # Critic offer: verification RAN, but rules can't judge design — on a
  # SUBSTANTIVE diff, offer the already-shipped fresh-context critic ONCE per
  # session (non-blocking systemMessage; the model/user decides). This engages the
  # judge rung on the 90% solo path without new machinery or coercion.
  # Kill switch: SB_CRITIC_OFFER=off; threshold SB_CRITIC_OFFER_MIN_FILES (3).
  [ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_CRITIC_OFFER:=off}" # hook-profile shim: this check runs before lib.sh's mapping (or lib-less)
  if [ "${SB_CRITIC_OFFER:-on}" != "off" ]; then
    OFFER_MIN="${SB_CRITIC_OFFER_MIN_FILES:-3}"; case "$OFFER_MIN" in ''|*[!0-9]*) OFFER_MIN=3 ;; esac
    OFFER_MARKER="$BRAIN_DIR/.critic-offer-$SESSION_ID"
    if [ "$CHANGED_N" -ge "$OFFER_MIN" ] && [ ! -f "$OFFER_MARKER" ]; then
      mkdir -p "$BRAIN_DIR" 2>/dev/null
      : > "$OFFER_MARKER" 2>/dev/null
      { command -v sb_buddy_event >/dev/null 2>&1 || source "$(dirname "$0")/lib.sh" 2>/dev/null; } || true
      command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$SESSION_ID" pending waiting "${CHANGED_N} files changed and checks passed — want a fresh-context critique? persona_think on the diff." stop-verify-gate
      jq -nc --arg n "$CHANGED_N" '{
        systemMessage: ("second-brain: " + $n + " source files changed and checks ran — rules verified mechanics, not design. For an independent fresh-context critique, run persona_think on the diff. Suppress: SB_CRITIC_OFFER=off.")
      }'
    fi
  fi
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

# No verification evidence found — block. Name WHAT changed and the EXACT
# command to run (discovered above), not a generic nag — deterministic backpressure.
mkdir -p "$BRAIN_DIR" 2>/dev/null
echo "$((BLOCK_COUNT + 1))" > "$MARKER"

# Session Intent Spine — close the loop on the frozen WHY: quote the session goal
# and the phase actually reached, so the block is the external done-check against
# the original intent, not a generic nag. Fail-open: no memo/phase (or spine off)
# leaves the reason unchanged.
SPINE_NOTE=""
if [ "${SB_INTENT_SPINE:-on}" != "off" ]; then
  _SP_SID="${SESSION_ID//[^A-Za-z0-9_-]/}"; _SP_SID="${_SP_SID:0:64}"
  _SP_GOAL=$(jq -r '.goal // ""' "$BRAIN_DIR/.injected/$_SP_SID.json" 2>/dev/null | tr -d '\r')
  _SP_PHASE=""
  [ -f "$BRAIN_DIR/.injected/$_SP_SID.phase" ] && { IFS= read -r _SP_PHASE < "$BRAIN_DIR/.injected/$_SP_SID.phase" 2>/dev/null || true; }
  case "$_SP_PHASE" in implement|verify) ;; *) _SP_PHASE="plan" ;; esac
  [ -n "$_SP_GOAL" ] && SPINE_NOTE=" Session goal: \"$_SP_GOAL\" (phase reached: $_SP_PHASE) — verification is what closes it."
fi

FILES_PREVIEW=$(printf '%s\n' "$CHANGED_FILES" | head -5 | tr '\n' ' ')
CMD_LINE="run the project's checks (tests, lint, type-check)"
[ -n "$VERIFY_CMD" ] && CMD_LINE="run \`$VERIFY_CMD\` (discovered in this project)"
# Audit the gate verdict (lazy lib.sh load; a source failure must never mute the block).
if ! command -v sb_log_audit >/dev/null 2>&1; then
  if ! source "$(dirname "$0")/lib.sh" 2>/dev/null; then
    sb_log_audit() { :; }
  fi
fi
sb_log_audit "stop-verify-gate.sh" "deny" "gate-c-verify-block" "$FILES_PREVIEW" "no verification evidence;$SPINE_NOTE" "$SESSION_ID" 2>/dev/null || true
command -v sb_buddy_event >/dev/null 2>&1 && sb_buddy_event "$SESSION_ID" gate alert "Verify gate: ${CHANGED_N} file(s) changed, no checks ran — ${CMD_LINE} before claiming done." stop-verify-gate
jq -nc --arg n "$CHANGED_N" --arg files "$FILES_PREVIEW" --arg cmd "$CMD_LINE" --arg note "$SPINE_NOTE" '{
  decision: "block",
  reason: ("Code was modified (" + $n + " file(s): " + $files + "…) but nothing verified it after the last edit. Before completing: " + $cmd + " after your final edit (a sed -i or > redirect into a source file counts as an edit), or call a verification skill through the Skill tool. Only tool calls count as evidence; naming a check in text does not. Evidence before assertions." + $note)
}'
