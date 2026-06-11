#!/bin/bash
# Guard: a skill whose body uses a top-level external binary must DECLARE it in allowed-tools,
# else a permission prompt stalls the skill mid-run. This is the v0.21.1 missing-mktemp bug
# class (then for agents), surfaced again for skills by the 2026-06-02 full-plugin audit.
# Targeted per-skill verb requirements (no body-parser heuristic -> no false positives).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; S="$ROOT/skills"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

req(){ # req <skill> <verb-or-mcp-token>...
  local sk="$1"; shift; local f="$S/$sk/SKILL.md" at
  [ -f "$f" ] || fail "$sk: SKILL.md not found"
  at=$(grep -m1 '^allowed-tools:' "$f") || fail "$sk: no allowed-tools line"
  for v in "$@"; do
    case "$v" in
      mcp__*) printf '%s' "$at" | grep -qF "$v" || fail "$sk: missing MCP tool '$v' in allowed-tools" ;;
      *)      printf '%s' "$at" | grep -qE "Bash\($v " || fail "$sk: missing Bash($v *) in allowed-tools (body uses '$v' at top level)" ;;
    esac
  done
  pass "$sk: declares [$*]"
}

# Each row = the top-level binaries/tools the skill's bash body actually invokes.
req dream       mktemp mv mkdir rm
req setup       grep sed awk head cat wc
req review      basename dirname tr head
req import-host tr
req status      mcp__plugin_second-brain_knowledge-base__knowledge_validate
req upgrade     node

echo; echo "ALL PASS"

# R8: the SHORT MCP dialect is non-canonical — the runtime exposes plugin
# tools as mcp__plugin_second-brain_knowledge-base__* (verified live), so a
# short-form grant never matches and silently becomes a permission prompt.
if grep -rln 'mcp__knowledge-base__' "$ROOT/skills" "$ROOT/agents"  | grep -q .; then
  echo "FAIL: short-form mcp__knowledge-base__ grant found (canonical: mcp__plugin_second-brain_knowledge-base__*)"
  exit 1
fi
echo "PASS: no non-canonical short-form MCP grants"
