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
