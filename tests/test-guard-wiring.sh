#!/bin/bash
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
printf '%s' "$QG_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 \
  || fail "quality-gate.sh does not emit a PostToolUse hookSpecificOutput envelope (got: $QG_OUT)"
printf '%s' "$QG_OUT" | jq -e '(.hookSpecificOutput.additionalContext | length) > 0' >/dev/null 2>&1 \
  || fail "quality-gate.sh envelope has no additionalContext text (got: $QG_OUT)"
pass "quality-gate.sh emits hookSpecificOutput.additionalContext (reaches model context)"
QG_OFF=$(SB_QUALITY_GATE=off bash "$QG" 2>/dev/null)
[ -z "$QG_OFF" ] || fail "SB_QUALITY_GATE=off must silence quality-gate.sh (got: $QG_OFF)"
pass "SB_QUALITY_GATE=off kill switch silences quality-gate.sh"

echo; echo "ALL PASS"
