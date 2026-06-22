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

echo; echo "ALL PASS"
